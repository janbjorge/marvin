-- marvin: 08-config-and-capacity.sql — Phase 8. Read-only. PG16+.
-- GUC snapshot (drift, planner flags) is 0-settings; rules in SKILL.md §H.
-- Here: pending restarts, memory arithmetic, pg_stat_database counters,
-- connections, sequence exhaustion, lock-table capacity.

-- ============================================================================
-- 8a  Pending restart — configured ≠ running. Any row → MEDIUM.
-- ============================================================================
SELECT name, setting, unit, boot_val, source, sourcefile, pending_restart
FROM pg_settings
WHERE pending_restart;


-- ============================================================================
-- 8b  Memory arithmetic. RAM is invisible from SQL — ask the operator.
-- work_mem is per sort/hash node (× hash_mem_multiplier for hashes), not
-- per connection. pganalyze expected work_mem ≈ shared_buffers /
-- max_connections clamped 1 MB–256 MB.
-- ============================================================================
WITH s AS (
  SELECT
    (SELECT setting::bigint FROM pg_settings WHERE name = 'shared_buffers')
      * current_setting('block_size')::bigint                              AS shared_buffers_b,
    (SELECT setting::bigint * 1024 FROM pg_settings WHERE name = 'work_mem') AS work_mem_b,
    current_setting('max_connections')::int                                 AS max_conn
)
SELECT
  pg_size_pretty(shared_buffers_b)                           AS shared_buffers,
  current_setting('effective_cache_size')                    AS effective_cache_size,
  current_setting('work_mem')                                AS work_mem,
  current_setting('hash_mem_multiplier')                     AS hash_mem_multiplier,
  current_setting('maintenance_work_mem')                    AS maintenance_work_mem,
  current_setting('autovacuum_work_mem')                     AS autovacuum_work_mem,
  max_conn                                                   AS max_connections,
  pg_size_pretty(work_mem_b * max_conn)                      AS work_mem_x_max_conn,
  pg_size_pretty(GREATEST(LEAST(shared_buffers_b / max_conn, 256::bigint * 1024 * 1024),
                          1024 * 1024))                      AS pganalyze_expected_work_mem
FROM s;


-- ============================================================================
-- 8c  pg_stat_database counters since stats_reset. severity: checksum_
-- failures > 0 → CRITICAL (bad pages from storage); deadlocks > 0 or
-- rollback_pct > 10 (app error loop) → MEDIUM. temp_files = cluster-wide 5c;
-- sessions_abandoned = clients dropped mid-query (pooler/LB timeouts).
-- ============================================================================
WITH d AS (
  SELECT *, round(100.0 * xact_rollback / NULLIF(xact_commit + xact_rollback, 0), 2) AS rollback_pct
  FROM pg_stat_database WHERE datname = current_database()
)
SELECT
  datname, xact_commit, xact_rollback, rollback_pct,
  deadlocks, conflicts,
  temp_files, pg_size_pretty(temp_bytes)                      AS temp_size,
  checksum_failures, checksum_last_failure,
  sessions, sessions_abandoned, sessions_fatal, sessions_killed,
  round((idle_in_transaction_time / 1000 / 3600)::numeric, 1) AS idle_in_xact_hours,
  current_setting('data_checksums')                           AS data_checksums,
  stats_reset, now() - stats_reset                            AS stats_age,
  CASE WHEN checksum_failures > 0                 THEN 'CRITICAL'
       WHEN deadlocks > 0 OR rollback_pct > 10    THEN 'MEDIUM' END AS severity
FROM d;


-- ============================================================================
-- 8d  Connection capacity net of superuser_reserved_connections +
-- reserved_connections. severity: app_capacity_used_pct > 90 → HIGH; > 80 or
-- max_connections > 300 (Percona: pooler territory) → MEDIUM.
-- ============================================================================
WITH cap AS (
  SELECT current_setting('max_connections')::int                AS max_connections,
         current_setting('superuser_reserved_connections')::int AS superuser_reserved,
         current_setting('reserved_connections')::int           AS reserved
), a AS (
  SELECT count(*)                                                  AS total,
         count(*) FILTER (WHERE state = 'active')                  AS active,
         count(*) FILTER (WHERE state = 'idle')                    AS idle,
         count(*) FILTER (WHERE state LIKE 'idle in transaction%') AS idle_in_xact,
         count(*) FILTER (WHERE backend_type <> 'client backend')  AS non_client,
         count(*) FILTER (WHERE backend_type = 'client backend')   AS client
  FROM pg_stat_activity
), c AS (
  SELECT *, max_connections - superuser_reserved - reserved AS app_capacity,
         round(100.0 * client / (max_connections - superuser_reserved - reserved), 1) AS app_capacity_used_pct
  FROM a, cap
)
SELECT total, active, idle, idle_in_xact, non_client,
       max_connections, superuser_reserved, reserved, app_capacity, app_capacity_used_pct,
       CASE WHEN app_capacity_used_pct > 90                          THEN 'HIGH'
            WHEN app_capacity_used_pct > 80 OR max_connections > 300 THEN 'MEDIUM' END AS severity
FROM c;


-- ============================================================================
-- 8e  Connections by state / user / app with idle-in-transaction tiers.
-- severity: any idle in transaction > 60 min → HIGH; > 30 min → MEDIUM
-- (pganalyze). Empty application_name = fix at the client so 4b/5j can
-- attribute load. Large idle share = client pool oversized.
-- ============================================================================
SELECT
  state, usename, application_name, count(*) AS backends,
  max(now() - state_change)                  AS oldest_in_state,
  count(*) FILTER (WHERE state = 'idle in transaction'
                     AND now() - state_change > interval '30 minutes') AS idle_in_xact_over_30m,
  count(*) FILTER (WHERE state = 'idle in transaction'
                     AND now() - state_change > interval '60 minutes') AS idle_in_xact_over_60m,
  CASE WHEN count(*) FILTER (WHERE state = 'idle in transaction'
                               AND now() - state_change > interval '60 minutes') > 0 THEN 'HIGH'
       WHEN count(*) FILTER (WHERE state = 'idle in transaction'
                               AND now() - state_change > interval '30 minutes') > 0 THEN 'MEDIUM'
  END AS severity
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY state, usename, application_name
ORDER BY backends DESC
LIMIT 25;


-- ============================================================================
-- 8f  Sequence / column exhaustion. A bigint sequence feeding an int4 column
-- overflows at column_pct = 100 (Crunchy). severity on the worse of seq_pct /
-- column_pct: > 80 → HIGH; > 50 → MEDIUM; > 10 → LOW. last_value NULL =
-- role cannot read the sequence — flag, don't guess.
-- ============================================================================
WITH seq AS (
  SELECT
    s.schemaname, s.sequencename, s.data_type::text AS seq_type,
    s.last_value, s.max_value, s.increment_by,
    d.refobjid::regclass          AS owned_table,
    a.attname                     AS owned_column,
    format_type(a.atttypid, NULL) AS column_type,
    CASE format_type(a.atttypid, NULL)
      WHEN 'smallint' THEN 32767::numeric
      WHEN 'integer'  THEN 2147483647::numeric
      WHEN 'bigint'   THEN 9223372036854775807::numeric
    END                           AS column_max
  FROM pg_sequences s
  JOIN pg_class c ON c.relname = s.sequencename
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = s.schemaname
  LEFT JOIN pg_depend d ON d.objid = c.oid AND d.classid = 'pg_class'::regclass
                        AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a','i')
  LEFT JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
  WHERE c.relkind = 'S'
), p AS (
  SELECT *,
         round(100.0 * last_value / NULLIF(max_value, 0), 2)  AS seq_pct,
         round(100.0 * last_value / NULLIF(column_max, 0), 2) AS column_pct
  FROM seq
  WHERE last_value IS NOT NULL AND increment_by > 0
)
SELECT schemaname, sequencename, seq_type, last_value, seq_pct,
       owned_table, owned_column, column_type, column_pct,
       CASE WHEN GREATEST(seq_pct, column_pct) > 80 THEN 'HIGH'
            WHEN GREATEST(seq_pct, column_pct) > 50 THEN 'MEDIUM'
            WHEN GREATEST(seq_pct, column_pct) > 10 THEN 'LOW' END AS severity
FROM p
ORDER BY GREATEST(seq_pct, column_pct) DESC NULLS LAST
LIMIT 25;


-- ============================================================================
-- 8g  Lock table capacity = max_locks_per_transaction × (max_connections +
-- max_prepared_transactions). A query on a parent with N partitions takes
-- N+ locks per backend. severity MEDIUM = used_pct > 50 or partitions ×
-- active backends within capacity. Fix: raise max_locks_per_transaction
-- (restart; standby ≥ primary).
-- ============================================================================
WITH c AS (
  SELECT
    current_setting('max_locks_per_transaction')::int AS max_locks_per_xact,
    current_setting('max_connections')::int           AS max_connections,
    current_setting('max_prepared_transactions')::int AS max_prepared_xacts,
    (SELECT count(*) FROM pg_locks)                    AS locks_now,
    (SELECT count(*) FROM pg_locks WHERE NOT fastpath) AS locks_non_fastpath,
    (SELECT count(*) FROM pg_stat_activity WHERE state = 'active') AS active_backends,
    (SELECT max(cnt) FROM (SELECT count(*) AS cnt FROM pg_inherits GROUP BY inhparent) p) AS max_partitions_per_parent
), x AS (
  SELECT *, max_locks_per_xact * (max_connections + max_prepared_xacts) AS lock_table_capacity
  FROM c
)
SELECT *,
       round(100.0 * locks_now / lock_table_capacity, 1) AS used_pct,
       CASE WHEN 100.0 * locks_now / lock_table_capacity > 50
              OR max_partitions_per_parent * active_backends > lock_table_capacity THEN 'MEDIUM' END AS severity
FROM x;

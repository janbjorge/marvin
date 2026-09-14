-- marvin: 08-config-and-capacity.sql — Phase 8. Read-only. PG16+.
-- Configuration sanity, database-level counters, connection pressure,
-- sequence exhaustion, lock-table capacity. Every GUC is read from
-- pg_settings so a name that does not exist on this major simply yields no
-- row (current_setting() would raise).

-- ============================================================================
-- 8a  Pending restart. ALTER SYSTEM applied, postmaster not restarted — the
-- running value is not the configured value. Any row → MEDIUM.
-- ============================================================================
SELECT name, setting, unit, boot_val, source, sourcefile, pending_restart
FROM pg_settings
WHERE pending_restart;


-- ============================================================================
-- 8b  GUC snapshot vs compiled default. changed = true is information, not a
-- defect — the point is to see what someone tuned and what nobody did.
-- Rules the agent applies (see interpretation-thresholds.md "Config sanity"):
--   fsync = off → CRITICAL; track_counts/track_activities = off → HIGH
--   (autovacuum blind); jit = on + OLTP → MEDIUM; random_page_cost = 4 on
--   SSD → MEDIUM; checkpoint_timeout = 300 + 5k req_pct > 30 → MEDIUM;
--   wal_compression = off + high 5b2 wal_fpi → LOW; log_checkpoints /
--   log_lock_waits = off → LOW; log_autovacuum_min_duration = -1 → LOW;
--   huge_pages_status = off with shared_buffers > 8 GB → LOW;
--   data_checksums = off → LOW (cannot enable online before PG19);
--   effective_io_concurrency = 1 on PG18 → LOW (disables AIO read-ahead);
--   statement_timeout / lock_timeout / idle_in_transaction_session_timeout = 0
--   cluster-wide on OLTP → MEDIUM.
-- ============================================================================
SELECT name, setting, unit, boot_val,
       setting IS DISTINCT FROM boot_val AS changed,
       source, pending_restart
FROM pg_settings
WHERE name IN (
  'fsync','full_page_writes','track_counts','track_activities','track_io_timing','track_wal_io_timing',
  'jit','random_page_cost','seq_page_cost','effective_io_concurrency','maintenance_io_concurrency',
  'wal_compression','wal_buffers','checkpoint_timeout','checkpoint_completion_target','max_wal_size','min_wal_size',
  'log_checkpoints','log_lock_waits','log_autovacuum_min_duration','log_temp_files','log_min_duration_statement',
  'huge_pages','huge_pages_status','data_checksums',
  'shared_buffers','effective_cache_size','work_mem','hash_mem_multiplier','maintenance_work_mem','autovacuum_work_mem',
  'autovacuum','autovacuum_max_workers','autovacuum_worker_slots','autovacuum_naptime',
  'autovacuum_vacuum_cost_limit','autovacuum_vacuum_cost_delay','vacuum_cost_limit',
  'autovacuum_vacuum_scale_factor','autovacuum_vacuum_threshold','autovacuum_vacuum_max_threshold',
  'autovacuum_vacuum_insert_scale_factor','autovacuum_analyze_scale_factor','autovacuum_freeze_max_age',
  'vacuum_failsafe_age','track_cost_delay_timing',
  'io_method','io_workers','io_combine_limit',
  'statement_timeout','lock_timeout','idle_in_transaction_session_timeout','idle_session_timeout',
  'max_connections','superuser_reserved_connections','reserved_connections',
  'max_locks_per_transaction','max_prepared_transactions','max_worker_processes','max_parallel_workers',
  'default_statistics_target','default_toast_compression','synchronous_commit','wal_level',
  'shared_preload_libraries','pg_stat_statements.max','pg_stat_statements.track','pg_stat_statements.track_utility'
)
ORDER BY name;


-- ============================================================================
-- 8c  Planner features switched off globally (pganalyze enable_features).
-- Anything other than the two partitionwise flags (off by default) → LOW.
-- ============================================================================
SELECT name, setting, boot_val, source
FROM pg_settings
WHERE name LIKE 'enable\_%' AND setting = 'off'
ORDER BY name;


-- ============================================================================
-- 8d  Memory budget arithmetic. RAM is not visible from SQL — the agent asks
-- the operator for it. work_mem is per sort/hash node, not per connection;
-- hash nodes get work_mem × hash_mem_multiplier. pganalyze work_mem check:
-- expected ≈ shared_buffers / max_connections, clamped 1 MB–256 MB.
-- ============================================================================
WITH s AS (
  SELECT
    (SELECT setting::bigint FROM pg_settings WHERE name = 'shared_buffers')
      * current_setting('block_size')::bigint                     AS shared_buffers_b,
    (SELECT setting::bigint * 1024 FROM pg_settings WHERE name = 'work_mem') AS work_mem_b,
    current_setting('max_connections')::int                        AS max_conn
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
-- 8e  Database-level counters (pg_stat_database). deadlocks > 0 → MEDIUM;
-- checksum_failures > 0 → CRITICAL (storage corruption); temp_files growing
-- → work_mem / missing index (cross-cite 5c); rollback_pct > 10 → app
-- error loop; sessions_abandoned high → client disconnects mid-query
-- (pooler timeouts). Rate everything against stats_age.
-- ============================================================================
SELECT
  datname, xact_commit, xact_rollback,
  round(100.0 * xact_rollback / NULLIF(xact_commit + xact_rollback, 0), 2) AS rollback_pct,
  deadlocks, conflicts,
  temp_files, pg_size_pretty(temp_bytes)                      AS temp_size,
  checksum_failures, checksum_last_failure,
  sessions, sessions_abandoned, sessions_fatal, sessions_killed,
  round((idle_in_transaction_time / 1000 / 3600)::numeric, 1) AS idle_in_xact_hours,
  current_setting('data_checksums')                           AS data_checksums,
  stats_reset, now() - stats_reset                            AS stats_age
FROM pg_stat_database
WHERE datname = current_database();


-- ============================================================================
-- 8f  Connection capacity. app_capacity excludes superuser_reserved_connections
-- and reserved_connections (PG16). app_capacity_used_pct > 80 → investigate,
-- > 90 → HIGH. Percona flags max_connections > 300 regardless of usage —
-- pooler territory (PgBouncer transaction mode).
-- ============================================================================
SELECT
  count(*)                                                       AS total,
  count(*) FILTER (WHERE state = 'active')                       AS active,
  count(*) FILTER (WHERE state = 'idle')                         AS idle,
  count(*) FILTER (WHERE state LIKE 'idle in transaction%')      AS idle_in_xact,
  count(*) FILTER (WHERE backend_type <> 'client backend')       AS non_client,
  current_setting('max_connections')::int                        AS max_connections,
  current_setting('superuser_reserved_connections')::int         AS superuser_reserved,
  current_setting('reserved_connections')::int                   AS reserved,
  current_setting('max_connections')::int
    - current_setting('superuser_reserved_connections')::int
    - current_setting('reserved_connections')::int               AS app_capacity,
  round(100.0 * count(*) FILTER (WHERE backend_type = 'client backend') /
        (current_setting('max_connections')::int
         - current_setting('superuser_reserved_connections')::int
         - current_setting('reserved_connections')::int), 1)     AS app_capacity_used_pct
FROM pg_stat_activity;


-- ============================================================================
-- 8g  Connections by state / user / app + idle-in-transaction duration tiers
-- (pganalyze idle_transaction: warn 30 min, critical 60 min). A large idle
-- share = client-side pool oversized. Many rows with application_name = ''
-- = nobody set it; recommend fixing so 4b/5j can attribute load.
-- ============================================================================
SELECT
  state, usename, application_name, count(*) AS backends,
  max(now() - state_change)                  AS oldest_in_state,
  count(*) FILTER (WHERE state = 'idle in transaction'
                     AND now() - state_change > interval '30 minutes') AS idle_in_xact_over_30m,
  count(*) FILTER (WHERE state = 'idle in transaction'
                     AND now() - state_change > interval '60 minutes') AS idle_in_xact_over_60m
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY state, usename, application_name
ORDER BY backends DESC
LIMIT 25;


-- ============================================================================
-- 8h  Sequence / column exhaustion. A bigint sequence feeding an int4 column
-- overflows at column_pct = 100, not seq_pct (Crunchy). > 10 → report;
-- > 50 → MEDIUM; > 80 → HIGH. last_value is NULL for sequences the role
-- cannot read — flag, don't guess.
-- ============================================================================
WITH seq AS (
  SELECT
    s.schemaname, s.sequencename, s.data_type::text AS seq_type,
    s.last_value, s.max_value, s.increment_by,
    d.refobjid::regclass        AS owned_table,
    a.attname                   AS owned_column,
    format_type(a.atttypid, NULL) AS column_type,
    CASE format_type(a.atttypid, NULL)
      WHEN 'smallint' THEN 32767::numeric
      WHEN 'integer'  THEN 2147483647::numeric
      WHEN 'bigint'   THEN 9223372036854775807::numeric
    END                         AS column_max
  FROM pg_sequences s
  JOIN pg_class c ON c.relname = s.sequencename
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = s.schemaname
  LEFT JOIN pg_depend d ON d.objid = c.oid AND d.classid = 'pg_class'::regclass
                        AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a','i')
  LEFT JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
  WHERE c.relkind = 'S'
)
SELECT
  schemaname, sequencename, seq_type, last_value,
  round(100.0 * last_value / NULLIF(max_value, 0), 2)  AS seq_pct,
  owned_table, owned_column, column_type,
  round(100.0 * last_value / NULLIF(column_max, 0), 2) AS column_pct
FROM seq
WHERE last_value IS NOT NULL AND increment_by > 0
ORDER BY GREATEST(100.0 * last_value / NULLIF(max_value, 0),
                  100.0 * last_value / NULLIF(column_max, 0)) DESC NULLS LAST
LIMIT 25;


-- ============================================================================
-- 8i  Lock table capacity. capacity = max_locks_per_transaction ×
-- (max_connections + max_prepared_transactions). A query touching a parent
-- with N partitions takes N+ locks per backend; locks_now near capacity or
-- max_partitions_per_parent × active backends approaching it → "out of
-- shared memory" errors. Fix: raise max_locks_per_transaction (restart;
-- standby must be >= primary).
-- ============================================================================
SELECT
  current_setting('max_locks_per_transaction')::int AS max_locks_per_xact,
  current_setting('max_connections')::int           AS max_connections,
  current_setting('max_prepared_transactions')::int AS max_prepared_xacts,
  current_setting('max_locks_per_transaction')::int *
   (current_setting('max_connections')::int
    + current_setting('max_prepared_transactions')::int)                 AS lock_table_capacity,
  (SELECT count(*) FROM pg_locks)                                         AS locks_now,
  (SELECT count(*) FROM pg_locks WHERE NOT fastpath)                      AS locks_non_fastpath,
  (SELECT max(cnt) FROM (SELECT count(*) AS cnt FROM pg_inherits
                         GROUP BY inhparent) p)                           AS max_partitions_per_parent;


-- ============================================================================
-- 8j  Extension versions behind the installed package. outdated = true →
-- LOW; ALTER EXTENSION ... UPDATE is needed to expose new columns
-- (pg_stat_statements 1.12 adds the PG18 parallel-worker columns).
-- ============================================================================
SELECT e.extname, e.extversion AS installed, a.default_version AS available,
       e.extversion IS DISTINCT FROM a.default_version AS outdated
FROM pg_extension e
JOIN pg_available_extensions a ON a.name = e.extname
ORDER BY outdated DESC, e.extname;

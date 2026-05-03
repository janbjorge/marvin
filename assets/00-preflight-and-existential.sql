-- postgres-health-review: 00-preflight-and-existential.sql
-- Run with: psql -X -f 00-preflight-and-existential.sql -d <database>
-- Sets safe session limits then runs Phase 0 (context) and Phase 1 (existential threats).
-- Read-only. No modifications.

\set QUIET on
\pset pager off
\pset null '(null)'
\timing off

-- ============================================================================
-- Self-protection
-- ============================================================================
SET application_name = 'health-review';
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET idle_in_transaction_session_timeout = '60s';
SET default_transaction_read_only = on;

\echo
\echo '================================================================'
\echo ' PHASE 0 — Context'
\echo '================================================================'

\echo
\echo '-- Version & role'
SELECT version() AS postgres_version;
SELECT
  current_setting('server_version_num')::int AS version_num,
  pg_is_in_recovery() AS is_replica,
  current_setting('cluster_name', true) AS cluster_name,
  pg_postmaster_start_time() AS started_at,
  now() - pg_postmaster_start_time() AS uptime;

\echo
\echo '-- Database sizes'
SELECT datname, pg_size_pretty(pg_database_size(oid)) AS size
FROM pg_database
WHERE NOT datistemplate
ORDER BY pg_database_size(oid) DESC;

\echo
\echo '-- Stats freshness (low confidence in unused-index findings if recent)'
SELECT datname, stats_reset, now() - stats_reset AS stats_age
FROM pg_stat_database
WHERE datname = current_database();

\echo
\echo '-- Available extensions'
SELECT extname, extversion
FROM pg_extension
WHERE extname IN (
  'pg_stat_statements','pgstattuple','pg_buffercache',
  'pg_repack','pg_squeeze','auto_explain','pg_visibility',
  'pg_freespacemap','pg_stat_kcache','pg_prewarm'
)
ORDER BY extname;

\echo
\echo '================================================================'
\echo ' PHASE 1a — Transaction ID wraparound risk'
\echo '================================================================'
\echo '   pct_to_emergency_av >= 90 = HIGH; >= 100 = CRITICAL'
\echo

SELECT
  datname,
  age(datfrozenxid) AS xid_age,
  current_setting('autovacuum_freeze_max_age')::bigint AS av_freeze_max_age,
  round(100.0 * age(datfrozenxid)::numeric /
        current_setting('autovacuum_freeze_max_age')::numeric, 1) AS pct_to_emergency_av,
  mxid_age(datminmxid) AS multixact_age,
  current_setting('autovacuum_multixact_freeze_max_age')::bigint AS av_mxid_max_age,
  round(100.0 * mxid_age(datminmxid)::numeric /
        current_setting('autovacuum_multixact_freeze_max_age')::numeric, 1) AS pct_to_emergency_mxid_av
FROM pg_database
WHERE datallowconn
ORDER BY age(datfrozenxid) DESC;

\echo
\echo '-- Per-table wraparound risk (tables > 50% of freeze_max_age)'
SELECT
  c.oid::regclass AS relation,
  age(c.relfrozenxid) AS xid_age,
  mxid_age(c.relminmxid) AS mxid_age,
  pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
  s.last_autovacuum,
  s.last_vacuum,
  s.n_dead_tup
FROM pg_class c
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind IN ('r','m','t')
  AND age(c.relfrozenxid) >
      current_setting('autovacuum_freeze_max_age')::bigint * 0.5
ORDER BY age(c.relfrozenxid) DESC
LIMIT 30;

\echo
\echo '================================================================'
\echo ' PHASE 1b — Replication slot bloat'
\echo '================================================================'
\echo '   Inactive slots with retained WAL > 10 GB are HIGH;'
\echo '   wal_status of "extended" or "lost" is CRITICAL.'
\echo

SELECT
  slot_name, plugin, slot_type, database,
  active, active_pid,
  pg_size_pretty(
    CASE
      WHEN restart_lsn IS NULL THEN 0
      ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    END
  ) AS retained_wal,
  wal_status,
  pg_size_pretty(safe_wal_size) AS safe_wal_size_remaining
FROM pg_replication_slots
ORDER BY
  CASE WHEN restart_lsn IS NULL THEN 0
       ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  END DESC NULLS LAST;

\echo
\echo '================================================================'
\echo ' PHASE 1c — Disk pressure (WAL volume)'
\echo '================================================================'
\echo

SELECT
  pg_size_pretty(sum(size)) AS total_wal_dir_size,
  count(*) AS wal_segment_count
FROM pg_ls_waldir();

-- Note: actual filesystem free space is best checked via OS tools (df -h)
-- Postgres only knows what it has written, not what the filesystem has free.

\echo
\echo '-- Preflight + existential checks complete --'

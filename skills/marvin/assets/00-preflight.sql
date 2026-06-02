-- marvin: 00-preflight.sql
-- Phase 0 — context. Capture environment facts the rest of the audit
-- branches on (PG major, replica status, DB size, stats freshness, extensions).
-- Read-only.
--
-- Execution model: labelled query catalogue for the pglens `query` MCP tool.
-- Not a psql script. Existential-threat checks (wraparound, slot bloat, WAL)
-- live in 01-existential-threats.sql so Phase 0 stays pure context.


-- ============================================================================
-- 0-version  PostgreSQL major version, recovery status, uptime.
-- Marvin requires PG16+. pg17_plus drives the one remaining branch
-- (pg_stat_checkpointer was split out of pg_stat_bgwriter in PG17).
-- If pg_ver < 160000 the audit should refuse to run and tell the user.
-- pg_is_in_recovery = true means standby/replica — no VACUUM, no DDL
-- recommendations should fire against this node.
-- ============================================================================
SELECT
  version()                                              AS postgres_version,
  current_setting('server_version_num')::int             AS pg_ver,
  current_setting('server_version_num')::int >= 160000   AS pg16_plus,
  current_setting('server_version_num')::int >= 170000   AS pg17_plus,
  pg_is_in_recovery()                                    AS is_replica,
  current_setting('cluster_name', true)                  AS cluster_name,
  pg_postmaster_start_time()                             AS started_at,
  now() - pg_postmaster_start_time()                     AS uptime;


-- ============================================================================
-- 0-sizes  Database sizes (cluster-wide).
-- ============================================================================
SELECT datname, pg_size_pretty(pg_database_size(oid)) AS size
FROM pg_database
WHERE NOT datistemplate
ORDER BY pg_database_size(oid) DESC;


-- ============================================================================
-- 0-stats-age  Stats freshness for the connected database.
-- Low confidence in unused-index and pg_stat_statements findings when this
-- is recent (< 7 days). Surface it as a caveat in the report, do not hide.
-- ============================================================================
SELECT datname, stats_reset, now() - stats_reset AS stats_age
FROM pg_stat_database
WHERE datname = current_database();


-- ============================================================================
-- 0-extensions  Which audit-relevant extensions are present?
-- Drives later phases:
--   pg_stat_statements  — Phase 5 hotspots
--   pgstattuple         — Phase 2 exact bloat fallback
--   pg_repack           — Remediation choice in the playbook
--   pg_buffercache      — Per-relation buffer attribution
--   auto_explain        — Plan capture for flagged queries
--   pg_wait_sampling    — Sustained wait-event distribution
--   pg_stat_kcache      — OS-level CPU / I/O per query
--   pg_prewarm          — Warm-cache restoration
--   pg_visibility       — Visibility map inspection
--   pg_freespacemap     — FSM inspection
-- ============================================================================
SELECT extname, extversion
FROM pg_extension
WHERE extname IN (
  'pg_stat_statements','pgstattuple','pg_buffercache',
  'pg_repack','pg_squeeze','auto_explain','pg_visibility',
  'pg_freespacemap','pg_stat_kcache','pg_prewarm','pg_wait_sampling'
)
ORDER BY extname;


-- ============================================================================
-- 0-key-settings  Tuning parameters the audit interprets.
-- ============================================================================
SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
  'shared_buffers','work_mem','maintenance_work_mem',
  'effective_cache_size','autovacuum','max_connections',
  'autovacuum_vacuum_scale_factor','autovacuum_analyze_scale_factor',
  'autovacuum_max_workers','default_statistics_target',
  'track_io_timing','log_min_duration_statement',
  'idle_in_transaction_session_timeout','max_wal_size'
);

-- marvin: 00-preflight.sql — Phase 0 context. Read-only.
-- Existential threats (wraparound, slot bloat, WAL) live in 01.

-- ============================================================================
-- 0-version  PG version, replica status, uptime.
-- pg16_plus is the floor (abort if false). pg17_plus drives 5b/5k/3c-progress
-- variants; pg18_plus drives 3f, 5i2, 7e [PG18].
-- is_replica → no VACUUM / DDL / pg_terminate_backend recommendations.
-- ============================================================================
SELECT
  version()                                              AS postgres_version,
  current_setting('server_version_num')::int             AS pg_ver,
  current_setting('server_version_num')::int >= 160000   AS pg16_plus,
  current_setting('server_version_num')::int >= 170000   AS pg17_plus,
  current_setting('server_version_num')::int >= 180000   AS pg18_plus,
  pg_is_in_recovery()                                    AS is_replica,
  current_setting('cluster_name', true)                  AS cluster_name,
  pg_postmaster_start_time()                             AS started_at,
  now() - pg_postmaster_start_time()                     AS uptime;


-- ============================================================================
-- 0-sizes  Database sizes.
-- ============================================================================
SELECT datname, pg_size_pretty(pg_database_size(oid)) AS size
FROM pg_database
WHERE NOT datistemplate
ORDER BY pg_database_size(oid) DESC;


-- ============================================================================
-- 0-stats-age  Stats freshness. < 30 days = do not call an index "unused"
-- (pganalyze 35 d, postgres.ai 1 month); < 7 days = lower confidence on
-- Phase 5 too. NULL = never reset since initdb (use uptime from 0-version).
-- ============================================================================
SELECT datname, stats_reset, now() - stats_reset AS stats_age
FROM pg_stat_database
WHERE datname = current_database();


-- ============================================================================
-- 0-extensions  Audit-relevant extensions.
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
-- 0-key-settings  Tuning parameters the audit reads. Full drift snapshot
-- lives in 08 (8b). PG18-only names (autovacuum_vacuum_max_threshold,
-- autovacuum_worker_slots, io_method, track_cost_delay_timing) return no
-- row on older majors — that is the version signal, not an error.
-- ============================================================================
SELECT name, setting, unit, boot_val, source
FROM pg_settings
WHERE name IN (
  'shared_buffers','work_mem','maintenance_work_mem','autovacuum_work_mem',
  'effective_cache_size','autovacuum','max_connections',
  'autovacuum_vacuum_scale_factor','autovacuum_analyze_scale_factor',
  'autovacuum_vacuum_insert_scale_factor','autovacuum_vacuum_max_threshold',
  'autovacuum_max_workers','autovacuum_worker_slots',
  'autovacuum_vacuum_cost_limit','autovacuum_vacuum_cost_delay',
  'default_statistics_target',
  'track_io_timing','track_wal_io_timing','track_cost_delay_timing',
  'log_min_duration_statement',
  'statement_timeout','lock_timeout','idle_in_transaction_session_timeout',
  'max_wal_size','max_slot_wal_keep_size','data_checksums','jit','io_method'
)
ORDER BY name;

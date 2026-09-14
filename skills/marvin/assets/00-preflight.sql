-- marvin: 00-preflight.sql — Phase 0 context. Read-only.
-- Existential threats (wraparound, slot bloat, WAL) live in 01.

-- ============================================================================
-- 0-version  pg16_plus is the floor (abort if false). pg17_plus picks the
-- 1b/5b/5k/3c-progress variants; pg18_plus unlocks 3f, 5i2, 7e [PG18].
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
-- 0-stats-age  unused_index_ok = false → never say "unused index" (say "no
-- scans in N d" and downgrade 6a one tier); phase5_ok = false → lower
-- confidence on Phase 5. stats_reset NULL = never reset (use uptime).
-- ============================================================================
SELECT datname, stats_reset, now() - stats_reset AS stats_age,
       COALESCE(now() - stats_reset, now() - pg_postmaster_start_time()) >= interval '30 days' AS unused_index_ok,
       COALESCE(now() - stats_reset, now() - pg_postmaster_start_time()) >= interval '7 days'  AS phase5_ok
FROM pg_stat_database
WHERE datname = current_database();


-- ============================================================================
-- 0-extensions  Installed extensions + newer package version available.
-- Gates: pg_stat_statements → 5-2, 5a–5e, 5b2; pgstattuple → Phase 2
-- follow-up; pg_wait_sampling → 5j follow-up. outdated = true → LOW
-- (ALTER EXTENSION ... UPDATE exposes new columns).
-- ============================================================================
SELECT e.extname, e.extversion AS installed, a.default_version AS available,
       e.extversion IS DISTINCT FROM a.default_version AS outdated
FROM pg_extension e
LEFT JOIN pg_available_extensions a ON a.name = e.extname
ORDER BY outdated DESC, e.extname;


-- ============================================================================
-- 0-settings  Every GUC the audit reads, once, plus any enable_* planner
-- flag switched off. changed = differs from compiled default (context, not
-- a defect). Names absent on this major return no row — the version signal.
-- severity carries the config rule; a qualifier ("if OLTP", "if SSD") means
-- confirm with the operator before reporting. Why: interpretation-
-- thresholds.md "Config sanity".
-- ============================================================================
SELECT name, setting, unit, boot_val,
       setting IS DISTINCT FROM boot_val AS changed,
       source, pending_restart,
       CASE
         WHEN name = 'fsync' AND setting = 'off'                                        THEN 'CRITICAL'
         WHEN name IN ('track_counts','track_activities') AND setting = 'off'           THEN 'HIGH'
         WHEN name = 'jit' AND setting = 'on'                                           THEN 'MEDIUM if OLTP'
         WHEN name = 'random_page_cost' AND setting::numeric >= 4                       THEN 'MEDIUM if SSD'
         WHEN name IN ('statement_timeout','lock_timeout','idle_in_transaction_session_timeout')
              AND setting = '0'                                                         THEN 'MEDIUM if OLTP'
         WHEN name = 'checkpoint_timeout' AND setting::int <= 300                       THEN 'MEDIUM if 5k req_pct > 30'
         WHEN name IN ('log_checkpoints','log_lock_waits') AND setting = 'off'          THEN 'LOW'
         WHEN name IN ('log_autovacuum_min_duration','log_temp_files') AND setting = '-1' THEN 'LOW'
         WHEN name = 'huge_pages_status' AND setting = 'off'                            THEN 'LOW if shared_buffers > 8 GB'
         WHEN name = 'data_checksums' AND setting = 'off'                               THEN 'LOW'
         WHEN name = 'effective_io_concurrency' AND setting = '1'
              AND current_setting('server_version_num')::int >= 180000                  THEN 'LOW (PG18 default is 16)'
         WHEN name = 'wal_compression' AND setting = 'off'                              THEN 'LOW if write-heavy'
         WHEN name LIKE 'enable\_%' AND name NOT LIKE 'enable\_partitionwise%'
              AND setting = 'off'                                                       THEN 'LOW'
       END AS severity
FROM pg_settings
WHERE name IN (
  -- durability / stats collection
  'fsync','full_page_writes','synchronous_commit','wal_level','data_checksums',
  'track_counts','track_activities','track_io_timing','track_wal_io_timing','track_cost_delay_timing',
  -- planner
  'jit','random_page_cost','seq_page_cost','effective_io_concurrency','maintenance_io_concurrency',
  'default_statistics_target',
  -- memory
  'shared_buffers','effective_cache_size','work_mem','hash_mem_multiplier',
  'maintenance_work_mem','autovacuum_work_mem','huge_pages','huge_pages_status',
  -- WAL / checkpoints
  'wal_compression','wal_buffers','checkpoint_timeout','checkpoint_completion_target',
  'max_wal_size','min_wal_size','wal_keep_size','max_slot_wal_keep_size','idle_replication_slot_timeout',
  -- autovacuum
  'autovacuum','autovacuum_max_workers','autovacuum_worker_slots','autovacuum_naptime',
  'autovacuum_vacuum_cost_limit','autovacuum_vacuum_cost_delay','vacuum_cost_limit',
  'autovacuum_vacuum_scale_factor','autovacuum_vacuum_threshold','autovacuum_vacuum_max_threshold',
  'autovacuum_vacuum_insert_scale_factor','autovacuum_analyze_scale_factor',
  'autovacuum_freeze_max_age','vacuum_failsafe_age',
  -- AIO (PG18)
  'io_method','io_workers','io_combine_limit',
  -- timeouts / connections / locks
  'statement_timeout','lock_timeout','idle_in_transaction_session_timeout','idle_session_timeout',
  'max_connections','superuser_reserved_connections','reserved_connections',
  'max_locks_per_transaction','max_prepared_transactions','max_worker_processes','max_parallel_workers',
  -- replication
  'max_wal_senders','max_replication_slots','hot_standby','hot_standby_feedback',
  'max_standby_streaming_delay','max_standby_archive_delay','wal_receiver_timeout','wal_sender_timeout',
  'synchronous_standby_names','logical_decoding_work_mem','max_logical_replication_workers',
  'max_sync_workers_per_subscription','archive_mode','archive_timeout','recovery_min_apply_delay',
  -- logging / extensions
  'log_checkpoints','log_lock_waits','log_autovacuum_min_duration','log_temp_files','log_min_duration_statement',
  'default_toast_compression','shared_preload_libraries',
  'pg_stat_statements.max','pg_stat_statements.track','pg_stat_statements.track_utility',
  'pg_stat_statements.track_planning'
)
   OR (name LIKE 'enable\_%' AND setting = 'off')
ORDER BY severity NULLS LAST, name;

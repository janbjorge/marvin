-- marvin: 07-replication.sql — Phase 7. Read-only. PG16+.
-- Physical + logical replication health. Run 7a/7c/7d on the primary, 7b/7g on
-- a standby. Lag in BYTES is the alertable signal; the *_lag intervals go NULL
-- on an idle primary (docs: monitoring-stats). Thresholds: pganalyze
-- high_lag — warn 100 MB, critical 1 GB sustained.

-- ============================================================================
-- 7a  Standbys seen from the primary. Empty when replicas are expected → HIGH
-- (pganalyze follower_missing). replay_lag_bytes >> flush_lag_bytes = replica
-- apply is the bottleneck (recovery conflict / slow disk), not the network.
-- backend_xmin non-NULL = hot_standby_feedback pins xmin on the primary (3a).
-- ============================================================================
SELECT
  pid, usename, application_name, client_addr, state, sync_state,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))   AS sent_lag_bytes,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn))  AS write_lag_bytes,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn))  AS flush_lag_bytes,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes,
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)                 AS replay_lag_raw,
  write_lag, flush_lag, replay_lag,
  backend_xmin, age(backend_xmin)                                   AS backend_xmin_age,
  backend_start, reply_time
FROM pg_stat_replication
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) DESC NULLS LAST;


-- ============================================================================
-- 7b  Standby self-check. All NULL on a primary (is_replica = false).
-- replay_delay is inflated on an idle primary — cite apply_backlog (bytes).
-- receiver_status <> 'streaming' → HIGH.
-- ============================================================================
SELECT
  pg_is_in_recovery()                                  AS is_replica,
  pg_last_wal_receive_lsn()                            AS receive_lsn,
  pg_last_wal_replay_lsn()                             AS replay_lsn,
  pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(),
                                 pg_last_wal_replay_lsn())) AS apply_backlog,
  pg_last_xact_replay_timestamp()                      AS last_replayed_xact,
  now() - pg_last_xact_replay_timestamp()              AS replay_delay,
  CASE WHEN pg_is_in_recovery() THEN pg_is_wal_replay_paused() END AS replay_paused,
  (SELECT status      FROM pg_stat_wal_receiver)       AS receiver_status,
  (SELECT sender_host FROM pg_stat_wal_receiver)       AS sender_host,
  (SELECT slot_name   FROM pg_stat_wal_receiver)       AS slot_name,
  current_setting('hot_standby_feedback')              AS hot_standby_feedback,
  current_setting('max_standby_streaming_delay')       AS max_standby_streaming_delay;


-- ============================================================================
-- 7c  Combined xmin horizon — every holder in one list (postgres.ai howto
-- 0045). Whichever row is oldest is what autovacuum is waiting on. The
-- pg_stat_replication row only appears with hot_standby_feedback = on.
-- pganalyze xmin_horizon: warn when the oldest is > 24 h.
-- ============================================================================
SELECT source, holder, xmin_age, detail FROM (
  SELECT 'pg_stat_activity.backend_xmin' AS source, pid::text AS holder,
         age(backend_xmin) AS xmin_age,
         format('%s | %s | %s', state, application_name, left(query, 80)) AS detail
  FROM pg_stat_activity WHERE backend_xmin IS NOT NULL
  UNION ALL
  SELECT 'pg_replication_slots.xmin', slot_name, age(xmin), slot_type::text
  FROM pg_replication_slots WHERE xmin IS NOT NULL
  UNION ALL
  SELECT 'pg_replication_slots.catalog_xmin', slot_name, age(catalog_xmin), plugin
  FROM pg_replication_slots WHERE catalog_xmin IS NOT NULL
  UNION ALL
  SELECT 'pg_stat_replication.backend_xmin', application_name, age(backend_xmin), client_addr::text
  FROM pg_stat_replication WHERE backend_xmin IS NOT NULL
  UNION ALL
  SELECT 'pg_prepared_xacts', gid, age(transaction), owner
  FROM pg_prepared_xacts
) h
WHERE holder IS DISTINCT FROM pg_backend_pid()::text
ORDER BY xmin_age DESC NULLS LAST
LIMIT 20;


-- ============================================================================
-- 7d  Logical slots — decoding lag + spill. confirmed_flush_lag = WAL the
-- consumer has not acknowledged. spill_bytes growing → logical_decoding_work_mem
-- (default 64 MB) too small; every spilled txn is a disk round-trip.
-- ============================================================================
SELECT
  s.slot_name, r.plugin, r.database, r.active,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), r.confirmed_flush_lsn)) AS confirmed_flush_lag,
  s.spill_txns, s.spill_count, pg_size_pretty(s.spill_bytes)  AS spilled,
  s.stream_txns, pg_size_pretty(s.stream_bytes)               AS streamed,
  s.total_txns,  pg_size_pretty(s.total_bytes)                AS total_decoded,
  current_setting('logical_decoding_work_mem')                AS logical_decoding_work_mem,
  s.stats_reset
FROM pg_stat_replication_slots s
JOIN pg_replication_slots r ON r.slot_name = s.slot_name
ORDER BY s.spill_bytes DESC NULLS LAST;


-- ============================================================================
-- 7e  Subscriptions (this DB is a logical subscriber). worker_alive = false on
-- an enabled subscription = apply worker crashed → HIGH. apply_error_count or
-- sync_error_count growing → HIGH (check the log for the failing row).
-- ============================================================================
SELECT
  sub.subname, sub.subenabled, sub.subslotname, sub.subpublications,
  st.pid                                  AS apply_worker_pid,
  st.pid IS NOT NULL                      AS worker_alive,
  st.received_lsn, st.latest_end_lsn, st.latest_end_time,
  now() - st.latest_end_time              AS since_last_end,
  ss.apply_error_count, ss.sync_error_count,
  ss.stats_reset
FROM pg_subscription sub
LEFT JOIN pg_stat_subscription st ON st.subid = sub.oid AND st.relid IS NULL
LEFT JOIN pg_stat_subscription_stats ss ON ss.subid = sub.oid
ORDER BY sub.subname;


-- ============================================================================
-- 7e [PG18]  Logical replication conflict counters (new in PG18). Any
-- non-zero column = rows silently skipped or errored on apply. Use when
-- pg18_plus = true; columns do not exist on PG16/17.
-- ============================================================================
SELECT subname,
  confl_insert_exists, confl_update_origin_differs, confl_update_exists,
  confl_update_missing, confl_delete_origin_differs, confl_delete_missing,
  confl_multiple_unique_conflicts
FROM pg_stat_subscription_stats
ORDER BY subname;


-- ============================================================================
-- 7f  Replication settings. max_slot_wal_keep_size = -1 (default) = a stuck
-- slot can fill the disk (1b safe_wal_size shows 'unbounded').
-- idle_replication_slot_timeout (PG18, default 0 = off) auto-invalidates idle
-- slots. hot_standby_feedback = on trades standby query cancels for primary
-- bloat (Cybertec). Read via pg_settings so missing GUCs return no row.
-- ============================================================================
SELECT name, setting, unit, boot_val, source, pending_restart
FROM pg_settings
WHERE name IN (
  'wal_level','max_wal_senders','max_replication_slots','wal_keep_size','max_slot_wal_keep_size',
  'idle_replication_slot_timeout','hot_standby','hot_standby_feedback','max_standby_streaming_delay',
  'max_standby_archive_delay','wal_receiver_status_interval','wal_receiver_timeout','wal_sender_timeout',
  'synchronous_commit','synchronous_standby_names','logical_decoding_work_mem','max_logical_replication_workers',
  'max_sync_workers_per_subscription','archive_mode','archive_timeout','recovery_min_apply_delay'
)
ORDER BY name;


-- ============================================================================
-- 7g  Recovery conflicts on a standby (cumulative since stats_reset). All
-- zero on a primary. confl_snapshot → hot_standby_feedback or longer
-- max_standby_streaming_delay; confl_lock → DDL on primary vs long standby
-- queries.
-- ============================================================================
SELECT datname, confl_tablespace, confl_lock, confl_snapshot, confl_bufferpin,
       confl_deadlock, confl_active_logicalslot
FROM pg_stat_database_conflicts
WHERE datname = current_database();

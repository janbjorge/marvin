-- marvin: 07-replication.sql — Phase 7. Read-only. PG16+.
-- 7a/7c/7d on the primary, 7b/7g on a standby. Lag in BYTES is the alertable
-- signal; *_lag intervals go NULL on an idle primary. Replication GUCs are in
-- 0-settings (max_slot_wal_keep_size = -1 with slots present → MEDIUM;
-- hot_standby_feedback = on → LOW, state the trade-off).

-- ============================================================================
-- 7a  Standbys seen from the primary. Empty when replicas are expected →
-- HIGH. severity: replay lag > 1 GB → HIGH, > 100 MB → MEDIUM (pganalyze).
-- apply_bottleneck = replay lag more than double flush lag (recovery
-- conflict / slow standby, see 7g). backend_xmin non-NULL = hot_standby_
-- feedback pinning xmin on the primary (7c).
-- ============================================================================
WITH r AS (
  SELECT *,
         pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)   AS sent_b,
         pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn)  AS write_b,
         pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn)  AS flush_b,
         pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_b
  FROM pg_stat_replication
)
SELECT
  pid, usename, application_name, client_addr, state, sync_state,
  pg_size_pretty(sent_b)   AS sent_lag_bytes,
  pg_size_pretty(write_b)  AS write_lag_bytes,
  pg_size_pretty(flush_b)  AS flush_lag_bytes,
  pg_size_pretty(replay_b) AS replay_lag_bytes,
  replay_b                 AS replay_lag_raw,
  write_lag, flush_lag, replay_lag,
  backend_xmin, age(backend_xmin) AS backend_xmin_age,
  backend_start, reply_time,
  replay_b > 2 * flush_b AND replay_b > 100 * 1024 * 1024 AS apply_bottleneck,
  CASE WHEN replay_b > 1024::bigint^3    THEN 'HIGH'
       WHEN replay_b > 100 * 1024 * 1024 THEN 'MEDIUM' END AS severity
FROM r
ORDER BY replay_b DESC NULLS LAST;


-- ============================================================================
-- 7b  Standby self-check. All NULL on a primary — not a finding. Cite
-- apply_backlog (bytes), not replay_delay (inflates when the primary idles).
-- severity HIGH = replica whose receiver is not streaming.
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
  CASE WHEN pg_is_in_recovery()
        AND (SELECT status FROM pg_stat_wal_receiver) IS DISTINCT FROM 'streaming'
       THEN 'HIGH' END                                 AS severity;


-- ============================================================================
-- 7c  Combined xmin horizon — every holder, oldest first (postgres.ai howto
-- 0045). The top row is what autovacuum waits on. xmin_age is in
-- transactions; time-based severity comes from 3a for session holders.
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
-- 7d  Logical slots — decoding lag + spill. severity MEDIUM = spill_bytes > 0
-- (confirm growth) → raise logical_decoding_work_mem (default 64 MB).
-- ============================================================================
SELECT
  s.slot_name, r.plugin, r.database, r.active,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), r.confirmed_flush_lsn)) AS confirmed_flush_lag,
  s.spill_txns, s.spill_count, pg_size_pretty(s.spill_bytes)  AS spilled,
  s.stream_txns, pg_size_pretty(s.stream_bytes)               AS streamed,
  s.total_txns,  pg_size_pretty(s.total_bytes)                AS total_decoded,
  current_setting('logical_decoding_work_mem')                AS logical_decoding_work_mem,
  s.stats_reset,
  CASE WHEN s.spill_bytes > 0 THEN 'MEDIUM' END               AS severity
FROM pg_stat_replication_slots s
JOIN pg_replication_slots r ON r.slot_name = s.slot_name
ORDER BY s.spill_bytes DESC NULLS LAST;


-- ============================================================================
-- 7e  Subscriptions (this DB is a logical subscriber). severity HIGH =
-- enabled with no apply worker, or any apply/sync errors (check the log).
-- ============================================================================
SELECT
  sub.subname, sub.subenabled, sub.subslotname, sub.subpublications,
  st.pid                                  AS apply_worker_pid,
  st.pid IS NOT NULL                      AS worker_alive,
  st.received_lsn, st.latest_end_lsn, st.latest_end_time,
  now() - st.latest_end_time              AS since_last_end,
  ss.apply_error_count, ss.sync_error_count, ss.stats_reset,
  CASE WHEN (sub.subenabled AND st.pid IS NULL)
         OR ss.apply_error_count > 0 OR ss.sync_error_count > 0 THEN 'HIGH' END AS severity
FROM pg_subscription sub
LEFT JOIN pg_stat_subscription st ON st.subid = sub.oid AND st.relid IS NULL
LEFT JOIN pg_stat_subscription_stats ss ON ss.subid = sub.oid
ORDER BY sub.subname;


-- ============================================================================
-- 7e [PG18]  Logical replication conflict counters. severity MEDIUM = any
-- non-zero (rows skipped or errored on apply). Use when pg18_plus = true.
-- ============================================================================
SELECT subname,
  confl_insert_exists, confl_update_origin_differs, confl_update_exists,
  confl_update_missing, confl_delete_origin_differs, confl_delete_missing,
  confl_multiple_unique_conflicts,
  CASE WHEN confl_insert_exists + confl_update_origin_differs + confl_update_exists
          + confl_update_missing + confl_delete_origin_differs + confl_delete_missing
          + confl_multiple_unique_conflicts > 0 THEN 'MEDIUM' END AS severity
FROM pg_stat_subscription_stats
ORDER BY subname;


-- ============================================================================
-- 7g  Recovery conflicts on a standby (cumulative). All zero on a primary.
-- confl_snapshot → hot_standby_feedback or longer max_standby_streaming_delay;
-- confl_lock → DDL on primary vs long standby queries.
-- ============================================================================
SELECT datname, confl_tablespace, confl_lock, confl_snapshot, confl_bufferpin,
       confl_deadlock, confl_active_logicalslot
FROM pg_stat_database_conflicts
WHERE datname = current_database();

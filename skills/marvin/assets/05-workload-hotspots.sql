-- marvin: 05-workload-hotspots.sql — Phase 5. PG16+. Read-only.
-- Gates from Phase 0: pg_stat_statements in 0-extensions → 5-2, 5a–5e, 5b2;
-- track_io_timing (0-settings) = off → rank 5b by shared_blks_read and say so;
-- pg17_plus picks 5b / 5k variants; pg18_plus adds 5i2.

-- ============================================================================
-- 5-2  pg_stat_statements freshness + eviction. Run first. dealloc > 0 =
-- .max was hit and least-executed entries were evicted → every 5a–5e
-- ranking is biased toward survivors; say so and recommend raising
-- pg_stat_statements.max (default 5000; restart). pganalyze: ~100 / 10 min
-- is concerning.
-- ============================================================================
SELECT
  i.dealloc, i.stats_reset, now() - i.stats_reset                         AS stats_age,
  (SELECT count(*) FROM pg_stat_statements)                               AS entries,
  (SELECT setting::int FROM pg_settings WHERE name = 'pg_stat_statements.max') AS pgss_max,
  CASE WHEN i.dealloc > 0 THEN 'MEDIUM' END                               AS severity
FROM pg_stat_statements_info i;


-- ============================================================================
-- 5a  Top by total time (plan + exec). severity HIGH = pct_total >= 25, or
-- mean_ms > 1000 with calls > 100.
-- ============================================================================
WITH q AS (
  SELECT *,
         total_plan_time + total_exec_time AS total_time,
         round((100 * (total_plan_time + total_exec_time) /
                NULLIF(sum(total_plan_time + total_exec_time) OVER (), 0))::numeric, 1) AS pct_total
  FROM pg_stat_statements
)
SELECT
  round(total_time::numeric, 0)                                       AS total_ms,
  round(total_plan_time::numeric, 0)                                  AS plan_ms,
  round(total_exec_time::numeric, 0)                                  AS exec_ms,
  calls,
  round((total_time / NULLIF(calls, 0))::numeric, 1)                  AS mean_ms,
  pct_total,
  rows,
  round((rows::numeric / NULLIF(calls, 0)), 1)                        AS rows_per_call,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)                   AS query,
  CASE WHEN pct_total >= 25
         OR (total_time / NULLIF(calls, 0) > 1000 AND calls > 100) THEN 'HIGH' END AS severity
FROM q
ORDER BY total_time DESC
LIMIT 15;


-- ============================================================================
-- 5b [PG16]  Top by disk I/O (blk_*_time). io_ms needs track_io_timing = on.
-- Use when pg17_plus = false.
-- ============================================================================
SELECT
  round((blk_read_time + blk_write_time)::numeric, 0) AS io_ms,
  round(blk_read_time::numeric, 0)                    AS read_ms,
  round(blk_write_time::numeric, 0)                   AS write_ms,
  shared_blks_read, shared_blks_hit,
  round((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 1) AS hit_pct,
  calls,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)  AS query
FROM pg_stat_statements
WHERE shared_blks_read > 0
ORDER BY (blk_read_time + blk_write_time) DESC NULLS LAST, shared_blks_read DESC
LIMIT 15;


-- ============================================================================
-- 5b [PG17+]  Same; PG17 split blk_*_time into shared/local/temp. Use when
-- pg17_plus = true.
-- ============================================================================
SELECT
  round((shared_blk_read_time + shared_blk_write_time)::numeric, 0) AS io_ms,
  round(shared_blk_read_time::numeric, 0)                           AS read_ms,
  round(shared_blk_write_time::numeric, 0)                          AS write_ms,
  shared_blks_read, shared_blks_hit,
  round((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 1) AS hit_pct,
  calls,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)  AS query
FROM pg_stat_statements
WHERE shared_blks_read > 0
ORDER BY (shared_blk_read_time + shared_blk_write_time) DESC NULLS LAST, shared_blks_read DESC
LIMIT 15;


-- ============================================================================
-- 5b2  Top WAL producers. High wal_bytes/call → wide UPDATEs or non-HOT
-- index churn (5g).
-- ============================================================================
SELECT
  pg_size_pretty(wal_bytes)                          AS wal_size,
  wal_bytes, wal_records, wal_fpi, calls,
  round((wal_bytes::numeric / NULLIF(calls, 0)), 0)  AS wal_bytes_per_call,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)  AS query
FROM pg_stat_statements
WHERE wal_bytes > 0
ORDER BY wal_bytes DESC
LIMIT 15;


-- ============================================================================
-- 5b3  Cluster WAL profile (pg_stat_wal). severity MEDIUM = wal_buffers_full
-- > 0 (confirm growth with a second sample) → raise wal_buffers. High
-- fpi_pct_of_records + 5k req_pct > 30 = short checkpoints inflating FPIs:
-- raise checkpoint_timeout / max_wal_size before wal_compression.
-- ============================================================================
SELECT
  wal_records, wal_fpi,
  pg_size_pretty(wal_bytes)                                AS wal_size,
  round(100.0 * wal_fpi / NULLIF(wal_records, 0), 1)       AS fpi_pct_of_records,
  wal_buffers_full,
  current_setting('wal_buffers')                           AS wal_buffers,
  current_setting('wal_compression')                       AS wal_compression,
  stats_reset, now() - stats_reset                         AS stats_age,
  CASE WHEN wal_buffers_full > 0 THEN 'MEDIUM' END         AS severity
FROM pg_stat_wal;


-- ============================================================================
-- 5c  Top temp-file writers. work_mem too low or missing index for sort/hash.
-- ============================================================================
SELECT
  temp_blks_written, temp_blks_read,
  pg_size_pretty(temp_blks_written * current_setting('block_size')::bigint) AS temp_written,
  calls,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)    AS query
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 15;


-- ============================================================================
-- 5d  Plan instability. severity MEDIUM = coeff_var > 1 (calls >= 100 by
-- filter): plan flips / parameter sensitivity. Pair with auto_explain.
-- ============================================================================
SELECT
  calls,
  round(mean_exec_time::numeric, 1)                                 AS mean_ms,
  round(stddev_exec_time::numeric, 1)                               AS stddev_ms,
  round((stddev_exec_time / NULLIF(mean_exec_time, 0))::numeric, 2) AS coeff_var,
  round(min_exec_time::numeric, 1)                                  AS min_ms,
  round(max_exec_time::numeric, 1)                                  AS max_ms,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)                 AS query,
  CASE WHEN stddev_exec_time / NULLIF(mean_exec_time, 0) > 1 THEN 'MEDIUM' END AS severity
FROM pg_stat_statements
WHERE calls >= 100 AND mean_exec_time > 1
ORDER BY (stddev_exec_time / NULLIF(mean_exec_time, 0)) DESC NULLS LAST
LIMIT 15;


-- ============================================================================
-- 5e  Rows per call. High → missing LIMIT, bad pagination, N+1 fan-out.
-- ============================================================================
SELECT
  calls, rows,
  round((rows::numeric / NULLIF(calls, 0)), 0)        AS rows_per_call,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)   AS query
FROM pg_stat_statements
WHERE calls >= 50
ORDER BY (rows::numeric / NULLIF(calls, 0)) DESC NULLS LAST
LIMIT 15;


-- ============================================================================
-- 5f  Seq-scan-dominated tables (> 100 MB). severity HIGH = seq_pct > 80 on
-- a table > 1 GB → missing index. last_*_scan survive stats resets.
-- ============================================================================
WITH t AS (
  SELECT schemaname, relname, relid, seq_scan, idx_scan, seq_tup_read, n_live_tup,
         last_seq_scan, last_idx_scan,
         pg_relation_size(relid) AS bytes,
         round((100.0 * seq_scan / NULLIF(seq_scan + COALESCE(idx_scan, 0), 0))::numeric, 1) AS seq_pct
  FROM pg_stat_user_tables
  WHERE pg_relation_size(relid) > 100 * 1024 * 1024 AND seq_scan > 0
)
SELECT
  schemaname, relname, seq_scan, idx_scan, seq_pct, seq_tup_read,
  round((seq_tup_read::numeric / NULLIF(seq_scan, 0)), 0) AS avg_tup_per_seqscan,
  last_seq_scan, last_idx_scan,
  pg_size_pretty(bytes)                                   AS size,
  n_live_tup,
  CASE WHEN seq_pct > 80 AND bytes > 1024::bigint^3 THEN 'HIGH' END AS severity
FROM t
ORDER BY seq_tup_read DESC
LIMIT 15;


-- ============================================================================
-- 5g  HOT update efficiency. severity MEDIUM = hot_pct < 50 with > 1 M
-- updates → index churn, faster bloat: lower fillfactor or stop updating
-- indexed columns. n_tup_newpage_upd = non-HOT row placed on a new page.
-- ============================================================================
SELECT
  schemaname, relname, n_tup_upd, n_tup_hot_upd, n_tup_newpage_upd,
  round((100.0 * n_tup_hot_upd / NULLIF(n_tup_upd, 0))::numeric, 1) AS hot_pct,
  pg_size_pretty(pg_relation_size(relid))                          AS size,
  CASE WHEN 100.0 * n_tup_hot_upd / NULLIF(n_tup_upd, 0) < 50
        AND n_tup_upd > 1000000 THEN 'MEDIUM' END                  AS severity
FROM pg_stat_user_tables
WHERE n_tup_upd > 10000
ORDER BY n_tup_upd DESC
LIMIT 15;


-- ============================================================================
-- 5h  Per-table heap cache hit (>= 10k touches). severity HIGH = hit_pct < 90
-- — directional only (OS cache invisible); attribute with 5i.
-- ============================================================================
SELECT
  schemaname, relname, heap_blks_read, heap_blks_hit,
  round((100.0 * heap_blks_hit / NULLIF(heap_blks_hit + heap_blks_read, 0))::numeric, 2) AS hit_pct,
  pg_size_pretty(pg_relation_size(relid))          AS size,
  CASE WHEN 100.0 * heap_blks_hit / NULLIF(heap_blks_hit + heap_blks_read, 0) < 90
       THEN 'HIGH' END                             AS severity
FROM pg_statio_user_tables
WHERE heap_blks_read + heap_blks_hit > 10000
ORDER BY hit_pct ASC NULLS FIRST
LIMIT 15;


-- ============================================================================
-- 5i  pg_stat_io by backend type + context. WAL rows (PG18) excluded so the
-- ranking means the same on every major; WAL I/O is 5i2.
-- ============================================================================
SELECT backend_type, object, context, reads, writes, extends, hits, evictions, fsyncs
FROM pg_stat_io
WHERE (reads > 0 OR writes > 0 OR extends > 0) AND object <> 'wal'
ORDER BY (COALESCE(reads,0) + COALESCE(writes,0) + COALESCE(extends,0)) DESC
LIMIT 30;


-- ============================================================================
-- 5i2 [PG18]  WAL I/O by backend. Timings need track_wal_io_timing = on.
-- 'client backend' doing most writes/fsyncs = backends flushing WAL at
-- commit. avg_fsync_ms > 5 on SSD = storage latency. Use when pg18_plus.
-- ============================================================================
SELECT
  backend_type, context,
  writes, pg_size_pretty(write_bytes)              AS written,
  round(write_time::numeric, 0)                    AS write_ms,
  fsyncs, round(fsync_time::numeric, 0)            AS fsync_ms,
  round((fsync_time / NULLIF(fsyncs, 0))::numeric, 2) AS avg_fsync_ms,
  reads, pg_size_pretty(read_bytes)                AS read,
  round(read_time::numeric, 0)                     AS read_ms,
  fsync_time / NULLIF(fsyncs, 0) > 5               AS slow_fsync
FROM pg_stat_io
WHERE object = 'wal' AND (writes > 0 OR reads > 0 OR fsyncs > 0)
ORDER BY writes DESC;


-- ============================================================================
-- 5j  Wait events, single snapshot. Sustained → pg_wait_sampling or sample
-- 1 s × 60. NULL type = on CPU; IO = disk; LWLock = buffer/WAL/lock manager;
-- Lock → Phase 4. PG18 AioIoCompletion is an I/O wait.
-- ============================================================================
SELECT
  COALESCE(wait_event_type, '(running on CPU)') AS wait_event_type,
  COALESCE(wait_event, '-')                     AS wait_event,
  state, count(*)                               AS backends
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
GROUP BY wait_event_type, wait_event, state
ORDER BY count(*) DESC;


-- ============================================================================
-- 5k [PG16]  Checkpoint pressure (pg_stat_bgwriter). severity MEDIUM =
-- req_pct > 30 → raise max_wal_size (and checkpoint_timeout if still 300 s).
-- Only meaningful against stats_age. Use when pg17_plus = false.
-- ============================================================================
WITH c AS (
  SELECT *, round((100.0 * checkpoints_req /
                   NULLIF(checkpoints_timed + checkpoints_req, 0))::numeric, 1) AS req_pct
  FROM pg_stat_bgwriter
)
SELECT
  checkpoints_timed, checkpoints_req, req_pct,
  round(checkpoint_write_time::numeric, 0)        AS write_ms,
  round(checkpoint_sync_time::numeric, 0)         AS sync_ms,
  buffers_checkpoint, buffers_backend,
  stats_reset, now() - stats_reset                AS stats_age,
  CASE WHEN req_pct > 30 THEN 'MEDIUM' END        AS severity
FROM c;


-- ============================================================================
-- 5k [PG17+]  Same from pg_stat_checkpointer. restartpoints_* nonzero on
-- replicas. PG18 adds num_done / slru_written (select by hand). Use when
-- pg17_plus = true.
-- ============================================================================
WITH c AS (
  SELECT *, round((100.0 * num_requested /
                   NULLIF(num_timed + num_requested, 0))::numeric, 1) AS req_pct
  FROM pg_stat_checkpointer
)
SELECT
  num_timed, num_requested, req_pct,
  round(write_time::numeric, 0)                   AS write_ms,
  round(sync_time::numeric, 0)                    AS sync_ms,
  buffers_written, restartpoints_timed, restartpoints_req,
  stats_reset, now() - stats_reset                AS stats_age,
  CASE WHEN req_pct > 30 THEN 'MEDIUM' END        AS severity
FROM c;


-- ============================================================================
-- 5l  Partition candidates (LOW, informational). Non-partitioned heaps
-- > 50 GB: per-partition autovacuum tuning + DROP instead of mass DELETE.
-- ============================================================================
SELECT
  c.oid::regclass                                AS table_name,
  pg_size_pretty(pg_total_relation_size(c.oid))  AS total_size,
  s.n_live_tup, s.seq_scan, s.n_tup_del
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind = 'r' AND NOT c.relispartition
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND pg_total_relation_size(c.oid) > 50 * 1024::bigint^3
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 15;

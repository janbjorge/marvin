-- marvin: 05-workload-hotspots.sql — Phase 5. PG16+. Read-only.
-- Severity rubric in SKILL.md §D. Agent picks 5b [PG16] vs [PG17+] via pg17_plus.

-- ============================================================================
-- 5-0  Preflight: version + track_io_timing.
-- ============================================================================
SELECT
  current_setting('server_version_num')::int       AS pg_ver,
  current_setting('server_version_num')::int >= 170000 AS pg17_plus,
  current_setting('track_io_timing')               AS track_io_timing;


-- ============================================================================
-- 5-1  pg_stat_statements present? Empty → skip 5a–5e + 5b2.
-- ============================================================================
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_stat_statements';


-- ============================================================================
-- 5-2  pg_stat_statements freshness. Interpret 5a–5e against stats_age.
-- ============================================================================
SELECT stats_reset, now() - stats_reset AS stats_age
FROM pg_stat_statements_info;


-- ============================================================================
-- 5a  Top by total time (plan + exec). pct_total >= 25 → biggest single win.
-- ============================================================================
SELECT
  round((total_plan_time + total_exec_time)::numeric, 0)              AS total_ms,
  round(total_plan_time::numeric, 0)                                  AS plan_ms,
  round(total_exec_time::numeric, 0)                                  AS exec_ms,
  calls,
  round(((total_plan_time + total_exec_time) / NULLIF(calls, 0))::numeric, 1)
                                                                      AS mean_ms,
  round((100 * (total_plan_time + total_exec_time) /
         NULLIF(sum(total_plan_time + total_exec_time) OVER (), 0))::numeric, 1)
                                                                      AS pct_total,
  rows,
  round((rows::numeric / NULLIF(calls, 0)), 1)                        AS rows_per_call,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)                   AS query
FROM pg_stat_statements
ORDER BY (total_plan_time + total_exec_time) DESC
LIMIT 15;


-- ============================================================================
-- 5b [PG16]  Top by disk I/O. Unsplit blk_*_time columns.
-- io_ms meaningful only when track_io_timing = on.
-- ============================================================================
SELECT
  round((blk_read_time + blk_write_time)::numeric, 0) AS io_ms,
  round(blk_read_time::numeric, 0)                    AS read_ms,
  round(blk_write_time::numeric, 0)                   AS write_ms,
  shared_blks_read,
  shared_blks_hit,
  CASE WHEN shared_blks_hit + shared_blks_read > 0
       THEN round((100.0 * shared_blks_hit /
                   (shared_blks_hit + shared_blks_read))::numeric, 1)
       ELSE NULL
  END                                                AS hit_pct,
  calls,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)  AS query
FROM pg_stat_statements
WHERE shared_blks_read > 0
ORDER BY (blk_read_time + blk_write_time) DESC NULLS LAST,
         shared_blks_read DESC
LIMIT 15;


-- ============================================================================
-- 5b [PG17+]  Top by disk I/O. PG17 split blk_*_time → shared/local/temp;
-- old columns removed. Use when pg17_plus = true.
-- ============================================================================
SELECT
  round((shared_blk_read_time + shared_blk_write_time)::numeric, 0) AS io_ms,
  round(shared_blk_read_time::numeric, 0)                           AS read_ms,
  round(shared_blk_write_time::numeric, 0)                          AS write_ms,
  shared_blks_read,
  shared_blks_hit,
  CASE WHEN shared_blks_hit + shared_blks_read > 0
       THEN round((100.0 * shared_blks_hit /
                   (shared_blks_hit + shared_blks_read))::numeric, 1)
       ELSE NULL
  END                                                AS hit_pct,
  calls,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)  AS query
FROM pg_stat_statements
WHERE shared_blks_read > 0
ORDER BY (shared_blk_read_time + shared_blk_write_time) DESC NULLS LAST,
         shared_blks_read DESC
LIMIT 15;


-- ============================================================================
-- 5b2  Top WAL producers. High wal_bytes/call → wide UPDATEs or non-HOT
-- index churn (5g).
-- ============================================================================
SELECT
  pg_size_pretty(wal_bytes)                          AS wal_size,
  wal_bytes,
  wal_records,
  wal_fpi,
  calls,
  round((wal_bytes::numeric / NULLIF(calls, 0)), 0)  AS wal_bytes_per_call,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)  AS query
FROM pg_stat_statements
WHERE wal_bytes > 0
ORDER BY wal_bytes DESC
LIMIT 15;


-- ============================================================================
-- 5c  Top temp-file writers. work_mem too low or missing index for sort/hash.
-- ============================================================================
SELECT
  temp_blks_written,
  temp_blks_read,
  pg_size_pretty((temp_blks_written * current_setting('block_size')::bigint))
                                                       AS temp_written,
  calls,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)    AS query
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 15;


-- ============================================================================
-- 5d  Plan instability. coeff_var > 1 + calls > 100 = plan flips / param
-- sensitivity / cache variance. Pair with auto_explain.
-- ============================================================================
SELECT
  calls,
  round(mean_exec_time::numeric, 1)                                AS mean_ms,
  round(stddev_exec_time::numeric, 1)                              AS stddev_ms,
  round((stddev_exec_time / NULLIF(mean_exec_time, 0))::numeric, 2) AS coeff_var,
  round(min_exec_time::numeric, 1)                                 AS min_ms,
  round(max_exec_time::numeric, 1)                                 AS max_ms,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)                AS query
FROM pg_stat_statements
WHERE calls >= 100
  AND mean_exec_time > 1
ORDER BY (stddev_exec_time / NULLIF(mean_exec_time, 0)) DESC NULLS LAST
LIMIT 15;


-- ============================================================================
-- 5e  Rows per call. High → missing LIMIT, bad pagination, N+1 fan-out.
-- ============================================================================
SELECT
  calls,
  rows,
  round((rows::numeric / NULLIF(calls, 0)), 0)        AS rows_per_call,
  left(regexp_replace(query, '\s+', ' ', 'g'), 200)   AS query
FROM pg_stat_statements
WHERE calls >= 50
ORDER BY (rows::numeric / NULLIF(calls, 0)) DESC NULLS LAST
LIMIT 15;


-- ============================================================================
-- 5f  Seq-scan-dominated tables. seq_pct > 80 on > 100 MB → missing index.
-- ============================================================================
SELECT
  schemaname, relname,
  seq_scan, idx_scan,
  CASE WHEN seq_scan + COALESCE(idx_scan, 0) > 0
       THEN round((100.0 * seq_scan /
                   (seq_scan + COALESCE(idx_scan, 0)))::numeric, 1)
       ELSE 0
  END                                              AS seq_pct,
  seq_tup_read,
  CASE WHEN seq_scan > 0
       THEN round((seq_tup_read::numeric / seq_scan), 0)
       ELSE 0
  END                                              AS avg_tup_per_seqscan,
  pg_size_pretty(pg_relation_size(relid))          AS size,
  n_live_tup
FROM pg_stat_user_tables
WHERE pg_relation_size(relid) > 100 * 1024 * 1024
  AND seq_scan > 0
ORDER BY seq_tup_read DESC
LIMIT 15;


-- ============================================================================
-- 5f2  Last seq/idx scan timestamps (survive stats resets).
-- ============================================================================
SELECT
  schemaname, relname,
  seq_scan,
  last_seq_scan,
  idx_scan,
  last_idx_scan,
  pg_size_pretty(pg_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE pg_relation_size(relid) > 100 * 1024 * 1024
ORDER BY last_seq_scan DESC NULLS LAST
LIMIT 15;


-- ============================================================================
-- 5g  HOT update efficiency. hot_pct < 50 + heavy updates = index churn,
-- write amplification, faster bloat. Lower fillfactor or stop updating the
-- indexed column. n_tup_newpage_upd = row placed on new page (non-HOT,
-- non-cold) — distinguishes from cold updates reachable via index.
-- ============================================================================
SELECT
  schemaname, relname,
  n_tup_upd,
  n_tup_hot_upd,
  n_tup_newpage_upd,
  CASE WHEN n_tup_upd > 0
       THEN round((100.0 * n_tup_hot_upd / n_tup_upd)::numeric, 1)
       ELSE NULL
  END                                              AS hot_pct,
  pg_size_pretty(pg_relation_size(relid))          AS size
FROM pg_stat_user_tables
WHERE n_tup_upd > 10000
ORDER BY n_tup_upd DESC
LIMIT 15;


-- ============================================================================
-- 5h  Per-table heap cache hit (>= 10k touches). Low + large → working set
-- > shared_buffers. Better attribution: 5i.
-- ============================================================================
SELECT
  schemaname, relname,
  heap_blks_read,
  heap_blks_hit,
  CASE WHEN heap_blks_hit + heap_blks_read > 0
       THEN round((100.0 * heap_blks_hit /
                   (heap_blks_hit + heap_blks_read))::numeric, 2)
       ELSE NULL
  END                                              AS hit_pct,
  pg_size_pretty(pg_relation_size(relid))          AS size
FROM pg_statio_user_tables
WHERE heap_blks_read + heap_blks_hit > 10000
ORDER BY hit_pct ASC NULLS FIRST
LIMIT 15;


-- ============================================================================
-- 5i  pg_stat_io — I/O by backend type + context (normal/vacuum/bulk*).
-- ============================================================================
SELECT
  backend_type, object, context,
  reads, writes, extends, hits, evictions, fsyncs
FROM pg_stat_io
WHERE (reads > 0 OR writes > 0 OR extends > 0)
ORDER BY (COALESCE(reads,0) + COALESCE(writes,0) + COALESCE(extends,0)) DESC
LIMIT 30;


-- ============================================================================
-- 5j  Wait events (single snapshot). Sustained → install pg_wait_sampling
-- or sample every 1s for a minute. wait_event_type: NULL=on-CPU, IO=disk,
-- LWLock=buffer/WAL/lock-manager, Lock→Phase 4, Client/IPC/Timeout.
-- ============================================================================
SELECT
  COALESCE(wait_event_type, '(running on CPU)') AS wait_event_type,
  COALESCE(wait_event, '-')                     AS wait_event,
  state,
  count(*)                                      AS backends
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND pid <> pg_backend_pid()
GROUP BY wait_event_type, wait_event, state
ORDER BY count(*) DESC;


-- ============================================================================
-- 5j2  pg_wait_sampling present?
-- ============================================================================
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_wait_sampling';

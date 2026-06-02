-- marvin: 05-workload-hotspots.sql
-- Phase 5 — workload hotspots: where the load is and why it hurts.
-- Read-only. Catalog views only.
-- Target: PostgreSQL 16+.
--
-- Execution model: each "-- ===" block below is one query the agent
-- runs via the pglens `query` MCP tool. Not a psql script — no \echo,
-- no \if, no \gset. Single statements per block, agent picks blocks based
-- on the preflight flags (00-preflight.sql).
--
-- Order of operations:
--   5-0  Preflight: capture version flags + track_io_timing.
--   5-1  pg_stat_statements extension check.
--   5-2  pg_stat_statements_info freshness.
--   5a   Top by total exec time (plan + exec).
--   5b   Top by disk I/O.
--   5b2  Top WAL producers.
--   5c   Top temp-file writers.
--   5d   Plan instability.
--   5e   Unbounded result sets.
--   5f   Sequential-scan-dominated tables.
--   5f2  Last seq/idx scan timestamps.
--   5g   HOT update efficiency.
--   5h   Per-table cache hit ratio.
--   5i   pg_stat_io I/O attribution.
--   5j   Live wait-event distribution.
--
-- Severity rules live in SKILL.md Section D.


-- ============================================================================
-- 5-0  Preflight: capture version + I/O timing flag.
-- ============================================================================
SELECT
  current_setting('server_version_num')::int       AS pg_ver,
  current_setting('server_version_num')::int >= 170000 AS pg17_plus,
  current_setting('track_io_timing')               AS track_io_timing;


-- ============================================================================
-- 5-1  pg_stat_statements present?
-- If empty result → recommend the extension; skip 5a-5e + 5b2.
-- ============================================================================
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_stat_statements';


-- ============================================================================
-- 5-2  Cumulative-stats freshness.
-- Interpret 5a-5e in light of the reported stats_age.
-- ============================================================================
SELECT stats_reset, now() - stats_reset AS stats_age
FROM pg_stat_statements_info;


-- ============================================================================
-- 5a  Top by total time (plan + exec) — where time is spent.
-- pct_total >= 25 → biggest single tuning win.
-- mean_ms  > 1000 with calls > 100 → per-call pain.
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
-- 5b [PG16]  Top by disk I/O (cache misses + I/O time).
-- PG16 still has the unsplit blk_read_time / blk_write_time columns.
-- io_ms is meaningful only when track_io_timing = on (see 5-0).
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
-- 5b [PG17+]  Top by disk I/O — PG17 split blk_*_time into shared / local /
-- temp variants. The old blk_read_time / blk_write_time columns were removed.
-- Use this block when pg17_plus = true.
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
-- 5b2  Top WAL producers (write amplification).
-- High wal_bytes/call = wide UPDATEs, non-HOT updates churning indexes
-- (see 5g), or write-heavy DML the workload may not realise is expensive.
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
-- 5c  Top temp-file writers (sort / hash spill).
-- Heavy temp_blks_written → work_mem too low for this query, or a missing
-- index forces a full sort/hash.
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
-- 5d  Plan instability (stddev / mean variance).
-- coeff_var > 1 with calls > 100 = plan flips, parameter sensitivity,
-- or cache-warm vs cache-cold variance. Pair with auto_explain.
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
-- 5e  Unbounded result sets (rows per call).
-- High rows/call on user-facing queries usually means missing LIMIT,
-- bad pagination, or N+1 fan-out.
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
-- 5f  Sequential-scan-dominated tables.
-- seq_pct > 80 on a > 100 MB table → missing or unused index.
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
-- 5f2  Last seq/idx scan timestamps.
-- Survives stats resets — tells you *when* the last scan happened.
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
-- 5g  HOT update efficiency.
-- hot_pct < 50 on a heavy-update table = index churn on every UPDATE,
-- write amplification, faster bloat growth. Candidates: lower fillfactor
-- or drop the indexed column from the UPDATE.
-- n_tup_newpage_upd reports updates that placed the new row on a NEW page
-- (no room on the original) — non-HOT and non-cold; useful to distinguish
-- from cold updates (different page reachable via index).
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
-- 5h  Per-table cache hit ratio (heap).
-- Filtered to "actually busy" (>= 10k buffer touches).
-- Low hit_pct + large size → working set exceeds shared_buffers for that
-- relation. For better attribution see 5i (pg_stat_io).
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
-- 5i  pg_stat_io — I/O attribution by backend type + context.
-- Tells you who is doing the I/O (client backend / autovacuum /
-- checkpointer / bgwriter / walwriter) and in what context (normal /
-- vacuum / bulkread / bulkwrite).
-- ============================================================================
SELECT
  backend_type, object, context,
  reads, writes, extends, hits, evictions, fsyncs
FROM pg_stat_io
WHERE (reads > 0 OR writes > 0 OR extends > 0)
ORDER BY (COALESCE(reads,0) + COALESCE(writes,0) + COALESCE(extends,0)) DESC
LIMIT 30;


-- ============================================================================
-- 5j  Live wait-event distribution (single snapshot).
-- For a proper distribution install pg_wait_sampling, or sample this
-- query every second for a minute. wait_event_type tells you the
-- bottleneck class:
--   NULL     → on-CPU (no wait)
--   IO       → disk pressure
--   LWLock   → buffer mapping, WAL insert, lock manager contention
--   Lock     → row/table lock waits → see Phase 4
--   Client   → app/network slow to consume results
--   IPC      → parallel worker coordination
--   Timeout  → vacuum_cost_delay, statement_timeout, etc.
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
-- 5j2  Sustained wait-event sampling extension present?
-- ============================================================================
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_wait_sampling';

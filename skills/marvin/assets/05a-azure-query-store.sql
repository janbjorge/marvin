-- marvin: 05a-azure-query-store.sql — Phase 5a. Read-only.
-- query_store.* lives ONLY in the azure_sys database — reconnect pglens
-- with PGDATABASE=azure_sys before running 5a-1+. 5a-0 confirms.
-- Adds time-bucketing (default 15 min, 7-day retention) and per-query waits
-- that pg_stat_statements cannot capture.
-- Not on read replicas. Do not enable on Burstable tier.
-- Docs: https://learn.microsoft.com/en-us/azure/postgresql/monitor/concepts-query-performance-insight

-- ============================================================================
-- 5a-0  Detection + connection check.
-- ============================================================================
SELECT
  current_database()                                              AS connected_db,
  EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'query_store') AS query_store_schema_present,
  EXISTS (SELECT 1 FROM pg_database  WHERE datname = 'azure_sys')   AS azure_sys_db_present,
  EXISTS (SELECT 1 FROM pg_roles     WHERE rolname = 'azure_pg_admin') AS azure_pg_admin_role_present,
  current_database() = 'azure_sys'                                AS connected_to_azure_sys;


-- ============================================================================
-- 5a-params  Server parameters. Required:
--   pg_qs.query_capture_mode              = 'top' | 'all'   (default 'none' = off)
--   pgms_wait_sampling.query_capture_mode = 'all'           (for waits)
--   track_io_timing                       = on              (for io_ms)
-- ============================================================================
SELECT name, setting, unit, source, short_desc
FROM pg_settings
WHERE name IN (
  'pg_qs.query_capture_mode',
  'pg_qs.interval_length_minutes',
  'pg_qs.max_captured_queries',
  'pg_qs.max_query_text_length',
  'pg_qs.retention_period_in_days',
  'pg_qs.store_query_plans',
  'pg_qs.track_utility',
  'pg_qs.parameters_capture_mode',
  'pgms_wait_sampling.query_capture_mode',
  'pgms_wait_sampling.history_period',
  'track_io_timing'
)
ORDER BY name;


-- ============================================================================
-- 5a-1  Captured-data freshness. staleness > a few intervals → capture stopped.
-- ============================================================================
SELECT
  min(start_time)                AS earliest_window,
  max(end_time)                  AS latest_window,
  now() - max(end_time)          AS staleness,
  count(*)                       AS total_rows,
  count(DISTINCT query_id)       AS distinct_queries,
  count(DISTINCT db_id)          AS distinct_databases
FROM query_store.qs_view;


-- ============================================================================
-- 5a-2  Top by total time (last 24h). Excludes is_system_query.
-- ============================================================================
SELECT
  q.query_id,
  d.datname                                              AS db,
  r.rolname                                              AS usr,
  sum(q.calls)                                           AS calls,
  round(sum(q.total_time)::numeric, 0)                   AS total_ms,
  round((sum(q.total_time) / NULLIF(sum(q.calls), 0))::numeric, 1) AS mean_ms,
  round(max(q.max_time)::numeric, 1)                     AS max_ms,
  sum(q.rows)                                            AS rows,
  round((sum(q.rows)::numeric / NULLIF(sum(q.calls), 0)), 0) AS rows_per_call,
  left(regexp_replace(max(q.query_sql_text), '\s+', ' ', 'g'), 200) AS query
FROM query_store.qs_view q
LEFT JOIN pg_database d ON d.oid = q.db_id
LEFT JOIN pg_roles    r ON r.oid = q.user_id
WHERE NOT q.is_system_query
  AND q.start_time > now() - interval '24 hours'
GROUP BY q.query_id, d.datname, r.rolname
ORDER BY sum(q.total_time) DESC
LIMIT 15;


-- ============================================================================
-- 5a-3  Top by disk I/O (last 24h). Needs track_io_timing = on.
-- ============================================================================
SELECT
  q.query_id,
  d.datname                                                       AS db,
  sum(q.calls)                                                    AS calls,
  round(sum(q.blk_read_time + q.blk_write_time)::numeric, 0)      AS io_ms,
  round(sum(q.blk_read_time)::numeric, 0)                         AS read_ms,
  round(sum(q.blk_write_time)::numeric, 0)                        AS write_ms,
  sum(q.shared_blks_read)                                         AS shared_blks_read,
  sum(q.shared_blks_hit)                                          AS shared_blks_hit,
  sum(q.shared_blks_written)                                      AS shared_blks_written,
  sum(q.shared_blks_dirtied)                                      AS shared_blks_dirtied,
  left(regexp_replace(max(q.query_sql_text), '\s+', ' ', 'g'), 200) AS query
FROM query_store.qs_view q
LEFT JOIN pg_database d ON d.oid = q.db_id
WHERE NOT q.is_system_query
  AND q.start_time > now() - interval '24 hours'
  AND (q.shared_blks_read > 0 OR q.blk_read_time > 0)
GROUP BY q.query_id, d.datname
ORDER BY sum(q.blk_read_time + q.blk_write_time) DESC NULLS LAST,
         sum(q.shared_blks_read) DESC
LIMIT 15;


-- ============================================================================
-- 5a-4  Top by temp-file usage (last 24h).
-- ============================================================================
SELECT
  q.query_id,
  d.datname                                                     AS db,
  sum(q.calls)                                                  AS calls,
  sum(q.temp_blks_written)                                      AS temp_blks_written,
  sum(q.temp_blks_read)                                         AS temp_blks_read,
  pg_size_pretty(sum(q.temp_blks_written) * current_setting('block_size')::bigint)
                                                                AS temp_written,
  left(regexp_replace(max(q.query_sql_text), '\s+', ' ', 'g'), 200) AS query
FROM query_store.qs_view q
LEFT JOIN pg_database d ON d.oid = q.db_id
WHERE NOT q.is_system_query
  AND q.start_time > now() - interval '24 hours'
  AND q.temp_blks_written > 0
GROUP BY q.query_id, d.datname
ORDER BY sum(q.temp_blks_written) DESC
LIMIT 15;


-- ============================================================================
-- 5a-5  Top by call volume (last 24h). High calls + small mean = chatty;
-- batching / prepared-statement reuse candidate.
-- ============================================================================
SELECT
  q.query_id,
  d.datname                                                       AS db,
  sum(q.calls)                                                    AS calls,
  round((sum(q.total_time) / NULLIF(sum(q.calls), 0))::numeric, 2) AS mean_ms,
  round(sum(q.total_time)::numeric, 0)                            AS total_ms,
  left(regexp_replace(max(q.query_sql_text), '\s+', ' ', 'g'), 200) AS query
FROM query_store.qs_view q
LEFT JOIN pg_database d ON d.oid = q.db_id
WHERE NOT q.is_system_query
  AND q.start_time > now() - interval '24 hours'
GROUP BY q.query_id, d.datname
ORDER BY sum(q.calls) DESC
LIMIT 15;


-- ============================================================================
-- 5a-6  Plan instability across 15-min buckets (last 24h).
-- bucket_coeff_var = stddev/mean over buckets.
-- ============================================================================
WITH per_window AS (
  SELECT query_id, db_id, start_time, mean_time, stddev_time, calls,
         max(query_sql_text) OVER (PARTITION BY query_id) AS sample_text
  FROM query_store.qs_view
  WHERE NOT is_system_query
    AND start_time > now() - interval '24 hours'
    AND mean_time IS NOT NULL
)
SELECT
  query_id,
  d.datname                                              AS db,
  count(*)                                               AS buckets,
  round(avg(mean_time)::numeric, 1)                      AS mean_of_means_ms,
  round(stddev(mean_time)::numeric, 1)                   AS stddev_of_means_ms,
  round((stddev(mean_time) / NULLIF(avg(mean_time), 0))::numeric, 2)
                                                         AS bucket_coeff_var,
  round(min(mean_time)::numeric, 1)                      AS min_mean_ms,
  round(max(mean_time)::numeric, 1)                      AS max_mean_ms,
  sum(calls)                                             AS total_calls,
  left(regexp_replace(max(sample_text), '\s+', ' ', 'g'), 200) AS query
FROM per_window p
LEFT JOIN pg_database d ON d.oid = p.db_id
GROUP BY query_id, d.datname
HAVING count(*) >= 3 AND sum(calls) >= 100
ORDER BY (stddev(mean_time) / NULLIF(avg(mean_time), 0)) DESC NULLS LAST
LIMIT 15;


-- ============================================================================
-- 5a-7  Wait events per query (last 24h). Needs pgms_wait_sampling = 'all'.
-- ============================================================================
SELECT
  w.query_id,
  d.datname             AS db,
  w.event_type,
  w.event,
  sum(w.calls)          AS sample_hits
FROM query_store.pgms_wait_sampling_view w
LEFT JOIN pg_database d ON d.oid = w.db_id
WHERE w.start_time > now() - interval '24 hours'
GROUP BY w.query_id, d.datname, w.event_type, w.event
ORDER BY sum(w.calls) DESC
LIMIT 30;


-- ============================================================================
-- 5a-8  Top wait events overall (last 24h).
-- ============================================================================
SELECT
  event_type,
  event,
  sum(calls)               AS sample_hits,
  count(DISTINCT query_id) AS distinct_queries
FROM query_store.pgms_wait_sampling_view
WHERE start_time > now() - interval '24 hours'
GROUP BY event_type, event
ORDER BY sum(calls) DESC
LIMIT 20;

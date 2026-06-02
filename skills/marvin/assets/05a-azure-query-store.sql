-- marvin: 05a-azure-query-store.sql
-- Phase 5a — Azure Database for PostgreSQL Flexible Server: Query Store hotspots.
-- Read-only.
--
-- Execution model: labelled query catalogue for the pglens `query` MCP tool.
-- Not a psql script.
--
-- CRITICAL connection note:
--   query_store.* views live only in the `azure_sys` database. The agent
--   must instruct the user to point pglens at a connection whose PGDATABASE
--   is `azure_sys` before running 5a-1 onward. 5a-0 below confirms this.
--
-- Why this exists in addition to Phase 5 (pg_stat_statements):
--   pg_stat_statements is cumulative since last reset → no time bucketing.
--   Query Store aggregates over fixed windows (default 15 min,
--   pg_qs.interval_length_minutes) and retains for
--   pg_qs.retention_period_in_days (default 7). That gives "what was slow
--   between 14:00 and 14:15 yesterday" without rotating snapshots yourself.
--   query_store.pgms_wait_sampling_view also gives per-query wait events,
--   which pg_stat_statements does NOT.
--
-- Reference:
--   https://learn.microsoft.com/en-us/azure/postgresql/monitor/concepts-query-performance-insight
--   https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-query-store
--
-- Limitations (per MS docs):
--   - Not available on read replicas.
--   - Burstable pricing tier: do NOT enable Query Store (performance impact).
--   - Server-wide on/off; cannot enable per-database.
--   - When default_transaction_read_only = on (or storage-full read-only),
--     Query Store stops capturing — analysis still works on retained data.


-- ============================================================================
-- 5a-0  Azure Flexible Server detection + connection check.
-- The agent reads these flags to decide whether to run the rest of 5a.
-- ============================================================================
SELECT
  current_database()                                              AS connected_db,
  EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'query_store') AS query_store_schema_present,
  EXISTS (SELECT 1 FROM pg_database  WHERE datname = 'azure_sys')   AS azure_sys_db_present,
  EXISTS (SELECT 1 FROM pg_roles     WHERE rolname = 'azure_pg_admin') AS azure_pg_admin_role_present,
  current_database() = 'azure_sys'                                AS connected_to_azure_sys;


-- ============================================================================
-- 5a-params  Server parameters controlling Query Store + wait sampling.
-- Required values for full hotspot analysis:
--   pg_qs.query_capture_mode              = 'top' or 'all'  (default 'none' = OFF)
--   pgms_wait_sampling.query_capture_mode = 'all'           (required for waits)
--   track_io_timing                       = on              (required for io_ms)
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
-- 5a-1  Captured-data freshness — do we have anything to analyse?
-- staleness > pg_qs.interval_length_minutes is normal (the current window
-- hasn't been flushed yet). staleness > a few intervals → capture has stopped.
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
-- 5a-2  Top queries by total time (last 24h).
-- Aggregates across all 15-min windows. Excludes the azuresu control-plane
-- user (is_system_query = true).
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
-- 5a-3  Top queries by disk I/O (last 24h).
-- blk_read_time / blk_write_time populated only when track_io_timing = on.
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
-- 5a-4  Top queries by temp-file usage (last 24h).
-- work_mem too small, or a missing index forcing a full sort/hash.
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
-- 5a-5  Top queries by call volume (last 24h).
-- High calls + small mean_ms = chatty workload (candidate for batching
-- or prepared-statement reuse). Multiplies per-call overhead.
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
-- 5a-6  Plan instability across windows (last 24h).
-- Compares mean_time across 15-min buckets for the same query_id.
-- bucket_coeff_var = stddev / mean over the buckets — flips, sensitivity.
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
-- 5a-7  Wait events per query (last 24h).
-- Populated only when pgms_wait_sampling.query_capture_mode = 'all'.
-- event_type buckets: IO, LWLock, Lock, Client, IPC, Timeout, BufferPin,
-- Extension, Activity. See pg_stat_activity docs for the canonical list.
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
-- Quick "what is the cluster waiting on" rollup.
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

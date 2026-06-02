-- marvin: 03-vacuum-and-long-xacts.sql
-- Phase 3 — vacuum state and long-running transactions.
-- Read-only.
--
-- Execution model: labelled query catalogue for the pglens `query` MCP tool.
-- Not a psql script.


-- ============================================================================
-- 3a  Long-running transactions (block global xmin).
-- Any > 1h is HIGH (blocks autovacuum cleanup of any row updated/deleted
-- after the transaction started).
-- "idle in transaction (aborted)" is CRITICAL — an error fired, the app
-- didn't ROLLBACK, the backend still holds locks and xmin forever.
-- ============================================================================
SELECT
  pid, datname, usename, application_name, client_addr,
  state, wait_event_type, wait_event,
  now() - xact_start  AS xact_age,
  now() - state_change AS state_age,
  backend_xmin,
  left(query, 200)     AS query
FROM pg_stat_activity
WHERE state IS DISTINCT FROM 'idle'
  AND xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes'
ORDER BY xact_age DESC;


-- ============================================================================
-- 3a-prepared  Prepared (two-phase) transactions — abandoned ones are nasty.
-- ============================================================================
SELECT * FROM pg_prepared_xacts ORDER BY prepared;


-- ============================================================================
-- 3a-slots  Replication-slot xmin holders.
-- A slot's xmin / catalog_xmin also blocks vacuum cleanup.
-- ============================================================================
SELECT slot_name, xmin, catalog_xmin
FROM pg_replication_slots
WHERE xmin IS NOT NULL OR catalog_xmin IS NOT NULL;


-- ============================================================================
-- 3b  Autovacuum lag — top 25 by dead tuples.
-- dead_ratio measures unvacuumed dead tuples (vacuum lag), NOT bloat.
-- For bloat see Phase 2.
-- ============================================================================
SELECT
  schemaname, relname,
  n_live_tup, n_dead_tup,
  CASE WHEN n_live_tup + n_dead_tup > 0
       THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1)
       ELSE 0
  END                                       AS dead_ratio,
  n_mod_since_analyze,
  pg_size_pretty(pg_relation_size(relid))   AS size,
  last_vacuum, last_autovacuum,
  last_analyze, last_autoanalyze,
  vacuum_count, autovacuum_count
FROM pg_stat_user_tables
WHERE n_live_tup + n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 25;


-- ============================================================================
-- 3c  Autovacuum workers currently running.
-- ============================================================================
SELECT pid, datname, query, state, wait_event_type, wait_event,
       now() - xact_start AS xact_age
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker'
   OR query ILIKE 'autovacuum:%';


-- ============================================================================
-- 3c-capacity  Autovacuum worker capacity.
-- ============================================================================
SELECT
  (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'autovacuum worker') AS running_workers,
  (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_max_workers')     AS max_workers;


-- ============================================================================
-- 3d  Tables with custom autovacuum settings (per-table overrides).
-- Useful context: someone has already tuned these — find out why before
-- proposing a global change.
-- ============================================================================
SELECT c.oid::regclass AS relation, c.reloptions
FROM pg_class c
WHERE c.relkind = 'r'
  AND c.reloptions IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM unnest(c.reloptions) o
    WHERE o LIKE 'autovacuum%' OR o LIKE 'toast.autovacuum%'
  )
ORDER BY c.oid::regclass::text;

-- marvin: 03-vacuum-and-long-xacts.sql — Phase 3. Read-only.

-- ============================================================================
-- 3a  Long-running transactions (block global xmin).
-- > 1h → HIGH. 'idle in transaction (aborted)' → CRITICAL.
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
-- 3a-prepared  Two-phase transactions. Abandoned ones hold xmin + locks.
-- ============================================================================
SELECT * FROM pg_prepared_xacts ORDER BY prepared;


-- ============================================================================
-- 3a-slots  Replication-slot xmin holders (also block vacuum).
-- ============================================================================
SELECT slot_name, xmin, catalog_xmin
FROM pg_replication_slots
WHERE xmin IS NOT NULL OR catalog_xmin IS NOT NULL;


-- ============================================================================
-- 3b  Autovacuum lag — top 25 by dead tuples.
-- dead_ratio = vacuum lag, NOT bloat. Bloat → Phase 2.
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
-- 3c  Autovacuum workers running. xact_age > 1h → HIGH: worker can't keep up
-- (tune autovacuum_vacuum_cost_limit / maintenance_work_mem, or the table
-- wants per-table overrides — see 3d). anti_wraparound = true → NEVER
-- pg_terminate_backend it; the cluster is defending against wraparound.
-- ============================================================================
SELECT pid, datname, query, state, wait_event_type, wait_event,
       now() - xact_start                         AS xact_age,
       now() - xact_start > interval '1 hour'      AS over_1h,
       query ILIKE '%to prevent wraparound%'       AS anti_wraparound
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker'
   OR query ILIKE 'autovacuum:%'
ORDER BY xact_age DESC;


-- ============================================================================
-- 3c-capacity  AV worker capacity vs max.
-- ============================================================================
SELECT
  (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'autovacuum worker') AS running_workers,
  (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_max_workers')     AS max_workers;


-- ============================================================================
-- 3d  Per-table autovacuum overrides. Someone tuned these — find out why
-- before proposing a global change.
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

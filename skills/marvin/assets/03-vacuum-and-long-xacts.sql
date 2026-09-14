-- marvin: 03-vacuum-and-long-xacts.sql — Phase 3. Read-only.

-- ============================================================================
-- 3a  Long-running transactions (block global xmin).
-- > 30 min → MEDIUM (pganalyze warn); > 1h → HIGH; 'idle in transaction
-- (aborted)' → CRITICAL. OLTP override: postgres.ai calls 30–60 s "long" on
-- a busy system — tighten when the workload says so. Full xmin horizon
-- (slots, standbys, prepared) is 7c.
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
-- 3b2  Autovacuum urgency — dead / inserted / modified tuples divided by the
-- trigger autovacuum actually uses (Cybertec "monitor autovacuum"). Honours
-- per-table reloptions and the PG18 autovacuum_vacuum_max_threshold cap
-- (default 100 M; -1 = no cap; no row on PG16/17 → falls back to -1).
-- urgency > 1 = table is due and autovacuum hasn't got to it (queue) →
-- MEDIUM; > 5 → HIGH (workers starved, cost limit, or av_disabled).
-- analyze_urgency > 1 for long = stale planner stats. Includes TOAST
-- (relkind 't') which pg_stat_user_tables hides; TOAST rows use global
-- thresholds (the parent's toast.* reloptions are not resolved here).
-- Not modelled: PG18 scales the insert trigger by (1 - relallfrozen/relpages).
-- ============================================================================
WITH g AS (
  SELECT
    current_setting('autovacuum_vacuum_threshold')::numeric           AS vt,
    current_setting('autovacuum_vacuum_scale_factor')::numeric        AS vsf,
    current_setting('autovacuum_vacuum_insert_threshold')::numeric    AS vit,
    current_setting('autovacuum_vacuum_insert_scale_factor')::numeric AS visf,
    current_setting('autovacuum_analyze_threshold')::numeric          AS at,
    current_setting('autovacuum_analyze_scale_factor')::numeric       AS asf,
    COALESCE((SELECT setting::numeric FROM pg_settings
              WHERE name = 'autovacuum_vacuum_max_threshold'), -1)    AS vmax
),
t AS (
  SELECT
    s.relid, s.schemaname, s.relname, c.relkind,
    GREATEST(c.reltuples, 0)::numeric AS reltuples,
    s.n_dead_tup, s.n_ins_since_vacuum, s.n_mod_since_analyze,
    s.last_autovacuum, s.last_autoanalyze,
    pg_relation_size(s.relid) AS bytes,
    COALESCE((SELECT substring(o FROM '=(.*)$')::numeric FROM unnest(c.reloptions) o
              WHERE o LIKE 'autovacuum_vacuum_threshold=%'), g.vt)           AS vt,
    COALESCE((SELECT substring(o FROM '=(.*)$')::numeric FROM unnest(c.reloptions) o
              WHERE o LIKE 'autovacuum_vacuum_scale_factor=%'), g.vsf)       AS vsf,
    COALESCE((SELECT substring(o FROM '=(.*)$')::numeric FROM unnest(c.reloptions) o
              WHERE o LIKE 'autovacuum_vacuum_insert_threshold=%'), g.vit)   AS vit,
    COALESCE((SELECT substring(o FROM '=(.*)$')::numeric FROM unnest(c.reloptions) o
              WHERE o LIKE 'autovacuum_vacuum_insert_scale_factor=%'), g.visf) AS visf,
    COALESCE((SELECT substring(o FROM '=(.*)$')::numeric FROM unnest(c.reloptions) o
              WHERE o LIKE 'autovacuum_analyze_threshold=%'), g.at)          AS at,
    COALESCE((SELECT substring(o FROM '=(.*)$')::numeric FROM unnest(c.reloptions) o
              WHERE o LIKE 'autovacuum_analyze_scale_factor=%'), g.asf)      AS asf,
    COALESCE((SELECT substring(o FROM '=(.*)$')::numeric FROM unnest(c.reloptions) o
              WHERE o LIKE 'autovacuum_vacuum_max_threshold=%'), g.vmax)     AS vmax,
    EXISTS (SELECT 1 FROM unnest(c.reloptions) o
            WHERE o = 'autovacuum_enabled=false')                            AS av_disabled
  FROM pg_stat_all_tables s
  JOIN pg_class c ON c.oid = s.relid
  CROSS JOIN g
  WHERE s.schemaname NOT IN ('pg_catalog','information_schema')
    AND c.relkind IN ('r','m','t')
),
x AS (
  SELECT *,
    CASE WHEN vmax >= 0 THEN LEAST(vt + vsf * reltuples, vmax)
         ELSE vt + vsf * reltuples END      AS vacuum_trigger,
    vit + visf * reltuples                  AS insert_trigger,
    at + asf * reltuples                    AS analyze_trigger
  FROM t
)
SELECT
  schemaname, relname, relkind,
  pg_size_pretty(bytes)                                             AS size,
  n_dead_tup,
  round(vacuum_trigger)                                             AS vacuum_trigger,
  round(n_dead_tup / NULLIF(vacuum_trigger, 0), 2)                  AS vacuum_urgency,
  n_ins_since_vacuum,
  round(n_ins_since_vacuum / NULLIF(insert_trigger, 0), 2)          AS insert_urgency,
  n_mod_since_analyze,
  round(n_mod_since_analyze / NULLIF(analyze_trigger, 0), 2)        AS analyze_urgency,
  av_disabled,
  last_autovacuum, last_autoanalyze
FROM x
WHERE n_dead_tup / NULLIF(vacuum_trigger, 0) > 0.5
   OR n_ins_since_vacuum / NULLIF(insert_trigger, 0) > 0.5
   OR n_mod_since_analyze / NULLIF(analyze_trigger, 0) > 0.5
   OR av_disabled
ORDER BY GREATEST(n_dead_tup / NULLIF(vacuum_trigger, 0),
                  n_mod_since_analyze / NULLIF(analyze_trigger, 0), 0) DESC
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
-- 3c-capacity  AV worker capacity vs max. running = max for the whole audit
-- + 3b2 rows with urgency > 1 = queue. Raising autovacuum_max_workers alone
-- does not help: the cost budget (autovacuum_vacuum_cost_limit, default 200
-- with 2 ms delay ≈ 80 MB/s of cache hits, 8 MB/s of reads) is shared across
-- workers — raise both. PG18: max_workers is reloadable up to worker_slots.
-- ============================================================================
SELECT
  (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'autovacuum worker') AS running_workers,
  (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_max_workers')     AS max_workers,
  (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_worker_slots')    AS worker_slots_pg18,
  (SELECT setting FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_limit')    AS av_cost_limit,
  (SELECT setting FROM pg_settings WHERE name = 'vacuum_cost_limit')               AS vacuum_cost_limit,
  (SELECT setting FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_delay')    AS av_cost_delay_ms,
  (SELECT setting FROM pg_settings WHERE name = 'autovacuum_work_mem')             AS autovacuum_work_mem,
  (SELECT setting FROM pg_settings WHERE name = 'maintenance_work_mem')            AS maintenance_work_mem;


-- ============================================================================
-- 3c-progress [PG16]  Vacuum progress. index_vacuum_count > 1 = dead-TID
-- store filled → multiple index passes → autovacuum_work_mem /
-- maintenance_work_mem too small (pganalyze inefficient_index_phase).
-- PG16 columns: max_dead_tuples / num_dead_tuples. Use when pg17_plus = false.
-- ============================================================================
SELECT
  p.pid, p.datname, p.relid::regclass AS relation, p.phase,
  p.heap_blks_total, p.heap_blks_scanned, p.heap_blks_vacuumed,
  round(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 1) AS scanned_pct,
  p.index_vacuum_count, p.indexes_total, p.indexes_processed,
  p.max_dead_tuples, p.num_dead_tuples,
  now() - a.xact_start                          AS running_for,
  a.wait_event_type, a.wait_event,
  a.query ILIKE '%to prevent wraparound%'       AS anti_wraparound
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a ON a.pid = p.pid
ORDER BY a.xact_start;


-- ============================================================================
-- 3c-progress [PG17+]  Same, PG17 renamed the dead-tuple columns to bytes
-- (TID store). Use when pg17_plus = true. PG18 adds delay_time (ms spent in
-- cost delay; 0 unless track_cost_delay_timing = on) — add it by hand when
-- pg18_plus = true and the GUC is on.
-- ============================================================================
SELECT
  p.pid, p.datname, p.relid::regclass AS relation, p.phase,
  p.heap_blks_total, p.heap_blks_scanned, p.heap_blks_vacuumed,
  round(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 1) AS scanned_pct,
  p.index_vacuum_count, p.indexes_total, p.indexes_processed,
  pg_size_pretty(p.dead_tuple_bytes)            AS dead_tuple_bytes,
  pg_size_pretty(p.max_dead_tuple_bytes)        AS max_dead_tuple_bytes,
  p.num_dead_item_ids,
  now() - a.xact_start                          AS running_for,
  a.wait_event_type, a.wait_event,
  a.query ILIKE '%to prevent wraparound%'       AS anti_wraparound
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a ON a.pid = p.pid
ORDER BY a.xact_start;


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


-- ============================================================================
-- 3e  Partitioned parents — autovacuum NEVER analyzes them (docs: routine
-- vacuuming), so parent-level stats only exist if someone runs ANALYZE
-- manually. stats_age NULL or old + partitions > 0 → MEDIUM (planner
-- estimates cross-partition joins blind). inherited_stat_cols = 0 means no
-- parent stats at all. PG18: VACUUM/ANALYZE on the parent recurses by
-- default (ONLY to opt out).
-- ============================================================================
SELECT
  c.oid::regclass                                        AS parent,
  (SELECT count(*) FROM pg_inherits i WHERE i.inhparent = c.oid) AS partitions,
  s.last_analyze, s.last_autoanalyze,
  now() - GREATEST(s.last_analyze, s.last_autoanalyze)   AS stats_age,
  c.reltuples,
  (SELECT count(*) FROM pg_stats st
    WHERE st.schemaname = n.nspname AND st.tablename = c.relname AND st.inherited) AS inherited_stat_cols
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_all_tables s ON s.relid = c.oid
WHERE c.relkind = 'p'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY stats_age DESC NULLS FIRST
LIMIT 25;


-- ============================================================================
-- 3f [PG18]  Where autovacuum time goes. total_autovacuum_time (ms, PG18)
-- ranks tables by worker time consumed. One table > 50% of all AV time on
-- 3 workers = the table that needs per-table cost / scale-factor tuning
-- (3d) or partitioning (5l). Use when pg18_plus = true.
-- ============================================================================
SELECT
  schemaname, relname,
  autovacuum_count, vacuum_count,
  round((total_autovacuum_time / 1000)::numeric, 0)               AS autovacuum_s,
  CASE WHEN autovacuum_count > 0
       THEN round((total_autovacuum_time / autovacuum_count / 1000)::numeric, 1)
  END                                                             AS avg_autovacuum_s,
  round((total_autoanalyze_time / 1000)::numeric, 0)              AS autoanalyze_s,
  round((100.0 * total_autovacuum_time /
         NULLIF(sum(total_autovacuum_time) OVER (), 0))::numeric, 1) AS pct_of_all_av_time,
  n_dead_tup, last_autovacuum,
  pg_size_pretty(pg_relation_size(relid))                         AS size
FROM pg_stat_all_tables
WHERE total_autovacuum_time > 0
ORDER BY total_autovacuum_time DESC
LIMIT 15;

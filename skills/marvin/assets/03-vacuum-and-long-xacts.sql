-- marvin: 03-vacuum-and-long-xacts.sql — Phase 3. Read-only.
-- Rationale for every threshold: references/interpretation-thresholds.md.

-- ============================================================================
-- 3a  Long-running transactions (hold global xmin). severity: 'idle in
-- transaction (aborted)' → CRITICAL; > 1 h → HIGH; > 30 min → MEDIUM.
-- OLTP override: tighten to minutes when the operator says so. All xmin
-- holders (slots, standbys, prepared xacts) in one list: 7c.
-- ============================================================================
SELECT
  pid, datname, usename, application_name, client_addr,
  state, wait_event_type, wait_event,
  now() - xact_start   AS xact_age,
  now() - state_change AS state_age,
  backend_xmin,
  left(query, 200)     AS query,
  CASE WHEN state = 'idle in transaction (aborted)'       THEN 'CRITICAL'
       WHEN now() - xact_start > interval '1 hour'        THEN 'HIGH'
       WHEN now() - xact_start > interval '30 minutes'    THEN 'MEDIUM'
  END AS severity
FROM pg_stat_activity
WHERE state IS DISTINCT FROM 'idle'
  AND xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes'
ORDER BY xact_age DESC;


-- ============================================================================
-- 3b  Autovacuum urgency = tuples ÷ the trigger autovacuum actually uses
-- (Cybertec), honouring reloptions and the PG18 autovacuum_vacuum_max_threshold
-- cap. severity: av_disabled or vacuum_urgency > 5 → HIGH; any urgency > 1 →
-- MEDIUM (due, not yet vacuumed/analyzed). Empty result = autovacuum keeping
-- up. Includes TOAST (relkind 't', global thresholds only).
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
    s.n_live_tup, s.n_dead_tup, s.n_ins_since_vacuum, s.n_mod_since_analyze,
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
),
u AS (
  SELECT *,
    round(n_dead_tup         / NULLIF(vacuum_trigger, 0), 2)  AS vacuum_urgency,
    round(n_ins_since_vacuum / NULLIF(insert_trigger, 0), 2)  AS insert_urgency,
    round(n_mod_since_analyze / NULLIF(analyze_trigger, 0), 2) AS analyze_urgency
  FROM x
)
SELECT
  schemaname, relname, relkind,
  pg_size_pretty(bytes)            AS size,
  n_live_tup, n_dead_tup,
  round(vacuum_trigger)            AS vacuum_trigger,
  vacuum_urgency,
  n_ins_since_vacuum, insert_urgency,
  n_mod_since_analyze, analyze_urgency,
  av_disabled, last_autovacuum, last_autoanalyze,
  CASE WHEN av_disabled OR vacuum_urgency > 5                                  THEN 'HIGH'
       WHEN GREATEST(vacuum_urgency, insert_urgency, analyze_urgency) > 1      THEN 'MEDIUM'
  END AS severity
FROM u
WHERE GREATEST(vacuum_urgency, insert_urgency, analyze_urgency) > 0.5 OR av_disabled
ORDER BY GREATEST(vacuum_urgency, analyze_urgency, 0) DESC
LIMIT 25;


-- ============================================================================
-- 3c  Autovacuum workers running. severity HIGH = over 1 h and not
-- anti-wraparound (worker can't keep up → cost limit / 3d overrides).
-- anti_wraparound = true → NEVER pg_terminate_backend it.
-- ============================================================================
SELECT pid, datname, query, state, wait_event_type, wait_event,
       now() - xact_start                         AS xact_age,
       query ILIKE '%to prevent wraparound%'       AS anti_wraparound,
       CASE WHEN now() - xact_start > interval '1 hour'
             AND query NOT ILIKE '%to prevent wraparound%' THEN 'HIGH' END AS severity
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker'
   OR query ILIKE 'autovacuum:%'
ORDER BY xact_age DESC;


-- ============================================================================
-- 3c-capacity  at_capacity for the whole audit + 3b rows with urgency > 1 =
-- queue → MEDIUM. Raise the cost budget (0-settings: autovacuum_vacuum_cost_
-- limit / _delay, autovacuum_work_mem) together with max_workers.
-- ============================================================================
SELECT
  (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'autovacuum worker') AS running_workers,
  (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_max_workers')     AS max_workers,
  (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_worker_slots')    AS worker_slots_pg18,
  (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'autovacuum worker')
    >= (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_max_workers') AS at_capacity;


-- ============================================================================
-- 3c-progress [PG16]  Vacuum progress. severity HIGH = index_vacuum_count > 1
-- (dead-TID store filled, indexes scanned again → raise autovacuum_work_mem).
-- Use when pg17_plus = false.
-- ============================================================================
SELECT
  p.pid, p.datname, p.relid::regclass AS relation, p.phase,
  p.heap_blks_total, p.heap_blks_scanned, p.heap_blks_vacuumed,
  round(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 1) AS scanned_pct,
  p.index_vacuum_count, p.indexes_total, p.indexes_processed,
  p.max_dead_tuples, p.num_dead_tuples,
  now() - a.xact_start                          AS running_for,
  a.wait_event_type, a.wait_event,
  a.query ILIKE '%to prevent wraparound%'       AS anti_wraparound,
  CASE WHEN p.index_vacuum_count > 1 THEN 'HIGH' END AS severity
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a ON a.pid = p.pid
ORDER BY a.xact_start;


-- ============================================================================
-- 3c-progress [PG17+]  Same; PG17 dead-tuple columns are bytes (TID store).
-- PG18 adds delay_time (needs track_cost_delay_timing = on) — select by hand.
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
  a.query ILIKE '%to prevent wraparound%'       AS anti_wraparound,
  CASE WHEN p.index_vacuum_count > 1 THEN 'HIGH' END AS severity
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a ON a.pid = p.pid
ORDER BY a.xact_start;


-- ============================================================================
-- 3d  Per-table autovacuum overrides. Someone tuned these — ask why before
-- proposing a global change.
-- ============================================================================
SELECT c.oid::regclass AS relation, c.reloptions
FROM pg_class c
WHERE c.relkind = 'r'
  AND EXISTS (SELECT 1 FROM unnest(c.reloptions) o
              WHERE o LIKE 'autovacuum%' OR o LIKE 'toast.autovacuum%')
ORDER BY c.oid::regclass::text;


-- ============================================================================
-- 3e  Partitioned parents — autovacuum never analyzes them. severity MEDIUM
-- = has partitions and parent stats missing or > 30 d old. PG18: ANALYZE on
-- the parent recurses by default (ONLY opts out).
-- ============================================================================
WITH p AS (
  SELECT
    c.oid::regclass AS parent,
    (SELECT count(*) FROM pg_inherits i WHERE i.inhparent = c.oid) AS partitions,
    s.last_analyze, s.last_autoanalyze,
    now() - GREATEST(s.last_analyze, s.last_autoanalyze) AS stats_age,
    c.reltuples,
    (SELECT count(*) FROM pg_stats st
      WHERE st.schemaname = n.nspname AND st.tablename = c.relname AND st.inherited) AS inherited_stat_cols
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_stat_all_tables s ON s.relid = c.oid
  WHERE c.relkind = 'p'
    AND n.nspname NOT IN ('pg_catalog','information_schema')
)
SELECT *,
  CASE WHEN partitions > 0 AND (stats_age IS NULL OR stats_age > interval '30 days')
       THEN 'MEDIUM' END AS severity
FROM p
ORDER BY stats_age DESC NULLS FIRST
LIMIT 25;


-- ============================================================================
-- 3f [PG18]  Where autovacuum time goes (total_autovacuum_time, ms). severity
-- MEDIUM = one table > 50% of all AV time → per-table tuning (3d) or
-- partitioning (5l). Use when pg18_plus = true.
-- ============================================================================
WITH t AS (
  SELECT schemaname, relname, relid, autovacuum_count, vacuum_count, n_dead_tup, last_autovacuum,
         total_autovacuum_time, total_autoanalyze_time,
         round((100.0 * total_autovacuum_time /
                NULLIF(sum(total_autovacuum_time) OVER (), 0))::numeric, 1) AS pct_of_all_av_time
  FROM pg_stat_all_tables
  WHERE total_autovacuum_time > 0
)
SELECT
  schemaname, relname, autovacuum_count, vacuum_count,
  round((total_autovacuum_time / 1000)::numeric, 0)                          AS autovacuum_s,
  CASE WHEN autovacuum_count > 0
       THEN round((total_autovacuum_time / autovacuum_count / 1000)::numeric, 1) END AS avg_autovacuum_s,
  round((total_autoanalyze_time / 1000)::numeric, 0)                         AS autoanalyze_s,
  pct_of_all_av_time,
  n_dead_tup, last_autovacuum,
  pg_size_pretty(pg_relation_size(relid))                                    AS size,
  CASE WHEN pct_of_all_av_time > 50 THEN 'MEDIUM' END                       AS severity
FROM t
ORDER BY total_autovacuum_time DESC
LIMIT 15;

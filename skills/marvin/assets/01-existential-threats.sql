-- marvin: 01-existential-threats.sql — Phase 1. Read-only.
-- Halt the audit on any severity = 'CRITICAL' row.

-- ============================================================================
-- 1a  Wraparound risk (xid + MultiXact, per database). MultiXact is a
-- separate counter — FK / FOR SHARE workloads can hit it first.
-- ============================================================================
WITH d AS (
  SELECT datname,
         age(datfrozenxid)::numeric  AS xid_age,
         mxid_age(datminmxid)::numeric AS mxid_age,
         current_setting('autovacuum_freeze_max_age')::numeric           AS av_freeze_max_age,
         current_setting('autovacuum_multixact_freeze_max_age')::numeric AS av_mxid_max_age
  FROM pg_database WHERE datallowconn
), p AS (
  SELECT *, round(100 * xid_age / av_freeze_max_age, 1)  AS pct_to_emergency_av,
            round(100 * mxid_age / av_mxid_max_age, 1)   AS pct_to_emergency_mxid_av
  FROM d
)
SELECT datname, xid_age, av_freeze_max_age, pct_to_emergency_av,
       mxid_age AS multixact_age, av_mxid_max_age, pct_to_emergency_mxid_av,
       CASE WHEN GREATEST(pct_to_emergency_av, pct_to_emergency_mxid_av) >= 100 THEN 'CRITICAL'
            WHEN GREATEST(pct_to_emergency_av, pct_to_emergency_mxid_av) >= 90  THEN 'HIGH'
       END AS severity
FROM p
ORDER BY xid_age DESC;


-- ============================================================================
-- 1a-per-table  Tables past 50% of freeze_max_age — VACUUM (FREEZE) targets,
-- largest + oldest first.
-- ============================================================================
SELECT
  c.oid::regclass                            AS relation,
  age(c.relfrozenxid)                        AS xid_age,
  mxid_age(c.relminmxid)                     AS mxid_age,
  pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
  s.last_autovacuum, s.last_vacuum, s.n_dead_tup
FROM pg_class c
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind IN ('r','m','t')
  AND age(c.relfrozenxid) > current_setting('autovacuum_freeze_max_age')::bigint * 0.5
ORDER BY age(c.relfrozenxid) DESC
LIMIT 30;


-- ============================================================================
-- 1b [PG16]  Replication slots. Use when pg17_plus = false.
-- severity: wal_status = 'lost' → CRITICAL; inactive + retained > 10 GB →
-- HIGH; max_slot_wal_keep_size = -1 with any slot → MEDIUM ('unbounded').
-- catalog_xmin on a logical slot pins catalog vacuum even when xmin is NULL.
-- ============================================================================
WITH s AS (
  SELECT *, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes,
         current_setting('max_slot_wal_keep_size') = '-1'    AS unbounded
  FROM pg_replication_slots
)
SELECT
  slot_name, plugin, slot_type, database, active, active_pid,
  pg_size_pretty(retained_bytes)                  AS retained_wal,
  wal_status,
  CASE WHEN unbounded THEN 'unbounded (max_slot_wal_keep_size = -1)'
       ELSE pg_size_pretty(safe_wal_size) END     AS safe_wal_size_remaining,
  conflicting,
  xmin, age(xmin)                                 AS xmin_age,
  catalog_xmin, age(catalog_xmin)                 AS catalog_xmin_age,
  CASE WHEN wal_status = 'lost'                                        THEN 'CRITICAL'
       WHEN NOT active AND retained_bytes > 10 * 1024::bigint^3        THEN 'HIGH'
       WHEN unbounded                                                  THEN 'MEDIUM'
  END AS severity
FROM s
ORDER BY retained_bytes DESC NULLS LAST;


-- ============================================================================
-- 1b [PG17+]  Same plus inactive_since / invalidation_reason (wal_removed,
-- rows_removed, wal_level_insufficient, idle_timeout). Use when pg17_plus.
-- Fix for 'unbounded': finite max_slot_wal_keep_size + PG18
-- idle_replication_slot_timeout.
-- ============================================================================
WITH s AS (
  SELECT *, pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes,
         current_setting('max_slot_wal_keep_size') = '-1'    AS unbounded
  FROM pg_replication_slots
)
SELECT
  slot_name, plugin, slot_type, database, active, active_pid,
  pg_size_pretty(retained_bytes)                  AS retained_wal,
  wal_status,
  CASE WHEN unbounded THEN 'unbounded (max_slot_wal_keep_size = -1)'
       ELSE pg_size_pretty(safe_wal_size) END     AS safe_wal_size_remaining,
  inactive_since,
  CASE WHEN NOT active THEN now() - inactive_since END AS inactive_for,
  invalidation_reason,
  conflicting,
  xmin, age(xmin)                                 AS xmin_age,
  catalog_xmin, age(catalog_xmin)                 AS catalog_xmin_age,
  CASE WHEN wal_status = 'lost' OR invalidation_reason IS NOT NULL      THEN 'CRITICAL'
       WHEN NOT active AND retained_bytes > 10 * 1024::bigint^3        THEN 'HIGH'
       WHEN unbounded                                                  THEN 'MEDIUM'
  END AS severity
FROM s
ORDER BY retained_bytes DESC NULLS LAST;


-- ============================================================================
-- 1c  WAL on disk (pair with max_wal_size + slot retention above).
-- ============================================================================
SELECT pg_size_pretty(sum(size)) AS total_wal_dir_size, count(*) AS wal_segment_count
FROM pg_ls_waldir();

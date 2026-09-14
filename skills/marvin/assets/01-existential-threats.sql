-- marvin: 01-existential-threats.sql — Phase 1. Read-only.
-- Halt the audit on any CRITICAL row.

-- ============================================================================
-- 1a  Wraparound risk (xid + MultiXact, per database).
-- pct_to_emergency_av >= 90 → HIGH; >= 100 → CRITICAL (anti-wraparound running).
-- MultiXact wraparound is a separate counter — FK / FOR SHARE workloads can
-- hit it first.
-- ============================================================================
SELECT
  datname,
  age(datfrozenxid)                                     AS xid_age,
  current_setting('autovacuum_freeze_max_age')::bigint  AS av_freeze_max_age,
  round(100.0 * age(datfrozenxid)::numeric /
        current_setting('autovacuum_freeze_max_age')::numeric, 1) AS pct_to_emergency_av,
  mxid_age(datminmxid)                                  AS multixact_age,
  current_setting('autovacuum_multixact_freeze_max_age')::bigint AS av_mxid_max_age,
  round(100.0 * mxid_age(datminmxid)::numeric /
        current_setting('autovacuum_multixact_freeze_max_age')::numeric, 1) AS pct_to_emergency_mxid_av
FROM pg_database
WHERE datallowconn
ORDER BY age(datfrozenxid) DESC;


-- ============================================================================
-- 1a-per-table  Per-table wraparound (> 50% of freeze_max_age).
-- Targets for VACUUM (FREEZE) in a fire drill — largest + oldest first.
-- ============================================================================
SELECT
  c.oid::regclass                            AS relation,
  age(c.relfrozenxid)                        AS xid_age,
  mxid_age(c.relminmxid)                     AS mxid_age,
  pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
  s.last_autovacuum,
  s.last_vacuum,
  s.n_dead_tup
FROM pg_class c
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind IN ('r','m','t')
  AND age(c.relfrozenxid) >
      current_setting('autovacuum_freeze_max_age')::bigint * 0.5
ORDER BY age(c.relfrozenxid) DESC
LIMIT 30;


-- ============================================================================
-- 1b [PG16]  Replication slot bloat.
-- Inactive + retained WAL > 10 GB → HIGH. wal_status 'extended'/'lost' →
-- CRITICAL (replica can't catch up without fresh basebackup).
-- safe_wal_size is NULL when max_slot_wal_keep_size = -1 (the default):
-- report it as 'unbounded' — a stuck slot can fill the disk — never as OK.
-- catalog_xmin on a logical slot pins catalog vacuum even when xmin is NULL.
-- Use when pg17_plus = false (inactive_since / invalidation_reason absent).
-- ============================================================================
SELECT
  slot_name, plugin, slot_type, database,
  active, active_pid,
  pg_size_pretty(
    CASE
      WHEN restart_lsn IS NULL THEN 0
      ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    END
  )                                          AS retained_wal,
  wal_status,
  CASE WHEN current_setting('max_slot_wal_keep_size') = '-1'
       THEN 'unbounded (max_slot_wal_keep_size = -1)'
       ELSE pg_size_pretty(safe_wal_size)
  END                                        AS safe_wal_size_remaining,
  conflicting,
  xmin, age(xmin)                            AS xmin_age,
  catalog_xmin, age(catalog_xmin)            AS catalog_xmin_age
FROM pg_replication_slots
ORDER BY
  CASE WHEN restart_lsn IS NULL THEN 0
       ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  END DESC NULLS LAST;


-- ============================================================================
-- 1b [PG17+]  Same, plus PG17 columns: inactive_for (inactive_since) = how
-- long nobody consumed the slot; invalidation_reason non-NULL = the server
-- already gave up on it (wal_removed / rows_removed / wal_level_insufficient
-- / idle_timeout). PG18: idle_replication_slot_timeout (default 0 = off) can
-- auto-invalidate idle slots — recommend it with a finite
-- max_slot_wal_keep_size. Use when pg17_plus = true.
-- ============================================================================
SELECT
  slot_name, plugin, slot_type, database,
  active, active_pid,
  pg_size_pretty(
    CASE
      WHEN restart_lsn IS NULL THEN 0
      ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    END
  )                                          AS retained_wal,
  wal_status,
  CASE WHEN current_setting('max_slot_wal_keep_size') = '-1'
       THEN 'unbounded (max_slot_wal_keep_size = -1)'
       ELSE pg_size_pretty(safe_wal_size)
  END                                        AS safe_wal_size_remaining,
  inactive_since,
  CASE WHEN NOT active THEN now() - inactive_since END AS inactive_for,
  invalidation_reason,
  conflicting,
  xmin, age(xmin)                            AS xmin_age,
  catalog_xmin, age(catalog_xmin)            AS catalog_xmin_age
FROM pg_replication_slots
ORDER BY
  CASE WHEN restart_lsn IS NULL THEN 0
       ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  END DESC NULLS LAST;


-- ============================================================================
-- 1c  WAL volume on disk (pair with max_wal_size + slot retention above).
-- ============================================================================
SELECT
  pg_size_pretty(sum(size))     AS total_wal_dir_size,
  count(*)                      AS wal_segment_count
FROM pg_ls_waldir();

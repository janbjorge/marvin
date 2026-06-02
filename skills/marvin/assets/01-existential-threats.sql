-- marvin: 01-existential-threats.sql
-- Phase 1 — things that can take the database offline. Surface immediately,
-- before continuing the rest of the audit.
-- Read-only.
--
-- Execution model: labelled query catalogue for the pglens `query` MCP tool.
-- Not a psql script.


-- ============================================================================
-- 1a  Transaction ID wraparound risk (per database).
-- pct_to_emergency_av >= 90  → HIGH    (anti-wraparound AV will start soon)
-- pct_to_emergency_av >= 100 → CRITICAL (already in anti-wraparound mode)
-- MultiXact wraparound is a separate clock and has its own counter — both
-- are reported below. Workloads using SELECT FOR SHARE / FK validation can
-- hit MultiXact wraparound before xid wraparound.
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
-- 1a-per-table  Per-table wraparound risk (tables > 50% of freeze_max_age).
-- Identifies which relations to target with VACUUM (FREEZE) in a fire drill,
-- largest + oldest first.
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
-- 1b  Replication slot bloat.
-- Inactive slots with retained WAL > 10 GB → HIGH.
-- wal_status of 'extended' or 'lost' → CRITICAL — replica cannot catch up
-- without a fresh basebackup.
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
  pg_size_pretty(safe_wal_size)              AS safe_wal_size_remaining
FROM pg_replication_slots
ORDER BY
  CASE WHEN restart_lsn IS NULL THEN 0
       ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  END DESC NULLS LAST;


-- ============================================================================
-- 1c  WAL volume on disk.
-- Postgres only knows what it has written; actual filesystem free space
-- requires OS tooling. Use this number against max_wal_size + the slot
-- retention above to estimate disk pressure.
-- ============================================================================
SELECT
  pg_size_pretty(sum(size))     AS total_wal_dir_size,
  count(*)                      AS wal_segment_count
FROM pg_ls_waldir();

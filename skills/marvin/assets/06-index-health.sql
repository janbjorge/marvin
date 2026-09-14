-- marvin: 06-index-health.sql — Phase 6. Read-only.
-- Prefer pglens `unused_indexes` tool when available; 6a is the raw SQL with
-- the same safety filters (excludes unique / PK / constraint-backing).

-- ============================================================================
-- 6a  Unused indexes. Trust requires stats age >= 30 d (0-stats-age;
-- pganalyze uses 35 d, postgres.ai 1 month) AND a look at every replica —
-- idx_scan is per-instance. Partial / quarterly-used indexes may show
-- idx_scan = 0 — cross-check last_idx_scan (PG16+, survives stats resets).
-- Excluded: unique, PK, constraint-backing, invalid (6e owns those), and
-- indexes whose leading columns match a FOREIGN KEY on the same table —
-- those serve cascade DELETE/UPDATE on the parent, rarely show scans, and
-- dropping them recreates finding 6d. (pg_constraint.conindid for a FK
-- points at the *referenced* table's index, so the old filter missed them.)
-- ============================================================================
SELECT
  s.schemaname, s.relname           AS table_name,
  s.indexrelname                    AS index_name,
  s.idx_scan, s.last_idx_scan,
  pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
  pg_size_pretty(pg_relation_size(s.relid))      AS table_size
FROM pg_stat_user_indexes s
JOIN pg_index i ON s.indexrelid = i.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisunique
  AND NOT i.indisprimary
  AND i.indisvalid
  AND NOT EXISTS (
    SELECT 1 FROM pg_constraint c WHERE c.conindid = s.indexrelid
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_constraint fk
    WHERE fk.contype = 'f'
      AND fk.conrelid = i.indrelid
      AND array_length(fk.conkey, 1) <= i.indnkeyatts
      AND (string_to_array(i.indkey::text, ' ')::int[])[1:array_length(fk.conkey, 1)]
          = fk.conkey::int[]
  )
ORDER BY pg_relation_size(s.indexrelid) DESC;


-- ============================================================================
-- 6b  Duplicate indexes (identical definition).
-- ============================================================================
WITH idx AS (
  SELECT
    indexrelid::regclass                  AS idx_name,
    indrelid::regclass                    AS table_name,
    pg_relation_size(indexrelid)          AS bytes,
    indrelid, indkey, indclass, indoption,
    COALESCE(indexprs::text, '')          AS expr,
    COALESCE(indpred::text, '')           AS pred
  FROM pg_index
  WHERE indislive
)
SELECT
  table_name,
  pg_size_pretty(sum(bytes)::bigint)                  AS combined_size,
  array_agg(idx_name ORDER BY idx_name)               AS indexes
FROM idx
GROUP BY table_name, indrelid, indkey, indclass, indoption, expr, pred
HAVING count(*) > 1
ORDER BY sum(bytes) DESC;


-- ============================================================================
-- 6c  Prefix-redundant: (a) is redundant if (a,b) exists with same predicate
-- + opclasses. Unique excluded (uniqueness can be a 1-col property). Slice
-- at indnkeyatts to drop INCLUDE columns (don't satisfy key-search). indkey
-- is int2vector (0-based) — indkey::text → string_to_array gives a 1-based
-- int[] (int2vectorout() returns cstring and does not cast implicitly).
-- PG18 skip scan is the reverse case ((a,b) serving WHERE b = ? when a has
-- few distinct values); it does NOT make (a) redundant and this rule stands.
-- Expression columns appear as 0 in indkey — two different expression
-- indexes would look identical, so indexprs must match too (same as 6b).
-- ============================================================================
WITH idx AS (
  SELECT
    indexrelid::regclass                                                AS idx_name,
    indrelid                                                            AS table_oid,
    indrelid::regclass                                                  AS table_name,
    string_to_array(indkey::text, ' ')::int[]                           AS keycols_full,
    indnkeyatts,
    indclass::oid[]                                                     AS keyops,
    pg_relation_size(indexrelid)                                        AS bytes,
    COALESCE(indpred::text, '')                                         AS pred,
    COALESCE(indexprs::text, '')                                        AS expr,
    indisunique
  FROM pg_index
  WHERE indislive
),
idx_keys AS (
  SELECT
    idx_name, table_oid, table_name,
    keycols_full[1:indnkeyatts] AS keycols,
    keyops[1:indnkeyatts]       AS keyops,
    bytes, pred, expr, indisunique
  FROM idx
)
SELECT
  small.table_name,
  small.idx_name              AS redundant_index,
  big.idx_name                AS covered_by,
  pg_size_pretty(small.bytes) AS reclaimable
FROM idx_keys small
JOIN idx_keys big
  ON small.table_oid = big.table_oid
 AND small.idx_name <> big.idx_name
 AND small.pred     = big.pred
 AND small.expr     = big.expr
 AND NOT small.indisunique
 -- strict prefix: equal-length identical keys are duplicates → 6b, not here
 AND array_length(small.keycols, 1) < array_length(big.keycols, 1)
 AND small.keycols  = big.keycols[1:array_length(small.keycols,1)]
 AND small.keyops   = big.keyops[1:array_length(small.keycols,1)]
ORDER BY small.bytes DESC;


-- ============================================================================
-- 6d  FKs without a supporting index. Cause of slow cascade DELETEs / parent
-- lock escalation. Index must lead with the FK columns; INCLUDE doesn't
-- count (use indnkeyatts). int2vector → 1-based int[] so [1:N] yields N.
-- ============================================================================
SELECT
  c.conrelid::regclass                          AS table_name,
  c.conname                                     AS fk_constraint,
  array_agg(a.attname ORDER BY x.ord)           AS fk_columns,
  pg_size_pretty(pg_relation_size(c.conrelid))  AS table_size
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, ord)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1
    FROM pg_index i
    WHERE i.indrelid = c.conrelid
      AND i.indislive
      AND array_length(c.conkey, 1) <= i.indnkeyatts
      AND (string_to_array(i.indkey::text, ' ')::int[])[1:array_length(c.conkey, 1)]
          = c.conkey::int[]
  )
GROUP BY c.oid, c.conrelid, c.conname
ORDER BY pg_relation_size(c.conrelid) DESC;


-- ============================================================================
-- 6e  Invalid indexes (failed CREATE INDEX CONCURRENTLY). Cost writes for
-- zero benefit (planner ignores). Drop or rebuild.
-- ============================================================================
SELECT i.indexrelid::regclass                            AS index_name,
       i.indrelid::regclass                              AS table_name,
       pg_size_pretty(pg_relation_size(i.indexrelid))    AS size
FROM pg_index i
WHERE NOT i.indisvalid
ORDER BY pg_relation_size(i.indexrelid) DESC;


-- ============================================================================
-- 6f  Tables without a usable replica identity. No PK / no replicable unique
-- index blocks two things: pg_repack refuses the table, and logical
-- replication UPDATE/DELETE fails ("cannot update table ... because it does
-- not have a replica identity"). relreplident: 'd'=default (uses PK),
-- 'i'=USING INDEX, 'f'=FULL (whole row as key — slow), 'n'=NOTHING.
-- Bad = 'd' with no PK, or 'n'. 'f' flagged separately (works but expensive).
-- Partitions excluded (identity is set on the partitioned parent).
-- ============================================================================
SELECT
  c.oid::regclass                                AS table_name,
  c.relreplident                                 AS replica_identity,
  EXISTS (SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.oid AND i.indisprimary) AS has_pk,
  pg_size_pretty(pg_total_relation_size(c.oid))  AS total_size,
  CASE
    WHEN c.relreplident = 'n' THEN 'NOTHING — no logical UPDATE/DELETE, no repack'
    WHEN c.relreplident = 'd'
     AND NOT EXISTS (SELECT 1 FROM pg_index i
                     WHERE i.indrelid = c.oid AND i.indisprimary)
                              THEN 'default but no PK — same breakage'
    WHEN c.relreplident = 'f' THEN 'FULL — works but whole-row key is slow'
  END                                            AS problem
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND NOT c.relispartition
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND n.nspname NOT LIKE 'pg_temp%'
  AND (
        c.relreplident = 'n'
     OR c.relreplident = 'f'
     OR (c.relreplident = 'd'
         AND NOT EXISTS (SELECT 1 FROM pg_index i
                         WHERE i.indrelid = c.oid AND i.indisprimary))
      )
ORDER BY pg_total_relation_size(c.oid) DESC;

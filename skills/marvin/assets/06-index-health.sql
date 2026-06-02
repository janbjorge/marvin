-- marvin: 06-index-health.sql
-- Phase 6 — unused, duplicate/redundant, missing-FK, and invalid indexes.
-- Read-only.
--
-- Execution model: labelled query catalogue for the pglens `query` MCP tool.
-- pglens also exposes a specialized `unused_indexes` tool — prefer it when
-- available; 6a below is the equivalent raw SQL with the safety filters
-- (excludes unique, primary-key, and constraint-backing indexes).


-- ============================================================================
-- 6a  Unused indexes.
-- Caveats:
--   - stats_reset must be > 7d ago for this to be trustworthy.
--   - On PG16+ pg_stat_user_indexes also has last_idx_scan (timestamp survives
--     stats resets) — Marvin queries that via raw `query` when needed.
--   - Per-replica stats vary; check the right replica.
--   - Partial / quarterly-used indexes may show idx_scan = 0.
--   - FK-supporting and constraint-backing indexes are filtered out.
-- ============================================================================
SELECT
  s.schemaname, s.relname           AS table_name,
  s.indexrelname                    AS index_name,
  s.idx_scan,
  pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
  pg_size_pretty(pg_relation_size(s.relid))      AS table_size
FROM pg_stat_user_indexes s
JOIN pg_index i ON s.indexrelid = i.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisunique
  AND NOT i.indisprimary
  AND NOT EXISTS (
    SELECT 1 FROM pg_constraint c WHERE c.conindid = s.indexrelid
  )
ORDER BY pg_relation_size(s.indexrelid) DESC;


-- ============================================================================
-- 6b  Duplicate indexes (same definition).
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
-- 6c  Prefix-redundant indexes.
-- (a) is redundant if (a,b) exists with the same predicate and opclasses.
-- Unique indexes are excluded — uniqueness can be a one-column property.
-- Slice indkey at indnkeyatts to exclude INCLUDE (covering) columns —
-- an INCLUDE column does not make an index redundant for key-search use.
-- indkey is an int2vector (0-based); convert to a 1-based int[] for slicing.
-- ============================================================================
WITH idx AS (
  SELECT
    indexrelid::regclass                                                AS idx_name,
    indrelid                                                            AS table_oid,
    indrelid::regclass                                                  AS table_name,
    (pg_catalog.string_to_array(pg_catalog.int2vectorout(indkey),' '))::int[]
                                                                        AS keycols_full,
    indnkeyatts,
    indclass::oid[]                                                     AS keyops,
    pg_relation_size(indexrelid)                                        AS bytes,
    COALESCE(indpred::text, '')                                         AS pred,
    indisunique
  FROM pg_index
  WHERE indislive
),
idx_keys AS (
  SELECT
    idx_name, table_oid, table_name,
    keycols_full[1:indnkeyatts] AS keycols,
    keyops[1:indnkeyatts]       AS keyops,
    bytes, pred, indisunique
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
 AND NOT small.indisunique
 AND array_length(small.keycols, 1) <= array_length(big.keycols, 1)
 AND small.keycols  = big.keycols[1:array_length(small.keycols,1)]
 AND small.keyops   = big.keyops[1:array_length(small.keycols,1)]
ORDER BY small.bytes DESC;


-- ============================================================================
-- 6d  Foreign keys without a supporting index.
-- Common cause of slow cascade DELETEs and lock escalations on the parent
-- side. The index must lead with the FK columns in order. Only the leading
-- key portion counts (indnkeyatts) — INCLUDE columns do not satisfy an FK
-- lookup. indkey is int2vector (0-based); convert to a 1-based int[] for
-- slicing so [1:N] returns N elements.
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
    FROM pg_index i,
         LATERAL (
           SELECT (pg_catalog.string_to_array(
                     pg_catalog.int2vectorout(i.indkey), ' '))::int[] AS k
         ) AS conv
    WHERE i.indrelid = c.conrelid
      AND i.indislive
      AND array_length(c.conkey, 1) <= i.indnkeyatts
      AND conv.k[1:array_length(c.conkey, 1)] = c.conkey::int[]
  )
GROUP BY c.oid, c.conrelid, c.conname
ORDER BY pg_relation_size(c.conrelid) DESC;


-- ============================================================================
-- 6e  Invalid indexes (failed CREATE INDEX CONCURRENTLY).
-- These still consume disk and are updated by writes, but ignored by the
-- planner. Drop or rebuild.
-- ============================================================================
SELECT i.indexrelid::regclass                            AS index_name,
       i.indrelid::regclass                              AS table_name,
       pg_size_pretty(pg_relation_size(i.indexrelid))    AS size
FROM pg_index i
WHERE NOT i.indisvalid
ORDER BY pg_relation_size(i.indexrelid) DESC;

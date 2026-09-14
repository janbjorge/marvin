-- marvin: 06-index-health.sql — Phase 6. Read-only.
-- pglens `unused_indexes` filters unique/PK/constraint but NOT FK-supporting
-- indexes; 6a does. Rationale: references/interpretation-thresholds.md.

-- ============================================================================
-- 6a  Unused indexes. Excludes unique / PK / constraint-backing / invalid
-- (6e) and indexes whose leading columns match a FOREIGN KEY on the table
-- (they serve cascades, rarely show scans; dropping one recreates 6d).
-- unused_total is the sum over all rows; severity on it: > 1 GB → HIGH,
-- > 100 MB → MEDIUM. Agent-side gates (cannot be tested here): stats age
-- < 30 d or unsampled standbys (7a) → downgrade one tier and say so.
-- ============================================================================
WITH u AS (
  SELECT s.schemaname, s.relname, s.indexrelname, s.idx_scan, s.last_idx_scan,
         pg_relation_size(s.indexrelid) AS index_bytes,
         pg_relation_size(s.relid)      AS table_bytes
  FROM pg_stat_user_indexes s
  JOIN pg_index i ON s.indexrelid = i.indexrelid
  WHERE s.idx_scan = 0
    AND NOT i.indisunique AND NOT i.indisprimary AND i.indisvalid
    AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = s.indexrelid)
    AND NOT EXISTS (
      SELECT 1 FROM pg_constraint fk
      WHERE fk.contype = 'f' AND fk.conrelid = i.indrelid
        AND array_length(fk.conkey, 1) <= i.indnkeyatts
        AND (string_to_array(i.indkey::text, ' ')::int[])[1:array_length(fk.conkey, 1)]
            = fk.conkey::int[])
)
SELECT
  schemaname, relname AS table_name, indexrelname AS index_name,
  idx_scan, last_idx_scan,
  pg_size_pretty(index_bytes)             AS index_size,
  pg_size_pretty(table_bytes)             AS table_size,
  pg_size_pretty(sum(index_bytes) OVER ()) AS unused_total,
  CASE WHEN sum(index_bytes) OVER () > 1024::bigint^3      THEN 'HIGH'
       WHEN sum(index_bytes) OVER () > 100 * 1024 * 1024   THEN 'MEDIUM' END AS severity
FROM u
ORDER BY index_bytes DESC;


-- ============================================================================
-- 6b  Duplicate indexes (identical definition). severity: combined > 1 GB →
-- MEDIUM, else LOW.
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
  array_agg(idx_name ORDER BY idx_name)               AS indexes,
  CASE WHEN sum(bytes) > 1024::bigint^3 THEN 'MEDIUM' ELSE 'LOW' END AS severity
FROM idx
GROUP BY table_name, indrelid, indkey, indclass, indoption, expr, pred
HAVING count(*) > 1
ORDER BY sum(bytes) DESC;


-- ============================================================================
-- 6c  Prefix-redundant: (a) is covered by (a,b) with the same predicate,
-- expression and opclasses. Unique excluded; INCLUDE columns sliced off at
-- indnkeyatts; strict prefix (equal keys → 6b). PG18 skip scan is the reverse
-- direction and does not relax this rule. severity: > 1 GB → MEDIUM, else LOW.
-- ============================================================================
WITH idx AS (
  SELECT
    indexrelid::regclass                                                AS idx_name,
    indrelid                                                            AS table_oid,
    indrelid::regclass                                                  AS table_name,
    (string_to_array(indkey::text, ' ')::int[])[1:indnkeyatts]          AS keycols,
    (indclass::oid[])[1:indnkeyatts]                                    AS keyops,
    pg_relation_size(indexrelid)                                        AS bytes,
    COALESCE(indpred::text, '')                                         AS pred,
    COALESCE(indexprs::text, '')                                        AS expr,
    indisunique
  FROM pg_index
  WHERE indislive
)
SELECT
  small.table_name,
  small.idx_name              AS redundant_index,
  big.idx_name                AS covered_by,
  pg_size_pretty(small.bytes) AS reclaimable,
  CASE WHEN small.bytes > 1024::bigint^3 THEN 'MEDIUM' ELSE 'LOW' END AS severity
FROM idx small
JOIN idx big
  ON small.table_oid = big.table_oid
 AND small.idx_name <> big.idx_name
 AND small.pred     = big.pred
 AND small.expr     = big.expr
 AND NOT small.indisunique
 AND array_length(small.keycols, 1) < array_length(big.keycols, 1)
 AND small.keycols  = big.keycols[1:array_length(small.keycols,1)]
 AND small.keyops   = big.keyops[1:array_length(small.keycols,1)]
ORDER BY small.bytes DESC;


-- ============================================================================
-- 6d  FKs without a supporting index (slow cascades, parent lock escalation).
-- Index must lead with the FK columns; INCLUDE doesn't count. severity:
-- table > 1 GB → HIGH, else MEDIUM.
-- ============================================================================
SELECT
  c.conrelid::regclass                          AS table_name,
  c.conname                                     AS fk_constraint,
  array_agg(a.attname ORDER BY x.ord)           AS fk_columns,
  pg_size_pretty(pg_relation_size(c.conrelid))  AS table_size,
  CASE WHEN pg_relation_size(c.conrelid) > 1024::bigint^3 THEN 'HIGH' ELSE 'MEDIUM' END AS severity
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, ord)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid AND i.indislive
      AND array_length(c.conkey, 1) <= i.indnkeyatts
      AND (string_to_array(i.indkey::text, ' ')::int[])[1:array_length(c.conkey, 1)]
          = c.conkey::int[])
GROUP BY c.oid, c.conrelid, c.conname
ORDER BY pg_relation_size(c.conrelid) DESC;


-- ============================================================================
-- 6e  Invalid indexes (failed CREATE INDEX CONCURRENTLY). Cost writes, never
-- used by the planner. Any row → HIGH. Drop or rebuild.
-- ============================================================================
SELECT i.indexrelid::regclass                            AS index_name,
       i.indrelid::regclass                              AS table_name,
       pg_size_pretty(pg_relation_size(i.indexrelid))    AS size
FROM pg_index i
WHERE NOT i.indisvalid
ORDER BY pg_relation_size(i.indexrelid) DESC;


-- ============================================================================
-- 6f  Tables without a usable replica identity: pg_repack refuses them and
-- logical replication UPDATE/DELETE fails. severity: NOTHING or default-
-- without-PK → HIGH (when logically replicated or a repack target); FULL →
-- MEDIUM (works, whole-row key is slow). Partitions excluded.
-- ============================================================================
WITH t AS (
  SELECT c.oid, c.relreplident,
         EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary) AS has_pk
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND NOT c.relispartition
    AND n.nspname NOT IN ('pg_catalog','information_schema')
    AND n.nspname NOT LIKE 'pg_temp%'
)
SELECT
  oid::regclass                                  AS table_name,
  relreplident                                   AS replica_identity,
  has_pk,
  pg_size_pretty(pg_total_relation_size(oid))    AS total_size,
  CASE relreplident
    WHEN 'n' THEN 'NOTHING — no logical UPDATE/DELETE, no repack'
    WHEN 'd' THEN 'default but no PK — same breakage'
    WHEN 'f' THEN 'FULL — works but whole-row key is slow'
  END                                            AS problem,
  CASE WHEN relreplident = 'f' THEN 'MEDIUM' ELSE 'HIGH' END AS severity
FROM t
WHERE relreplident IN ('n','f') OR (relreplident = 'd' AND NOT has_pk)
ORDER BY pg_total_relation_size(oid) DESC;

-- postgres-health-review: 06-index-health.sql
-- Phase 6 — unused, duplicate/redundant, missing-FK, and invalid indexes.
-- Read-only.

\set QUIET on
\pset pager off

SET application_name = 'health-review';
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET default_transaction_read_only = on;

\echo
\echo '================================================================'
\echo ' PHASE 6a — Unused indexes'
\echo '================================================================'
\echo '   Caveats: stats_reset must be > 7d ago; per-replica stats vary;'
\echo '   partial indexes may be used quarterly; FK-supporting indexes excluded.'
\echo

SELECT
  s.schemaname, s.relname AS table_name,
  s.indexrelname AS index_name,
  s.idx_scan,
  pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
  pg_size_pretty(pg_relation_size(s.relid)) AS table_size
FROM pg_stat_user_indexes s
JOIN pg_index i ON s.indexrelid = i.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisunique
  AND NOT i.indisprimary
  AND NOT EXISTS (
    SELECT 1 FROM pg_constraint c WHERE c.conindid = s.indexrelid
  )
ORDER BY pg_relation_size(s.indexrelid) DESC;

\echo
\echo '================================================================'
\echo ' PHASE 6b — Duplicate indexes (same definition)'
\echo '================================================================'
\echo

WITH idx AS (
  SELECT
    indexrelid::regclass AS idx_name,
    indrelid::regclass AS table_name,
    pg_relation_size(indexrelid) AS bytes,
    indrelid, indkey, indclass, indoption,
    COALESCE(indexprs::text, '') AS expr,
    COALESCE(indpred::text, '')  AS pred
  FROM pg_index
  WHERE indislive
)
SELECT
  table_name,
  pg_size_pretty(sum(bytes)::bigint) AS combined_size,
  array_agg(idx_name ORDER BY idx_name) AS indexes
FROM idx
GROUP BY table_name, indrelid, indkey, indclass, indoption, expr, pred
HAVING count(*) > 1
ORDER BY sum(bytes) DESC;

\echo
\echo '================================================================'
\echo ' PHASE 6c — Prefix-redundant indexes'
\echo '================================================================'
\echo '   (a) is redundant if (a,b) exists with same predicate & opclass'
\echo

WITH idx AS (
  SELECT
    indexrelid::regclass AS idx_name,
    indrelid AS table_oid,
    indrelid::regclass AS table_name,
    indkey::int[] AS keycols,
    indclass::oid[] AS keyops,
    pg_relation_size(indexrelid) AS bytes,
    COALESCE(indpred::text,'') AS pred,
    indisunique
  FROM pg_index
  WHERE indislive
)
SELECT
  small.table_name,
  small.idx_name AS redundant_index,
  big.idx_name   AS covered_by,
  pg_size_pretty(small.bytes) AS reclaimable
FROM idx small
JOIN idx big
  ON small.table_oid = big.table_oid
 AND small.idx_name <> big.idx_name
 AND small.pred = big.pred
 AND NOT small.indisunique
 AND array_length(small.keycols, 1) <= array_length(big.keycols, 1)
 AND small.keycols = big.keycols[1:array_length(small.keycols,1)]
 AND small.keyops  = big.keyops[1:array_length(small.keycols,1)]
ORDER BY small.bytes DESC;

\echo
\echo '================================================================'
\echo ' PHASE 6d — Foreign keys without a supporting index'
\echo '================================================================'
\echo '   Common cause of slow cascade DELETEs and lock escalations.'
\echo

SELECT
  c.conrelid::regclass AS table_name,
  c.conname AS fk_constraint,
  array_agg(a.attname ORDER BY x.ord) AS fk_columns,
  pg_size_pretty(pg_relation_size(c.conrelid)) AS table_size
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, ord)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid
      AND (i.indkey::int[])[0:array_length(c.conkey,1)-1] = c.conkey::int[]
  )
GROUP BY c.oid, c.conrelid, c.conname
ORDER BY pg_relation_size(c.conrelid) DESC;

\echo
\echo '================================================================'
\echo ' PHASE 6e — Invalid indexes (failed CREATE INDEX CONCURRENTLY)'
\echo '================================================================'
\echo

SELECT i.indexrelid::regclass AS index_name,
       i.indrelid::regclass   AS table_name,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS size
FROM pg_index i
WHERE NOT i.indisvalid
ORDER BY pg_relation_size(i.indexrelid) DESC;

\echo
\echo '-- Phase 6 complete --'

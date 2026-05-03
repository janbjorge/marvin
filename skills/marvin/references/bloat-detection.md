# Bloat Detection — Statistics-Based Estimation

These queries estimate bloat without scanning every page (unlike `pgstattuple`). They compute the *expected* relation size from `pg_class.reltuples`, column widths from `pg_statistic`, fillfactor, and per-page overhead, then compare to the actual size. The gap is "bloat."

The math originates with the pgexperts team and is maintained at https://github.com/ioguix/pgsql-bloat-estimation. These versions handle PG 12–17.

**Important caveats:**
- Estimates require fresh statistics. If `last_analyze` is old, results lie. Always cross-check `pg_stat_user_tables.last_analyze` for any flagged table.
- Toast tables and small tables (< 8 pages) are filtered out — noise dominates.
- Numbers are reasonable to within ~10–15% on healthy stats. For exact accounting, use `pgstattuple` per table.
- The query reads catalogs only; it doesn't take row locks.

## Table bloat

```sql
-- Estimate table bloat (pgexperts-style, PG12+)
SELECT
  current_database() AS db,
  schemaname,
  tblname,
  bs * tblpages AS real_size,
  (tblpages - est_tblpages) * bs AS extra_size,
  CASE WHEN tblpages > 0 AND tblpages - est_tblpages > 0
       THEN 100 * (tblpages - est_tblpages) / tblpages::float
       ELSE 0
  END AS extra_pct,
  fillfactor,
  CASE WHEN tblpages - est_tblpages_ff > 0
       THEN (tblpages - est_tblpages_ff) * bs
       ELSE 0
  END AS bloat_size,
  CASE WHEN tblpages > 0 AND tblpages - est_tblpages_ff > 0
       THEN 100 * (tblpages - est_tblpages_ff) / tblpages::float
       ELSE 0
  END AS bloat_pct,
  is_na
FROM (
  SELECT
    ceil( reltuples / ( (bs - page_hdr) / tpl_size ) ) + ceil( toasttuples / 4 ) AS est_tblpages,
    ceil( reltuples / ( (bs - page_hdr) * fillfactor / (tpl_size*100) ) ) + ceil( toasttuples / 4 ) AS est_tblpages_ff,
    tblpages, fillfactor, bs, tblid, schemaname, tblname, heappages, toastpages, is_na
  FROM (
    SELECT
      ( 4 + tpl_hdr_size + tpl_data_size + (2 * ma)
        - CASE WHEN tpl_hdr_size % ma = 0 THEN ma ELSE tpl_hdr_size % ma END
        - CASE WHEN ceil(tpl_data_size)::int % ma = 0 THEN ma ELSE ceil(tpl_data_size)::int % ma END
      ) AS tpl_size,
      bs - page_hdr AS size_per_block,
      (heappages + toastpages) AS tblpages, heappages,
      toastpages, reltuples, toasttuples, bs, page_hdr,
      tblid, schemaname, tblname, fillfactor, is_na
    FROM (
      SELECT
        tbl.oid AS tblid, ns.nspname AS schemaname, tbl.relname AS tblname,
        tbl.reltuples, tbl.relpages AS heappages,
        coalesce(toast.relpages, 0) AS toastpages,
        coalesce(toast.reltuples, 0) AS toasttuples,
        coalesce(substring(
          array_to_string(tbl.reloptions, ' ') FROM 'fillfactor=([0-9]+)')::smallint, 100) AS fillfactor,
        current_setting('block_size')::numeric AS bs,
        CASE WHEN version() ~ 'mingw32' OR version() ~ '64-bit|x86_64|ppc64|ia64|amd64' THEN 8 ELSE 4 END AS ma,
        24 AS page_hdr,
        23 + CASE WHEN MAX(coalesce(s.null_frac,0)) > 0 THEN ( 7 + count(s.attname) ) / 8 ELSE 0::int END
           + CASE WHEN bool_or(att.attname = 'oid' and att.attnum < 0) THEN 4 ELSE 0 END AS tpl_hdr_size,
        sum( (1 - coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 0) ) AS tpl_data_size,
        bool_or(att.atttypid = 'pg_catalog.name'::regtype)
           OR sum(CASE WHEN att.attnum > 0 THEN 1 ELSE 0 END) <> count(s.attname) AS is_na
      FROM pg_attribute AS att
        JOIN pg_class AS tbl ON att.attrelid = tbl.oid
        JOIN pg_namespace AS ns ON ns.oid = tbl.relnamespace
        LEFT JOIN pg_stats AS s ON s.schemaname=ns.nspname
                               AND s.tablename = tbl.relname AND s.inherited=false
                               AND s.attname=att.attname
        LEFT JOIN pg_class AS toast ON tbl.reltoastrelid = toast.oid
      WHERE NOT att.attisdropped
        AND tbl.relkind in ('r','m')
        AND ns.nspname NOT IN ('pg_catalog','information_schema')
      GROUP BY 1,2,3,4,5,6,7,8,9,10
      ORDER BY 2,3
    ) AS s
  ) AS s2
) AS s3
WHERE NOT is_na
  AND tblpages * bs > 100 * 1024 * 1024     -- > 100 MB only
ORDER BY bloat_size DESC NULLS LAST
LIMIT 25;
```

Output columns of interest:
- `real_size` — actual on-disk size including TOAST
- `bloat_size` — bytes wasted accounting for fillfactor (this is the headline number)
- `bloat_pct` — same as percentage
- `is_na` — `true` means the estimate is unreliable for this table (usually missing stats or `pg_catalog.name`-typed columns); skip it

## Index bloat (B-tree only)

The query is structurally similar but operates on `pg_index` and accounts for B-tree page layout, including the metapage and internal vs leaf pages. It does NOT estimate GIN/GiST/BRIN/HASH/SP-GiST bloat — the math doesn't generalize.

```sql
-- Estimate B-tree index bloat (pgexperts-style, PG12+)
SELECT
  current_database() AS db, nspname AS schemaname, tblname, idxname,
  bs * (relpages) AS real_size,
  bs * (relpages - est_pages) AS extra_size,
  CASE WHEN relpages > 0 AND relpages - est_pages > 0
       THEN 100 * (relpages - est_pages) / relpages::float
       ELSE 0
  END AS extra_pct,
  fillfactor,
  CASE WHEN relpages - est_pages_ff > 0
       THEN bs * (relpages - est_pages_ff)
       ELSE 0
  END AS bloat_size,
  CASE WHEN relpages > 0 AND relpages - est_pages_ff > 0
       THEN 100 * (relpages - est_pages_ff) / relpages::float
       ELSE 0
  END AS bloat_pct,
  is_na
FROM (
  SELECT
    coalesce(1 +
      ceil(reltuples / floor((bs - pageopqdata - pagehdr) / (4 + nulldatahdrwidth)::float)), 0)
      AS est_pages,
    coalesce(1 +
      ceil(reltuples / floor((bs - pageopqdata - pagehdr) * fillfactor / (100 * (4 + nulldatahdrwidth)::float))), 0)
      AS est_pages_ff,
    bs, nspname, tblname, idxname, relpages, fillfactor, is_na
  FROM (
    SELECT
      maxalign, bs, nspname, tblname, idxname, reltuples, relpages, idxoid, fillfactor,
      ( index_tuple_hdr_bm + maxalign
        - CASE WHEN index_tuple_hdr_bm % maxalign = 0 THEN maxalign ELSE index_tuple_hdr_bm % maxalign END
        + nulldatawidth + maxalign
        - CASE WHEN nulldatawidth = 0 THEN 0
               WHEN nulldatawidth::integer % maxalign = 0 THEN maxalign
               ELSE nulldatawidth::integer % maxalign
          END
      ) AS nulldatahdrwidth, pagehdr, pageopqdata, is_na
    FROM (
      SELECT
        i.nspname, i.tblname, i.idxname, i.reltuples, i.relpages, i.idxoid, i.fillfactor,
        current_setting('block_size')::numeric AS bs,
        CASE WHEN version() ~ 'mingw32' OR version() ~ '64-bit|x86_64|ppc64|ia64|amd64' THEN 8 ELSE 4 END AS maxalign,
        24 AS pagehdr,
        16 AS pageopqdata,
        CASE WHEN max(coalesce(s.null_frac, 0)) = 0 THEN 8 ELSE 8 + ((32 + 8 - 1) / 8) END AS index_tuple_hdr_bm,
        sum( (1 - coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 1024) ) AS nulldatawidth,
        max(CASE WHEN i.atttypid = 'pg_catalog.name'::regtype THEN 1 ELSE 0 END) > 0 AS is_na
      FROM (
        SELECT ct.relname AS tblname, ct.relnamespace, ic.idxname, ic.attpos, ic.indkey, ic.indkey[ic.attpos] AS attnum,
               ic.attname, ic.atttypid, ic.indclass, ic.idxoid, ic.fillfactor, ic.indrelid, ic.reltuples, ic.relpages
        FROM (
          SELECT idxname, attpos, indkey, indkey[attpos] AS attnum, attname,
                 atttypid::regtype, indclass, idxoid, fillfactor, indrelid, reltuples, relpages
          FROM (
            SELECT
              ci.relname AS idxname, ci.reltuples, ci.relpages, i.indrelid, i.indexrelid AS idxoid,
              coalesce(substring(array_to_string(ci.reloptions, ' ') FROM 'fillfactor=([0-9]+)')::smallint, 90) AS fillfactor,
              i.indnatts,
              pg_catalog.string_to_array(pg_catalog.textin(pg_catalog.int2vectorout(i.indkey)),' ')::int[] AS indkey,
              i.indclass, generate_series(1, i.indnatts) AS attpos
            FROM pg_index i
            JOIN pg_class ci ON ci.oid = i.indexrelid
            WHERE ci.relam = (SELECT oid FROM pg_am WHERE amname = 'btree')
              AND ci.relpages > 0
          ) sub2
          JOIN pg_attribute a ON a.attrelid = idxoid
                              AND a.attnum = attpos
        ) AS ic
        JOIN pg_class ct ON ct.oid = ic.indrelid
      ) AS i
      JOIN pg_namespace n ON n.oid = i.relnamespace
      LEFT JOIN pg_stats s ON s.schemaname = n.nspname
                          AND s.tablename = i.tblname
                          AND s.attname = i.attname
      GROUP BY 1,2,3,4,5,6,7,8,9,10,11
    ) AS rows_data_stats
  ) AS rows_hdr_pdg_stats
) AS relation_stats
WHERE NOT is_na
  AND relpages * bs > 50 * 1024 * 1024    -- > 50 MB only
ORDER BY bloat_size DESC NULLS LAST
LIMIT 25;
```

## When to use `pgstattuple` instead

Use `pgstattuple` (the contrib extension) when:
- You need exact numbers (e.g., justifying a maintenance window)
- Estimate query flagged a table but stats are stale
- You need free-space-fragmentation breakdown beyond just dead-tuple percentage

```sql
-- Exact: full sequential scan + share lock
SELECT * FROM pgstattuple('schema.table');

-- Sampled: faster, ~2-5% sample, lower lock impact (PG9.5+)
SELECT * FROM pgstattuple_approx('schema.table');

-- Index page fill / dead-page percentage
SELECT * FROM pgstatindex('schema.index_name');

-- Index tuple counts (B-tree only, very fast)
SELECT * FROM pgstatginindex('schema.gin_index');
```

`pgstattuple_approx` is the practical default for spot-checking — it's fast enough to run during business hours on most tables.

## Interpreting bloat numbers

**Some bloat is normal and good.** A table with `fillfactor = 90` is intentionally 10% empty to leave room for HOT updates. A B-tree index running near 70% leaf density is healthy — split-and-fill leaves room for inserts without page splits.

The questions that matter:
1. **Is bloat growing?** A stable 30% is fine; 30% growing 1% per day is not.
2. **Is the table update-heavy?** HOT-update-friendly schemas (no indexed columns updated) keep bloat self-managed; otherwise vacuum has to clean up.
3. **Is autovacuum keeping up?** `last_autovacuum` recent + `n_dead_tup` low = healthy. `last_autovacuum` recent + `n_dead_tup` high = autovacuum can't reclaim because xmin horizon is held back. Hunt the long transaction.

## Sources

- pgexperts/ioguix bloat queries: https://github.com/ioguix/pgsql-bloat-estimation
- `pgstattuple` docs: https://www.postgresql.org/docs/current/pgstattuple.html
- HOT updates explained: https://www.postgresql.org/docs/current/storage-hot.html

-- marvin: 02-bloat-pgexperts.sql — Phase 2. Catalog-only, no row locks.
-- Source: https://github.com/ioguix/pgsql-bloat-estimation (BSD).
-- Pgexperts math compares actual pages against expected pages computed from
-- reltuples + pg_statistic widths + fillfactor + page overhead. n_dead_tup
-- ratio is vacuum lag, NOT bloat — see references/interpretation-thresholds.md.

-- ============================================================================
-- 2a  Table bloat (> 100 MB). is_na = skip the row; stale stats (2a-stats) =
-- unreliable. severity: bloat_pct > 20 AND bloat_size > 1 GB → HIGH, > 100 MB
-- → MEDIUM. Borderline → propose pgstattuple_approx('schema.table'); never
-- run pgstattuple() (full scan + share lock) without confirmation.
-- ============================================================================
SELECT
  current_database()                                            AS db,
  schemaname,
  tblname,
  pg_size_pretty((bs * tblpages)::bigint)                       AS real_size,
  pg_size_pretty(GREATEST((tblpages - est_tblpages) * bs, 0)::bigint) AS extra_size,
  CASE WHEN tblpages > 0 AND tblpages - est_tblpages > 0
       THEN round((100 * (tblpages - est_tblpages) / tblpages::float)::numeric, 1)
       ELSE 0
  END                                                           AS extra_pct,
  fillfactor,
  pg_size_pretty(GREATEST((tblpages - est_tblpages_ff) * bs, 0)::bigint) AS bloat_size,
  CASE WHEN tblpages > 0 AND tblpages - est_tblpages_ff > 0
       THEN round((100 * (tblpages - est_tblpages_ff) / tblpages::float)::numeric, 1)
       ELSE 0
  END                                                           AS bloat_pct,
  is_na,
  CASE WHEN tblpages > 0 AND 100 * (tblpages - est_tblpages_ff) / tblpages::float > 20
        AND (tblpages - est_tblpages_ff) * bs > 1024::bigint^3        THEN 'HIGH'
       WHEN tblpages > 0 AND 100 * (tblpages - est_tblpages_ff) / tblpages::float > 20
        AND (tblpages - est_tblpages_ff) * bs > 100 * 1024 * 1024     THEN 'MEDIUM'
  END                                                           AS severity
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
           + CASE WHEN bool_or(att.attname = 'oid' AND att.attnum < 0) THEN 4 ELSE 0 END AS tpl_hdr_size,
        sum( (1 - coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 0) ) AS tpl_data_size,
        bool_or(att.atttypid = 'pg_catalog.name'::regtype)
           OR sum(CASE WHEN att.attnum > 0 THEN 1 ELSE 0 END) <> count(s.attname) AS is_na
      FROM pg_attribute AS att
        JOIN pg_class AS tbl ON att.attrelid = tbl.oid
        JOIN pg_namespace AS ns ON ns.oid = tbl.relnamespace
        LEFT JOIN pg_stats AS s ON s.schemaname = ns.nspname
                               AND s.tablename = tbl.relname
                               AND s.inherited = false
                               AND s.attname = att.attname
        LEFT JOIN pg_class AS toast ON tbl.reltoastrelid = toast.oid
      WHERE NOT att.attisdropped
        AND tbl.relkind IN ('r','m')
        AND ns.nspname NOT IN ('pg_catalog','information_schema')
      GROUP BY 1,2,3,4,5,6,7,8,9,10
    ) AS s
  ) AS s2
) AS s3
WHERE NOT is_na
  AND tblpages * bs > 100 * 1024 * 1024
ORDER BY GREATEST((tblpages - est_tblpages_ff) * bs, 0) DESC NULLS LAST
LIMIT 25;


-- ============================================================================
-- 2a-stats  Stats freshness for the top tables. Stale → recommend ANALYZE.
-- ============================================================================
SELECT
  schemaname, relname,
  last_analyze, last_autoanalyze,
  now() - GREATEST(last_analyze, last_autoanalyze) AS stats_age,
  pg_size_pretty(pg_relation_size(relid))          AS size
FROM pg_stat_user_tables
WHERE pg_relation_size(relid) > 100 * 1024 * 1024
ORDER BY pg_relation_size(relid) DESC
LIMIT 25;


-- ============================================================================
-- 2b  B-tree index bloat (> 50 MB). GIN/GiST/BRIN/HASH/SP-GiST not covered.
-- severity: bloat_pct > 50 AND bloat_size > 1 GB → MEDIUM, > 100 MB → LOW.
-- Never HIGH on the estimate alone (Cybertec: ~70% is normal for B-trees);
-- rebuild on low AND falling pgstatindex().avg_leaf_density.
-- ============================================================================
SELECT
  current_database()                                                   AS db,
  nspname                                                              AS schemaname,
  tblname,
  idxname,
  pg_size_pretty((bs * relpages)::bigint)                              AS real_size,
  pg_size_pretty(GREATEST(bs * (relpages - est_pages), 0)::bigint)     AS extra_size,
  CASE WHEN relpages > 0 AND relpages - est_pages > 0
       THEN round((100 * (relpages - est_pages) / relpages::float)::numeric, 1)
       ELSE 0
  END                                                                  AS extra_pct,
  fillfactor,
  pg_size_pretty(GREATEST(bs * (relpages - est_pages_ff), 0)::bigint)  AS bloat_size,
  CASE WHEN relpages > 0 AND relpages - est_pages_ff > 0
       THEN round((100 * (relpages - est_pages_ff) / relpages::float)::numeric, 1)
       ELSE 0
  END                                                                  AS bloat_pct,
  is_na,
  CASE WHEN relpages > 0 AND 100 * (relpages - est_pages_ff) / relpages::float > 50
        AND bs * (relpages - est_pages_ff) > 1024::bigint^3           THEN 'MEDIUM'
       WHEN relpages > 0 AND 100 * (relpages - est_pages_ff) / relpages::float > 50
        AND bs * (relpages - est_pages_ff) > 100 * 1024 * 1024        THEN 'LOW'
  END                                                                  AS severity
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
        n.nspname, i.tblname, i.idxname, i.reltuples, i.relpages, i.idxoid, i.fillfactor,
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
  AND relpages * (current_setting('block_size')::numeric) > 50 * 1024 * 1024
ORDER BY GREATEST(bs * (relpages - est_pages_ff), 0) DESC NULLS LAST
LIMIT 25;

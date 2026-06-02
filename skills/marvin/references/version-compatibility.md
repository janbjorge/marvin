# PostgreSQL Version Compatibility Matrix

This skill targets **PostgreSQL 16 and 17**. Pre-PG16 is not supported — the headline signals the audit relies on (`pg_stat_io`, `last_seq_scan` / `last_idx_scan`, `n_tup_newpage_upd`, `total_plan_time`, `wal_bytes`) all require PG16 or newer.

## Pre-flight version detection

`assets/00-preflight.sql` block `0-version` returns:

```sql
SELECT
  current_setting('server_version_num')::int           AS pg_ver,
  current_setting('server_version_num')::int >= 160000 AS pg16_plus,
  current_setting('server_version_num')::int >= 170000 AS pg17_plus,
  pg_is_in_recovery()                                  AS is_replica;
```

- `pg16_plus` is the **floor check**. If false, abort the audit.
- `pg17_plus` drives the one column-rename branch (5b) and the `pg_stat_checkpointer` split.

## Major PG16 / PG17 differences the audit branches on

### `pg_stat_statements`

| Column | PG16 | PG17 |
|---|---|---|
| `blk_read_time`, `blk_write_time` | present | **removed** |
| `shared_blk_read_time`, `shared_blk_write_time` | not present | present |
| `local_blk_read_time`, `local_blk_write_time` | not present | present |
| `temp_blk_read_time`, `temp_blk_write_time` | not present | present |
| `total_plan_time`, `total_exec_time`, `mean_exec_time`, `stddev_exec_time` | present | present |
| `wal_bytes`, `wal_records`, `wal_fpi` | present | present |
| `stats_since`, `minmax_stats_since` | not present | present |

`assets/05-workload-hotspots.sql` ships two `5b` blocks (`[PG16]` and `[PG17+]`). All other 5-series blocks use columns that exist identically on both majors.

### Checkpointer / bgwriter

| View | PG16 | PG17 |
|---|---|---|
| `pg_stat_bgwriter` | combined: `checkpoints_*`, `buffers_checkpoint`, `buffers_clean`, `buffers_backend`, `buffers_alloc` | bgwriter-only: `buffers_clean`, `buffers_alloc`, etc. |
| `pg_stat_checkpointer` | does not exist | `num_timed`, `num_requested`, `write_time`, `sync_time`, `buffers_written`, `slru_written`, `restartpoints_*` |

Phase 8 (when shipped) will branch on `pg17_plus`.

### `pg_stat_io` (PG16+)

Per-backend-type, per-context I/O attribution. Use it instead of `pg_statio_user_tables` whenever applicable. Columns of interest: `backend_type`, `object`, `context`, `reads`, `writes`, `extends`, `hits`, `evictions`, `fsyncs`.

```sql
SELECT backend_type, object, context, reads, writes, extends, hits, evictions
FROM pg_stat_io;
```

`backend_type` values include `client backend`, `autovacuum worker`, `checkpointer`, `background worker`, `walwriter`. `context` values include `normal`, `vacuum`, `bulkread`, `bulkwrite`. PG17 added more context resolution but no rename.

### `pg_stat_user_tables` / `pg_stat_user_indexes` (PG16+)

`last_seq_scan` and `last_idx_scan` timestamps survive stats resets — much better than the `seq_scan` / `idx_scan` counters alone. Used by Phase 5f2 and (when applicable) Phase 6 follow-up queries.

### Autovacuum / HOT updates

- `n_tup_newpage_upd` was added in PG16. Distinguishes updates that placed the new row on a new page (no room on the original) from cold updates (different page reachable via index). Used in Phase 5g.
- `vacuum_failsafe_age` (PG14+) — emergency mode kicks in at this xid age. Still present on PG16/17.

### Other PG17 gotchas

- `pg_stat_progress_vacuum.delay_time` added — useful when watching a long vacuum.
- `MERGE ... RETURNING` produces `pg_stat_statements` entries with `query_type` reflecting MERGE.
- Logical replication slots can be exported/imported between major versions — irrelevant to the audit but worth knowing.

## Branches summary (what the audit actually needs to switch on)

| Block | Variants shipped | Driven by |
|---|---|---|
| `5b` | `[PG16]`, `[PG17+]` | `pg17_plus` |

That's the only one for now. Everything else in `assets/*.sql` runs identically on PG16 and PG17.

## What got dropped vs the previous PG12-17 matrix

- All PG12 / PG13 / PG14 / PG15 variant blocks were removed (Marvin no longer supports them).
- The PG13 `pg_stat_statements` rename (`total_time` → `total_exec_time`) is no longer a branch — the new names are required.
- PG14's `pg_stat_wal` (still present on PG16) is in scope. Phase 8 (when shipped) will use it.

Pin marvin to a pre-`PG16+ floor` tag if you still operate PG12-15.

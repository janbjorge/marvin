# PG version matrix

Marvin requires **PG16+**. The headline signals (`pg_stat_io`, `last_seq_scan` / `last_idx_scan`, `n_tup_newpage_upd`, `total_plan_time`, `wal_bytes`) all need PG16 or newer.

`assets/00-preflight.sql` block `0-version` returns the version flags every later asset reads:

```sql
SELECT
  current_setting('server_version_num')::int           AS pg_ver,
  current_setting('server_version_num')::int >= 160000 AS pg16_plus,
  current_setting('server_version_num')::int >= 170000 AS pg17_plus,
  pg_is_in_recovery()                                  AS is_replica;
```

If `pg16_plus = false`, abort.

## PG17 vs PG16 differences the audit branches on

### `pg_stat_statements` column rename — **the only remaining branch**

| Column | PG16 | PG17 |
|---|---|---|
| `blk_read_time` / `blk_write_time` | present | **removed** |
| `shared_blk_read_time` / `shared_blk_write_time` | absent | present |
| `local_blk_*_time`, `temp_blk_*_time` | absent | present |
| `stats_since`, `minmax_stats_since` | absent | present |

→ `assets/05-workload-hotspots.sql` ships `5b [PG16]` and `5b [PG17+]`. Agent picks via `pg17_plus`.

### Other notable differences (no branch shipped yet)

- **`pg_stat_checkpointer`** (PG17 new): `num_timed`, `num_requested`, `write_time`, `sync_time`, `buffers_written`, `slru_written`, `restartpoints_*`. Phase 8 will branch on this when shipped.
- **`pg_stat_bgwriter`** (PG17): checkpoint-related columns moved to `pg_stat_checkpointer`; bgwriter-only columns remain.
- **`pg_stat_progress_vacuum.delay_time`** (PG17 new) — useful when watching a long vacuum.

### PG16+ features marvin relies on

- `pg_stat_io` — per-backend-type, per-context I/O attribution (`backend_type`, `object`, `context`, `reads`, `writes`, `extends`, `hits`, `evictions`, `fsyncs`).
- `pg_stat_user_tables` / `pg_stat_user_indexes`: `last_seq_scan`, `last_idx_scan` (timestamps survive stats resets).
- `pg_stat_user_tables.n_tup_newpage_upd` — distinguishes updates placed on a new page from cold updates.

## Pre-PG16

Not supported. Pin marvin to a pre-`PG16+ floor` tag if you still operate PG12–15.

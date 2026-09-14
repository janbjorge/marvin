# PG version matrix

Marvin requires **PG16+** and is verified through **PG18**. PG19 (beta as of 2026-09) is not targeted. The headline signals (`pg_stat_io`, `last_seq_scan` / `last_idx_scan`, `n_tup_newpage_upd`, `total_plan_time`, `wal_bytes`) all need PG16 or newer.

`assets/00-preflight.sql` block `0-version` returns the version flags every later asset reads:

```sql
SELECT
  current_setting('server_version_num')::int           AS pg_ver,
  current_setting('server_version_num')::int >= 160000 AS pg16_plus,
  current_setting('server_version_num')::int >= 170000 AS pg17_plus,
  current_setting('server_version_num')::int >= 180000 AS pg18_plus,
  pg_is_in_recovery()                                  AS is_replica;
```

If `pg16_plus = false`, abort.

## Which blocks branch

| Flag | Blocks |
|---|---|
| `pg17_plus` | `1b [PG16]` / `1b [PG17+]`, `5b [PG16]` / `5b [PG17+]`, `5k [PG16]` / `5k [PG17+]`, `3c-progress [PG16]` / `3c-progress [PG17+]` |
| `pg18_plus` | run additionally: `3f [PG18]`, `5i2 [PG18]`, `7e [PG18]` |
| none | everything else — PG18-only GUCs are read through `pg_settings` and return no row on older majors |

## PG17 vs PG16 differences the audit branches on

### `pg_stat_statements` column rename

| Column | PG16 | PG17 |
|---|---|---|
| `blk_read_time` / `blk_write_time` | present | **removed** |
| `shared_blk_read_time` / `shared_blk_write_time` | absent | present |
| `local_blk_*_time`, `temp_blk_*_time` | absent | present |
| `stats_since`, `minmax_stats_since` | absent | present |

→ `assets/05-workload-hotspots.sql` ships `5b [PG16]` and `5b [PG17+]`. Agent picks via `pg17_plus`.

### Checkpoint stats — second branch (`5k`)

`assets/05-workload-hotspots.sql` ships `5k [PG16]` (`pg_stat_bgwriter`) and `5k [PG17+]` (`pg_stat_checkpointer`). Agent picks via `pg17_plus`.

| Column | PG16 (`pg_stat_bgwriter`) | PG17 (`pg_stat_checkpointer`) |
|---|---|---|
| timed checkpoints | `checkpoints_timed` | `num_timed` |
| requested checkpoints | `checkpoints_req` | `num_requested` |
| write / sync time | `checkpoint_write_time` / `checkpoint_sync_time` | `write_time` / `sync_time` |
| buffers written by ckpt | `buffers_checkpoint` | `buffers_written` |
| restartpoints (replica) | — | `restartpoints_timed` / `restartpoints_req` / `restartpoints_done` |

`req_pct` = requested / (requested + timed). `> 30%` → raise `max_wal_size` (see `interpretation-thresholds.md`).

### `pg_stat_progress_vacuum` dead-tuple columns — third branch (`3c-progress`)

| PG16 | PG17+ |
|---|---|
| `max_dead_tuples`, `num_dead_tuples` | `max_dead_tuple_bytes`, `dead_tuple_bytes`, `num_dead_item_ids` (TID store) |

### `pg_replication_slots` — fourth branch (`1b`)

| PG16 | PG17+ |
|---|---|
| `conflicting` (PG16 new) | adds `inactive_since`, `invalidation_reason` |

### Other PG17 additions used without a branch

- `huge_pages_status` GUC — read via `pg_settings` in `8b`, no row on PG16.

## PG18 differences (verified against postgresql.org/docs/18)

| Object | Change | Marvin |
|---|---|---|
| `pg_stat_io` | `op_bytes` **removed**; `read_bytes` / `write_bytes` / `extend_bytes` added; new rows with `object = 'wal'` | `5i` filters `object <> 'wal'` so the ranking is stable across majors; `5i2 [PG18]` reads the WAL rows and byte columns |
| `pg_stat_wal` | `wal_write`, `wal_sync`, `wal_write_time`, `wal_sync_time` **removed** | `5b3` selects only surviving columns (`wal_records`, `wal_fpi`, `wal_bytes`, `wal_buffers_full`) |
| `pg_stat_all_tables` | `total_vacuum_time`, `total_autovacuum_time`, `total_analyze_time`, `total_autoanalyze_time` (ms) | `3f [PG18]` |
| `pg_stat_checkpointer` | `num_done`, `slru_written` | mentioned in `5k [PG17+]` header; select by hand |
| `pg_stat_database` | `parallel_workers_to_launch`, `parallel_workers_launched` | not yet used |
| `pg_stat_statements` | `parallel_workers_to_launch`, `parallel_workers_launched`, `wal_buffers_full` (extension 1.12 — needs `ALTER EXTENSION ... UPDATE`, see `8j`) | not yet used |
| `pg_stat_statements` queryid | IN-list constants collapsed; same-name relations across schemas grouped; 18.2 minor also changed GROUP BY jumbling | never compare `queryid` across majors or across 18.1 → 18.2 |
| `pg_stat_progress_vacuum` / `_analyze` | `delay_time` (ms in cost delay; 0 unless `track_cost_delay_timing = on`, default off) | noted in `3c-progress [PG17+]` header |
| `pg_stat_subscription_stats` | `confl_insert_exists`, `confl_update_origin_differs`, `confl_update_exists`, `confl_update_missing`, `confl_delete_origin_differs`, `confl_delete_missing`, `confl_multiple_unique_conflicts` | `7e [PG18]` |
| GUC `autovacuum_vacuum_max_threshold` | new, default 100 M, -1 disables; caps `threshold + scale × reltuples` | `3b2` applies the cap; `0-key-settings` / `8b` read it |
| GUC `autovacuum_worker_slots` | new, default 16; `autovacuum_max_workers` becomes reloadable up to it | `3c-capacity` |
| GUCs `vacuum_max_eager_freeze_failure_rate` (0.03), `vacuum_truncate` (true), `track_cost_delay_timing` (off) | new | `8b` reads `track_cost_delay_timing` |
| GUCs `io_method` (default `worker`), `io_workers` (3), `io_max_combine_limit` | new (AIO) | `0-key-settings` / `8b` report `io_method`, `io_workers` |
| `effective_io_concurrency`, `maintenance_io_concurrency` | default 1 → 16 | `8b` rule: explicit `= 1` on PG18 is stale tuning |
| GUC `idle_replication_slot_timeout` | new, default 0 (off) | `7f`; recommended in slot-bloat advice |
| initdb | data checksums default **on** | `8e` reads `data_checksums`, `checksum_failures` |
| `EXPLAIN ANALYZE` | `BUFFERS` included by default; fractional row estimates; `Index Searches: N` | advice text only |
| B-tree skip scan | `(a, b)` usable without a predicate on `a` when `a` is low-cardinality | does not change `6c`; see interpretation-thresholds |
| `VACUUM` / `ANALYZE` | recurse into partitions by default; `ONLY` opts out | `3e` remediation text |
| `pg_stat_replication` | no column changes; 18.1 / 18.4 minors fixed `write_lag` / `flush_lag` stalls | `7a` |

Not verified on a live PG16 or PG17 this cycle: the `[PG16]` variants were carried forward unchanged. Verified live on PG 18.4: every other block in `00`–`08`.

### PG16+ features marvin relies on

- `pg_stat_io` — per-backend-type, per-context I/O attribution (`backend_type`, `object`, `context`, `reads`, `writes`, `extends`, `hits`, `evictions`, `fsyncs`).
- `pg_stat_user_tables` / `pg_stat_user_indexes`: `last_seq_scan`, `last_idx_scan` (timestamps survive stats resets).
- `pg_stat_user_tables.n_tup_newpage_upd` — distinguishes updates placed on a new page from cold updates.

## Pre-PG16

Not supported. Pin marvin to a pre-`PG16+ floor` tag if you still operate PG12–15.

# PG version matrix

Marvin requires **PG16+** and is verified through **PG18**. PG19 is not targeted. Headline signals (`pg_stat_io`, `last_seq_scan` / `last_idx_scan`, `n_tup_newpage_upd`, `total_plan_time`, `wal_bytes`) all need PG16.

`0-version` returns `pg16_plus` (abort if false), `pg17_plus`, `pg18_plus`, `is_replica`.

## Which blocks branch

| Flag | Blocks |
|---|---|
| `pg17_plus` | `1b`, `5b`, `5k`, `3c-progress` — each ships `[PG16]` and `[PG17+]` |
| `pg18_plus` | run additionally: `3f [PG18]`, `5i2 [PG18]`, `7e [PG18]` |
| none | everything else — version-specific GUCs are read through `pg_settings` (`0-settings`) and return no row on older majors |

## PG17 vs PG16

| Object | PG16 | PG17 | Block |
|---|---|---|---|
| `pg_stat_statements` I/O time | `blk_read_time` / `blk_write_time` | `shared_blk_*_time`, `local_blk_*_time`, `temp_blk_*_time`; adds `stats_since`, `minmax_stats_since` | `5b` |
| checkpoint counters | `pg_stat_bgwriter.checkpoints_timed` / `checkpoints_req` / `checkpoint_write_time` / `checkpoint_sync_time` / `buffers_checkpoint` | `pg_stat_checkpointer.num_timed` / `num_requested` / `write_time` / `sync_time` / `buffers_written` + `restartpoints_*` | `5k` |
| `pg_stat_progress_vacuum` | `max_dead_tuples`, `num_dead_tuples` | `max_dead_tuple_bytes`, `dead_tuple_bytes`, `num_dead_item_ids` | `3c-progress` |
| `pg_replication_slots` | `conflicting` | adds `inactive_since`, `invalidation_reason` | `1b` |
| `huge_pages_status` GUC | — | new | `0-settings` |

## PG18 (verified against postgresql.org/docs/18)

| Object | Change | Block |
|---|---|---|
| `pg_stat_io` | `op_bytes` removed; `read_bytes` / `write_bytes` / `extend_bytes` added; rows with `object = 'wal'` | `5i` excludes WAL; `5i2 [PG18]` reads it |
| `pg_stat_wal` | `wal_write`, `wal_sync`, `wal_write_time`, `wal_sync_time` removed | `5b3` selects survivors only |
| `pg_stat_all_tables` | `total_vacuum_time`, `total_autovacuum_time`, `total_analyze_time`, `total_autoanalyze_time` (ms) | `3f [PG18]` |
| `pg_stat_checkpointer` | `num_done`, `slru_written` | `5k [PG17+]` header; select by hand |
| `pg_stat_progress_vacuum` / `_analyze` | `delay_time` (0 unless `track_cost_delay_timing = on`) | `3c-progress [PG17+]` header |
| `pg_stat_subscription_stats` | `confl_*` counters | `7e [PG18]` |
| `pg_stat_statements` queryid | IN-list constants collapsed; same-name relations across schemas grouped; 18.2 changed GROUP BY jumbling | never compare `queryid` across majors or 18.1 → 18.2 |
| `pg_stat_statements` 1.12 | `parallel_workers_*`, `wal_buffers_full` (needs `ALTER EXTENSION ... UPDATE`) | `0-extensions` `outdated` |
| GUC `autovacuum_vacuum_max_threshold` | default 100 M, -1 disables; caps `threshold + scale × reltuples` | `3b` applies the cap |
| GUC `autovacuum_worker_slots` | default 16; `autovacuum_max_workers` reloadable up to it | `3c-capacity` |
| GUCs `io_method` (`worker`), `io_workers` (3), `io_combine_limit`, `track_cost_delay_timing` | new | `0-settings` |
| `effective_io_concurrency`, `maintenance_io_concurrency` | default 1 → 16 | `0-settings` severity on explicit `= 1` |
| GUC `idle_replication_slot_timeout` | default 0 (off) | `0-settings`; `1b [PG17+]` advice |
| initdb | data checksums default on | `0-settings`, `8c` `checksum_failures` |
| B-tree skip scan | `(a, b)` usable without a predicate on `a` | does not change `6c` |
| `VACUUM` / `ANALYZE` | recurse into partitions by default; `ONLY` opts out | `3e` remediation text |

Verified live on PG 18.4: every block except the `[PG16]` variants, which were carried forward unchanged.

## Pre-PG16

Not supported. Pin marvin to a pre-`PG16+ floor` tag for PG12–15.

# PostgreSQL Version Compatibility Matrix

This skill targets PG 12 through 17. Several catalogs and column names changed in ways that silently break audit queries written for the wrong version. Branch on `current_setting('server_version_num')::int` (e.g., `>= 130000` for PG13+) before running anything version-sensitive.

## Quick version detection

```sql
SELECT
  current_setting('server_version') AS version_str,
  current_setting('server_version_num')::int AS version_num,
  CASE
    WHEN current_setting('server_version_num')::int >= 170000 THEN 17
    WHEN current_setting('server_version_num')::int >= 160000 THEN 16
    WHEN current_setting('server_version_num')::int >= 150000 THEN 15
    WHEN current_setting('server_version_num')::int >= 140000 THEN 14
    WHEN current_setting('server_version_num')::int >= 130000 THEN 13
    WHEN current_setting('server_version_num')::int >= 120000 THEN 12
    ELSE -1
  END AS major;
```

## Major changes by area

### `pg_stat_statements`

| Version | Change |
|---|---|
| PG13 | `total_time` → `total_exec_time`; new `total_plan_time`, `mean_plan_time`, `min_plan_time`, `max_plan_time`, `stddev_plan_time`. `min_time` → `min_exec_time`, etc. The old column names are GONE, not renamed-and-aliased. |
| PG13 | `queryid` is now stable across server restarts (when `compute_query_id = on`). |
| PG14 | Added `toplevel` column to distinguish top-level vs nested statements. |
| PG14 | `compute_query_id = auto` is the new default; `pg_stat_statements` enables it automatically when loaded. |
| PG15 | Added JIT timing columns: `jit_functions`, `jit_generation_time`, `jit_inlining_count`, etc. |
| PG17 | Added `stats_since` and `minmax_stats_since` for tracking when stats began accumulating per statement. |

**Audit query branch:**

```sql
-- Detect once
SELECT EXISTS(
  SELECT 1 FROM information_schema.columns
  WHERE table_schema='public' AND table_name='pg_stat_statements' AND column_name='total_exec_time'
) AS is_pg13_plus;
```

### Replication views

| Version | Change |
|---|---|
| PG10 | `pg_stat_replication` got `write_lag`, `flush_lag`, `replay_lag` interval columns (in addition to LSN-based lag). |
| PG13 | `pg_replication_slots` got `wal_status` (`reserved` / `extended` / `unreserved` / `lost`) and `safe_wal_size`. Use these instead of computing from `restart_lsn`. |
| PG14 | `pg_stat_replication_slots` added — per-slot statistics on logical decoding work. |

### `pg_stat_wal` (PG14+)

Entirely new in PG14. Tracks WAL volume, buffer-full counts, and WAL write/sync timing. Replaces ad-hoc analysis from logs.

```sql
SELECT * FROM pg_stat_wal;       -- PG14+: wal_records, wal_buffers_full, wal_write_time, wal_sync_time
```

PG17 extended it with `wal_buffers_full` semantics improvements and additional reset tracking.

### `pg_stat_io` (PG16+)

This is a major change — *finally* per-backend-type, per-context I/O attribution. Use it instead of `pg_statio_user_tables` whenever available (PG16+).

```sql
-- PG16+ only
SELECT backend_type, object, context, reads, writes, extends, hits, evictions
FROM pg_stat_io;
```

`backend_type` includes `client backend`, `autovacuum worker`, `checkpointer`, `background worker`, `walwriter`, etc. `context` includes `normal`, `vacuum`, `bulkread`, `bulkwrite`. This finally lets you say "checkpoint I/O is dominant" or "autovacuum is doing 80% of disk reads" with evidence.

### Checkpointer (PG17+)

PG17 split the checkpointer's stats out of `pg_stat_bgwriter` into its own `pg_stat_checkpointer` view.

| Version | Source |
|---|---|
| ≤ PG16 | `pg_stat_bgwriter` includes both bgwriter and checkpointer |
| PG17+ | `pg_stat_checkpointer` (checkpointer-only); `pg_stat_bgwriter` is bgwriter-only |

```sql
-- PG17+
SELECT num_timed, num_requested, write_time, sync_time, buffers_written, slru_written
FROM pg_stat_checkpointer;

-- PG16-
SELECT checkpoints_timed, checkpoints_req, checkpoint_write_time, checkpoint_sync_time,
       buffers_checkpoint, buffers_clean, maxwritten_clean, buffers_backend, buffers_alloc
FROM pg_stat_bgwriter;
```

### Autovacuum

| Version | Change |
|---|---|
| PG13 | `autovacuum_vacuum_insert_threshold` and `autovacuum_vacuum_insert_scale_factor` — autovacuum now triggers on inserts (previously only on updates/deletes). Insert-heavy tables that never UPDATE/DELETE will get vacuumed and ANALYZEd appropriately. |
| PG14 | Added `vacuum_failsafe_age` — emergency mode when wraparound is critical. |
| PG14 | `autovacuum_work_mem` separated from `maintenance_work_mem`. |
| PG16 | Logical replication can use parallel apply (relevant for replication lag analysis). |

### `pg_stat_user_tables` / `pg_stat_user_indexes`

Stable across PG12–17 in the columns we use. PG16 added `last_seq_scan` and `last_idx_scan` timestamps to `pg_stat_user_tables` — much better than just `seq_scan` / `idx_scan` counters when stats reset infrequently.

```sql
-- PG16+: when was this index last actually used?
SELECT schemaname, relname, indexrelname, idx_scan, last_idx_scan
FROM pg_stat_user_indexes WHERE last_idx_scan IS NOT NULL
ORDER BY last_idx_scan DESC;
```

This is *the* fix for the "stats reset 3 days ago, my unused-index query is now broken" problem — but only on PG16+.

### Other gotchas

- **`pg_relation_filenode()` and `pg_filenode_relation()`** — useful for OS-level investigations, behavior unchanged but worth knowing.
- **`pg_stat_progress_vacuum`** — exists since PG9.6 but easy to forget. Use during a manual VACUUM to see phase-by-phase progress.
- **`pg_stat_progress_create_index`** — PG12+. Same idea for `CREATE INDEX (CONCURRENTLY)`.
- **Generated columns** (PG12+) and **MERGE** (PG15+) appear in `pg_stat_statements` but query text fingerprinting was reworked in PG14; old `queryid` values aren't comparable across major upgrades.
- **TOAST compression algorithms** — PG14 added LZ4 (`default_toast_compression`), PG16 added per-table `toast_compression`. If a TOAST-heavy table is on PGLZ, switching to LZ4 typically halves write time and improves compression ratio.

## Pre-flight version detection in this skill

Run this once at the start of Phase 0:

```sql
SELECT
  current_setting('server_version_num')::int AS pg_ver,
  current_setting('server_version_num')::int >= 130000 AS pg13_plus,
  current_setting('server_version_num')::int >= 140000 AS pg14_plus,
  current_setting('server_version_num')::int >= 150000 AS pg15_plus,
  current_setting('server_version_num')::int >= 160000 AS pg16_plus,
  current_setting('server_version_num')::int >= 170000 AS pg17_plus;
```

Then within the audit logic:

- `pg13_plus` controls the `pg_stat_statements` column choice.
- `pg14_plus` enables `pg_stat_wal` and `pg_stat_replication_slots` queries.
- `pg16_plus` enables `pg_stat_io` and `last_idx_scan`/`last_seq_scan`.
- `pg17_plus` switches to `pg_stat_checkpointer`.

For older versions (pre-PG12), this skill's queries will mostly still work but several features are unavailable. Don't run it against PG10/11 without flagging the user — the bloat queries above target PG12 reltuples behavior.

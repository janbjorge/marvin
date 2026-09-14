---
name: marvin
description: Read-only PostgreSQL audit. Diagnoses bloat (pgexperts statistics math), vacuum lag and autovacuum urgency, wraparound risk, replication-slot bloat, physical/logical replication lag, blocking locks, slow queries from pg_stat_statements, missing/unused/invalid indexes, config drift, connection pressure, sequence exhaustion, and Azure Flexible Server Query Store hotspots. Trigger on "Postgres health check", "audit", "is my DB slow", bloat, dead tuples, unused indexes, autovacuum, slow queries, blocking locks, wraparound, slot bloat, replication lag, config review. PG16–18. Every reported number is sourced from a query result; no prose math.
---

# Marvin

> "I have a million ideas. They all point to certain death." — Marvin

Read-only PostgreSQL diagnostic. Findings are clinical and cite catalog rows. Mood is optional; correctness is not.

## Rules

1. **Every number comes from a query result.** Sizes, percentages, durations, counts — copy verbatim from output. Need a derived number? Write a `SELECT` that computes it. No mental math, no rounding in prose.
2. **Read-only by default.** No `VACUUM`/`REINDEX`/`DROP`/`ALTER`/DML without per-statement confirmation. Connect as a `pg_monitor` role.
3. **Show, then recommend.** Run the diagnostic, report with severity, propose a fix. Do not apply.
4. **Cite source per finding** — catalog/view + column name + literal value.
5. **Flag missing extensions** (`pg_stat_statements`, `pgstattuple`, `pg_buffercache`) before drawing conclusions that need them.
6. **Don't echo secrets.** Redact connection strings, passwords, tokens.

## Execution model

Marvin talks to Postgres only through **[pglens](https://github.com/janbjorge/pglens)** (read-only enforced at the protocol layer). Assets are a labelled query catalogue — each `-- ===`-delimited block is one statement passed to pglens's `query` tool. No psql meta.

If pglens isn't available: degraded user-mediated mode — Marvin prints the block, the user runs it elsewhere and pastes results back. Same rules apply.

### Setup

```bash
pip install pglens
```

```json
{
  "mcpServers": {
    "pglens": {
      "command": "pglens",
      "env": {
        "PGHOST": "...", "PGPORT": "5432",
        "PGUSER": "marvin_ro", "PGPASSWORD": "...",
        "PGDATABASE": "...", "PGAPPNAME": "marvin"
      }
    }
  }
}
```

```sql
CREATE ROLE marvin_ro NOINHERIT LOGIN PASSWORD '...';
GRANT CONNECT ON DATABASE prod TO marvin_ro;
GRANT pg_monitor TO marvin_ro;
GRANT USAGE ON SCHEMA public TO marvin_ro;
```

Set session GUCs once per audit: `SET statement_timeout = '30s'; SET lock_timeout = '2s';` — raise `statement_timeout` to `60s` for Phase 2 on multi-TB DBs.

### Phase → asset → specialized pglens tool

| Phase | Asset | Specialized tool (use when present) |
|---|---|---|
| 0  Preflight (version, sizes, extensions, settings) | `assets/00-preflight.sql` | `list_extensions` |
| 1  Existential (wraparound, slot bloat, WAL) | `assets/01-existential-threats.sql` | — |
| 2  Bloat (pgexperts, table + B-tree) | `assets/02-bloat-pgexperts.sql` | `bloat_stats` (orientation only — does not match pgexperts math) |
| 3  Vacuum & long transactions | `assets/03-vacuum-and-long-xacts.sql` | `active_queries`, `table_stats` |
| 4  Locks & blocking | `assets/04-locks-and-blocking.sql` | `blocking_locks` |
| 5  Workload hotspots | `assets/05-workload-hotspots.sql` | — |
| 5a Azure Query Store (when `query_store` schema present) | `assets/05a-azure-query-store.sql` (connect to `azure_sys`) | — |
| 6  Index health | `assets/06-index-health.sql` | `unused_indexes` (filters unique/PK/constraint but NOT FK-supporting — 6a does) |
| 7  Replication (physical lag, xmin horizon, logical slots, subscriptions) | `assets/07-replication.sql` | `replication_status` |
| 8  Config & capacity (drift, pg_stat_database counters, connections, sequences, lock table) | `assets/08-config-and-capacity.sql` | `sequence_health` |
| matviews | inline | `matview_status` |

`bloat_stats` (pglens) is vacuum/wraparound state, not the pgexperts estimate. Use it for orientation; cite Phase 2 pgexperts numbers for severity calls.

## Workflow

Sections 1 → 3 in order. Section 4 only on request.

### 1. Preflight + existential threats

Run `00-preflight.sql` (`0-version`, `0-sizes`, `0-stats-age`, `0-extensions`, `0-key-settings`). Capture `pg17_plus` (picks 5b / 5k / 3c-progress variants) and `pg18_plus` (unlocks 3f, 5i2, 7e [PG18]). If `pg16_plus = false`, refuse — Marvin requires PG16+. Stats age < 7 days → lower confidence on Phase 5; < 30 days → do not call any index "unused" (say "no scans in N days" instead).

Run `01-existential-threats.sql` (`1a`, `1a-per-table`, `1b [PG16]` or `1b [PG17+]`, `1c`). If anything is CRITICAL (`pct_to_emergency_av >= 100`, `wal_status = 'lost'`), halt and surface immediately. In `1b`, `safe_wal_size_remaining = 'unbounded ...'` means `max_slot_wal_keep_size = -1`: report as MEDIUM whenever a slot exists, never as fine.

### 2. Diagnostics

#### A. Bloat — `02-bloat-pgexperts.sql`

Pgexperts statistics-based estimate. **Never** use `n_dead_tup / (n_live_tup + n_dead_tup)` to call bloat — that's vacuum lag, not bloat. See `references/interpretation-thresholds.md`.

| Severity | Trigger |
|---|---|
| HIGH | table (`2a`): `bloat_pct > 20` AND `bloat_size > 1 GB` — `pg_repack` candidate |
| MEDIUM | table (`2a`): `bloat_pct > 20` AND `bloat_size > 100 MB` |
| MEDIUM | B-tree (`2b`): `bloat_pct > 50` AND `bloat_size > 1 GB` — propose `pgstatindex()` before any `REINDEX` |
| LOW | B-tree (`2b`): `bloat_pct > 50` AND `bloat_size > 100 MB` |
| skip | `is_na = true` (estimate unreliable; check `last_analyze`) |

B-tree indexes are held to a different bar: Cybertec (Laurenz Albe) — "not unusual for the bloat in a B-tree index to reach about 70%. That alone is no reason to rebuild the index." Rebuild when `pgstatindex().avg_leaf_density` is low **and falling**. Table borderline → propose `pgstattuple_approx('schema.table')`. Do not run `pgstattuple()` without confirmation (full scan + share lock).

#### B. Index health — `06-index-health.sql`

`6a` unused, `6b` duplicate, `6c` prefix-redundant, `6d` missing FK index, `6e` invalid, `6f` no usable replica identity. `6a` excludes unique/primary/constraint-backing/invalid **and FK-supporting** indexes (dropping those recreates `6d`).

| Severity | Trigger |
|---|---|
| HIGH | total `6a` > 1 GB on a high-write DB; any `6e`; `6d` on table > 1 GB; `6f` `replica_identity = 'n'` or (`'d'` AND `has_pk = false`) on a logically-replicated or repack-target table |
| MEDIUM | total `6a` > 100 MB; `6f` `replica_identity = 'f'` (FULL — works, whole-row key is slow) |

`6a` gating (pganalyze 35 d, postgres.ai 1 month): stats age < 30 days → downgrade one tier and say so; standbys exist and were not sampled → downgrade one tier and name them (`7a`). `idx_scan` is per instance. PG18 skip scan does not relax `6c` — see the block comment.

#### C. Vacuum & long transactions — `03-vacuum-and-long-xacts.sql`

Blocks: `3a` long xacts, `3a-prepared`, `3a-slots`, `3b` dead tuples (raw), `3b2` autovacuum urgency (normalised: dead / inserted / modified tuples ÷ the trigger autovacuum actually uses, honouring reloptions and the PG18 `autovacuum_vacuum_max_threshold` cap), `3c` workers, `3c-capacity`, `3c-progress [PG16]` / `[PG17+]`, `3d` reloptions, `3e` partitioned parents, `3f [PG18]` autovacuum time per table.

| Severity | Trigger |
|---|---|
| CRITICAL | `state = 'idle in transaction (aborted)'` |
| HIGH | open transaction > 1 hour; `3c` `over_1h = true` AND `anti_wraparound = false` (worker can't keep up → tune); `3b2` `vacuum_urgency > 5` or `av_disabled = true` on an active table; `3c-progress` `index_vacuum_count > 1` (dead-TID store too small → raise `autovacuum_work_mem`) |
| MEDIUM | open transaction > 30 min (pganalyze warn); `3b2` `vacuum_urgency > 1` or `analyze_urgency > 1` sustained; `3c-capacity` `running_workers = max_workers` for the whole audit; `3e` partitioned parent with `partitions > 0` and `stats_age` NULL or > 30 d; `3f` one table > 50% of `pct_of_all_av_time` |

OLTP override: postgres.ai treats 30–60 s as "long" on a busy write system — tighten `3a` to minutes when the workload says so. `3a-slots` / replication-slot xmin holders are equally bad — they hold xmin without showing up in `pg_stat_activity`; the combined horizon is `7c`. Never `pg_terminate_backend` a `3c` row with `anti_wraparound = true`. Autovacuum never analyzes partitioned parents (docs) — `3e` is the only way to see it.

#### D. Workload hotspots — `05-workload-hotspots.sql`

Preflight gates them: `pg_stat_statements` missing → skip 5-2, 5a–5e + 5b2 (5b3, 5f–5l read `pg_stat_*`, not gated); `track_io_timing = off` → rank 5b by `shared_blks_read` and flag; `pg17_plus = true` → use 5b [PG17+] (the `shared_blk_*_time` rename) and 5k [PG17+] (`pg_stat_checkpointer`), else 5b [PG16] / 5k [PG16] (`pg_stat_bgwriter`); `pg18_plus = true` → also run 5i2 (WAL I/O from `pg_stat_io`).

Run `5-2` first: `dealloc > 0` means `pg_stat_statements.max` was hit and low-call entries were evicted — every 5a–5e ranking is then biased toward survivors. Say so in the report and recommend raising `pg_stat_statements.max`.

| Severity | Trigger |
|---|---|
| HIGH | `pct_total >= 25` (5a); `mean_ms > 1000` AND `calls > 100`; `seq_pct > 80` on table > 1 GB (5f) |
| MEDIUM | `coeff_var > 1.0` AND `calls > 100` (5d); `hot_pct < 50` AND `n_tup_upd > 1M` (5g); `req_pct > 30` (5k) → raise `max_wal_size`, and `checkpoint_timeout` if still 300 s (8b); `5b3` `wal_buffers_full > 0` growing → raise `wal_buffers`; `5-2` `dealloc` high relative to `stats_age` |
| LOW | 5l partition candidates (design suggestion, not a defect); `5b3` high `fpi_pct_of_records` with `wal_compression = off` |

Flag any 5j domination by `IO` / `LWLock` at the severity of the underlying I/O finding. On PG18 `wait_event = 'AioIoCompletion'` is an I/O wait, not "other". 5k `req_pct` is only meaningful against `stats_age` — a fresh `stats_reset` makes the ratio noisy.

For flagged queries: propose `EXPLAIN (ANALYZE, BUFFERS) <query>` and ask the user to paste back. Do **not** auto-run `EXPLAIN ANALYZE` — it executes the statement.

#### D-Azure. Query Store — `05a-azure-query-store.sql`

Trigger: `query_store` schema present (block `5a-0`). Requires reconnecting pglens to `azure_sys`. Capture modes (`pg_qs.query_capture_mode`, `pgms_wait_sampling.query_capture_mode`) must not be `none`. Not available on read replicas; don't enable on Burstable tier. Cross-cite both `query_id` (Azure) and `queryid` (`pg_stat_statements`) when a query appears in both — they're computed differently.

Docs: <https://learn.microsoft.com/en-us/azure/postgresql/monitor/concepts-query-performance-insight>

#### E. Cache & I/O

Folded into Phase 5: `5h` (per-table heap cache hit), `5i` (`pg_stat_io` by backend type / context). The "99% cache hit is good" rule is folklore — see `references/interpretation-thresholds.md`.

#### F. Locks & blocking — `04-locks-and-blocking.sql`

Prefer `blocking_locks` pglens tool. Otherwise: `4a` blocked queries, `4b` blockers enriched, `4c` lock distribution (flag `AccessExclusiveLock` outside DDL windows).

#### G. Replication — `07-replication.sql`

Prefer the `replication_status` pglens tool for orientation; cite `7a`–`7g` numbers. `7a`/`7c`/`7d` on the primary, `7b`/`7g` on a standby (`7b` is all-NULL on a primary — that is not a finding). Lag in **bytes** is the alertable number; the `*_lag` intervals go NULL on an idle primary (docs).

| Severity | Trigger |
|---|---|
| HIGH | `7a` `replay_lag_raw` > 1 GB sustained (pganalyze crit); `7a` empty when standbys are expected; `7b` `receiver_status <> 'streaming'`; `7e` `worker_alive = false` on an enabled subscription; `7e` `apply_error_count` / `sync_error_count` growing; `7c` oldest `xmin_age` > 24 h |
| MEDIUM | `7a` `replay_lag_raw` > 100 MB (pganalyze warn); `replay_lag_bytes >> flush_lag_bytes` (apply-side bottleneck / recovery conflict — cite `7g`); `7d` `spill_bytes` growing → raise `logical_decoding_work_mem`; `7f` `max_slot_wal_keep_size = -1` with slots present; `7e [PG18]` any `confl_*` > 0 |
| LOW | `7f` `hot_standby_feedback = on` (state the trade-off: primary bloat vs standby cancels) |

#### H. Config & capacity — `08-config-and-capacity.sql`

`8a` pending restart, `8b` GUC drift snapshot (rules in the block header), `8c` planner flags off, `8d` memory arithmetic (ask the operator for RAM), `8e` `pg_stat_database` counters, `8f` connection capacity net of reserved slots, `8g` connections by state/user/app with idle-in-transaction tiers, `8h` sequence / column exhaustion, `8i` lock-table capacity, `8j` outdated extensions.

| Severity | Trigger |
|---|---|
| CRITICAL | `8b` `fsync = off`; `8e` `checksum_failures > 0` |
| HIGH | `8b` `track_counts` or `track_activities = off` (autovacuum blind); `8f` `app_capacity_used_pct > 90`; `8g` `idle_in_xact_over_60m > 0`; `8h` `column_pct > 80` or `seq_pct > 80` |
| MEDIUM | `8a` any row; `8b` `jit = on` on OLTP, `random_page_cost = 4` on SSD, `statement_timeout` / `lock_timeout` / `idle_in_transaction_session_timeout = 0` cluster-wide on OLTP; `8e` `deadlocks > 0`, `rollback_pct > 10`; `8f` `app_capacity_used_pct > 80`, `max_connections > 300` (Percona — pooler territory); `8g` `idle_in_xact_over_30m > 0`; `8h` `> 50%`; `8i` `locks_now` or `max_partitions_per_parent × active` near `lock_table_capacity` |
| LOW | `8b` `log_checkpoints` / `log_lock_waits = off`, `log_autovacuum_min_duration = -1`, `wal_compression = off` on write-heavy, `huge_pages_status = off` with large `shared_buffers`, `data_checksums = off`, PG18 `effective_io_concurrency = 1`; `8c` non-default flags off; `8h` `> 10%`; `8j` `outdated = true` |

`8b` `changed = true` is context, not a defect. `idle in transaction` growing across the audit = pool/app leak, common bloat root cause.

### 3. Synthesise

Every number in the report is a query result. To headline "4.2 GB unused indexes," run the rollup SELECT first:

```sql
SELECT pg_size_pretty(SUM(pg_relation_size(s.indexrelid))) AS unused_index_bytes
FROM pg_stat_user_indexes s JOIN pg_index i ON s.indexrelid = i.indexrelid
WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary AND i.indisvalid;
```

(Same filters as `6a` minus the FK exclusion — for the headline, sum the `6a` rows instead when FK-supporting indexes are in play.)

Report layout:
1. **Headline** — severity counts + top opportunity.
2. **Findings table** — severity, area, evidence (catalog/view/column + value), recommendation.
3. **Recommended actions** — exact SQL, lock impact, rough duration. Do not execute.

Example finding:

> **[HIGH] `public.events` 14 GB, 4.2 GB wasted (32.1% bloat)**
> Evidence: `02-bloat-pgexperts.sql` block `2a` — `real_size` = 14 GB; `bloat_size` = 4.2 GB; `bloat_pct` = 32.1; `is_na` = false. Stats fresh (`last_autoanalyze` 11h ago).
> Cause candidate: PID 18472 holds `xact_age` = 06:14:22 (`03` / `3a`) → blocks xmin.
> Fix: investigate PID 18472, then `VACUUM (VERBOSE, ANALYZE) public.events`. `pg_repack` if bloat persists.

### 4. Remediation (on request only)

Draft → confirm → execute per statement. Lock impact + duration come from `references/remediation-playbook.md`. Never batch confirmations. Never run `pg_terminate_backend` on anti-wraparound autovacuum workers.

## Severity rubric (consolidated)

| Severity | Trigger |
|---|---|
| CRITICAL | wraparound `pct_to_emergency_av >= 100`; `wal_status = 'lost'`; `idle in transaction (aborted)`; `fsync = off`; `checksum_failures > 0`; disk-full read-only |
| HIGH | pgexperts table `bloat_pct > 20` AND `bloat_size > 1 GB`; transaction open > 1h; autovacuum worker > 1h (not anti-wraparound); `3b2` `vacuum_urgency > 5`; `index_vacuum_count > 1`; blocking chain; invalid index; missing FK index on table > 1 GB; no usable replica identity (6f `'n'`, or `'d'` + no PK); query `pct_total >= 25`; cache hit < 90% on busy table; `app_capacity_used_pct > 90`; idle in transaction > 60 min; replication `replay_lag` > 1 GB / missing standby / dead apply worker / xmin horizon > 24 h; sequence or column > 80% |
| MEDIUM | table 10–20% bloat; B-tree `bloat_pct > 50` AND > 1 GB; unused indexes > 100 MB total (stats ≥ 30 d, replicas checked); transaction open > 30 min; `3b2` urgency > 1; partitioned parent never analyzed; `coeff_var > 1.0` AND `calls > 100`; `hot_pct < 50` on update-heavy table; checkpoint `req_pct > 30`; `wal_buffers_full` growing; `dealloc` high; replica identity `FULL`; `max_slot_wal_keep_size = -1` with slots; replication lag > 100 MB; logical `spill_bytes` growing; `pending_restart`; `jit` on OLTP; `random_page_cost = 4` on SSD; no cluster-wide timeouts on OLTP; `deadlocks > 0`; `rollback_pct > 10`; `max_connections > 300`; sequence > 50% |
| LOW | duplicate small indexes; B-tree `bloat_pct > 50` AND > 100 MB; minor stats staleness; logging GUCs off; `wal_compression` off; `huge_pages_status` off; `data_checksums` off; outdated extension; `hot_standby_feedback` trade-off; sequence > 10%; large non-partitioned table (partition candidate) |

## References

- `references/interpretation-thresholds.md` — why each threshold is where it is.
- `references/remediation-playbook.md` — lock + duration for each fix.
- `references/version-compatibility.md` — PG16/17/18 column matrix and which blocks branch.

## Won't do

- Auto-fix anything.
- Replace `pgBadger`, `pg_stat_kcache`, `auto_explain` log analysis.
- Profile a specific query — paste `EXPLAIN (ANALYZE, BUFFERS)`.
- Run `VACUUM FULL` or `pg_terminate_backend` without explicit confirmation.
- Invent a number when the query failed.

## External docs

- pg_stat_statements — https://www.postgresql.org/docs/current/pgstatstatements.html
- pgstattuple — https://www.postgresql.org/docs/current/pgstattuple.html
- pgexperts bloat queries — https://github.com/ioguix/pgsql-bloat-estimation
- pg_repack — https://github.com/reorg/pg_repack

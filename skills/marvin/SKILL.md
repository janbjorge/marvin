---
name: marvin
description: Read-only PostgreSQL audit. Diagnoses bloat (pgexperts statistics math), vacuum lag, wraparound risk, replication-slot bloat, blocking locks, slow queries from pg_stat_statements, missing/unused/invalid indexes, and Azure Flexible Server Query Store hotspots. Trigger on "Postgres health check", "audit", "is my DB slow", bloat, dead tuples, unused indexes, autovacuum, slow queries, blocking locks, wraparound, slot bloat. PG16+ only. Every reported number is sourced from a query result; no prose math.
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
| 6  Index health | `assets/06-index-health.sql` | `unused_indexes` (already filters unique/PK/constraint) |
| sequences, matviews | inline | `sequence_health`, `matview_status` |

`bloat_stats` (pglens) is vacuum/wraparound state, not the pgexperts estimate. Use it for orientation; cite Phase 2 pgexperts numbers for severity calls.

## Workflow

Sections 1 → 3 in order. Section 4 only on request.

### 1. Preflight + existential threats

Run `00-preflight.sql` (`0-version`, `0-sizes`, `0-stats-age`, `0-extensions`, `0-key-settings`). Capture `pg17_plus` (drives the only remaining variant block, 5b). If `pg16_plus = false`, refuse — Marvin requires PG16+. If stats-reset age < 7 days, lower confidence on Phase 5 and 6.

Run `01-existential-threats.sql` (`1a`, `1a-per-table`, `1b`, `1c`). If anything is CRITICAL (`pct_to_emergency_av >= 100`, `wal_status = 'lost'`), halt and surface immediately.

### 2. Diagnostics

#### A. Bloat — `02-bloat-pgexperts.sql`

Pgexperts statistics-based estimate. **Never** use `n_dead_tup / (n_live_tup + n_dead_tup)` to call bloat — that's vacuum lag, not bloat. See `references/interpretation-thresholds.md`.

| Severity | Trigger |
|---|---|
| HIGH | `bloat_pct > 20` AND `bloat_size > 1 GB` — `pg_repack` candidate |
| MEDIUM | `bloat_pct > 20` AND `bloat_size > 100 MB` |
| skip | `is_na = true` (estimate unreliable; check `last_analyze`) |

Borderline → propose `pgstattuple_approx('schema.table')`. Do not run `pgstattuple()` without confirmation (full scan + share lock).

#### B. Index health — `06-index-health.sql`

`6a` unused, `6b` duplicate, `6c` prefix-redundant, `6d` missing FK index, `6e` invalid. `6a` already excludes unique/primary/constraint-backing.

| Severity | Trigger |
|---|---|
| HIGH | total `6a` > 1 GB on a high-write DB; any `6e`; `6d` on table > 1 GB |
| MEDIUM | total `6a` > 100 MB |

#### C. Vacuum & long transactions — `03-vacuum-and-long-xacts.sql`

| Severity | Trigger |
|---|---|
| CRITICAL | `state = 'idle in transaction (aborted)'` |
| HIGH | open transaction > 1 hour |

`3a-slots` / replication-slot xmin holders are equally bad — they hold xmin without showing up in `pg_stat_activity`.

#### D. Workload hotspots — `05-workload-hotspots.sql`

Twelve blocks; preflight gates them: `pg_stat_statements` missing → skip 5a–5e + 5b2; `track_io_timing = off` → rank 5b by `shared_blks_read` and flag; `pg17_plus = true` → use 5b [PG17+] (the `shared_blk_*_time` rename), else 5b [PG16].

| Severity | Trigger |
|---|---|
| HIGH | `pct_total >= 25` (5a); `mean_ms > 1000` AND `calls > 100`; `seq_pct > 80` on table > 1 GB (5f) |
| MEDIUM | `coeff_var > 1.0` AND `calls > 100` (5d); `hot_pct < 50` AND `n_tup_upd > 1M` (5g) |

Flag any 5j domination by `IO` / `LWLock` at the severity of the underlying I/O finding.

For flagged queries: propose `EXPLAIN (ANALYZE, BUFFERS) <query>` and ask the user to paste back. Do **not** auto-run `EXPLAIN ANALYZE` — it executes the statement.

#### D-Azure. Query Store — `05a-azure-query-store.sql`

Trigger: `query_store` schema present (block `5a-0`). Requires reconnecting pglens to `azure_sys`. Capture modes (`pg_qs.query_capture_mode`, `pgms_wait_sampling.query_capture_mode`) must not be `none`. Not available on read replicas; don't enable on Burstable tier. Cross-cite both `query_id` (Azure) and `queryid` (`pg_stat_statements`) when a query appears in both — they're computed differently.

Docs: <https://learn.microsoft.com/en-us/azure/postgresql/monitor/concepts-query-performance-insight>

#### E. Cache & I/O

Folded into Phase 5: `5h` (per-table heap cache hit), `5i` (`pg_stat_io` by backend type / context). The "99% cache hit is good" rule is folklore — see `references/interpretation-thresholds.md`.

#### F. Locks & blocking — `04-locks-and-blocking.sql`

Prefer `blocking_locks` pglens tool. Otherwise: `4a` blocked queries, `4b` blockers enriched, `4c` lock distribution (flag `AccessExclusiveLock` outside DDL windows).

#### G. Connections & largest objects

```sql
SELECT count(*) FILTER (WHERE state = 'active')              AS active,
       count(*) FILTER (WHERE state = 'idle')                AS idle,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_xact,
       count(*) AS total,
       (SELECT setting::int FROM pg_settings WHERE name='max_connections') AS max_conn
FROM pg_stat_activity;
```

Flag: `idle in transaction > 5` (or growing) = pool/app leak, common bloat root cause.

### 3. Synthesise

Every number in the report is a query result. To headline "4.2 GB unused indexes," run the rollup SELECT first:

```sql
SELECT pg_size_pretty(SUM(pg_relation_size(s.indexrelid))) AS unused_index_bytes
FROM pg_stat_user_indexes s JOIN pg_index i ON s.indexrelid = i.indexrelid
WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary;
```

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
| CRITICAL | wraparound `pct_to_emergency_av >= 100`; `wal_status = 'lost'`; `idle in transaction (aborted)`; disk-full read-only |
| HIGH | pgexperts `bloat_pct > 20` AND `bloat_size > 1 GB`; transaction open > 1h; blocking chain; invalid index; missing FK index on table > 1 GB; query `pct_total >= 25`; cache hit < 90% on busy table; connections > 90% of `max_connections` |
| MEDIUM | 10–20% bloat; unused indexes > 100 MB total; `coeff_var > 1.0` AND `calls > 100`; `hot_pct < 50` on update-heavy table; no autovacuum in 7d on active table |
| LOW | duplicate small indexes; minor stats staleness; minor config drift |

## References

- `references/interpretation-thresholds.md` — why each threshold is where it is.
- `references/remediation-playbook.md` — lock + duration for each fix.
- `references/version-compatibility.md` — PG16/17 column matrix.

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

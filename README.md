# marvin

**Senior-DBA-grade PostgreSQL audits for LLMs. One Skill folder. Read-only. PG16+.**

marvin is a [Claude Skill](https://docs.claude.com/en/docs/claude-code/skills) that turns an MCP-capable agent into a thorough, opinionated, read-only Postgres reviewer. Every finding cites the catalog row that produced it. Bloat math is the [pgexperts statistics-based estimate](https://github.com/ioguix/pgsql-bloat-estimation), not the `n_dead_tup` ratio LLMs love to hallucinate. Wraparound-, replica-, and Azure-Flexible-Server-aware.

Talks to Postgres exclusively through **[pglens](https://github.com/janbjorge/pglens)** (read-only MCP).

```
User:  "Is my Postgres OK?"
Agent: → loads marvin
       → Phase 0: PG 17.8, primary, uptime 42d, stats reset 19d ago
       → Phase 1: relfrozenxid age = 87% of autovacuum_freeze_max_age  ← HIGH
       → Phase 2: orders 41% bloat / 12 GB reclaimable (pgexperts)     ← HIGH
       → Phase 5: 1 query = 38% of total_exec_time, 4 GB temp/day      ← HIGH
       → Phase 6: 7 unused indexes, 3.4 GB                              ← MEDIUM
       Findings ranked by severity, each with the catalog row that proves it.
```

## Install

Packaged as a Claude Code plugin. Install via the marketplace, or drop the skill directly.

```bash
# Claude Code
claude plugin marketplace add janbjorge/marvin
claude plugin install marvin-skills@marvin
```

```bash
# Or drop the folder
git clone https://github.com/janbjorge/marvin.git /tmp/marvin
cp -r /tmp/marvin/skills/marvin ~/.claude/skills/marvin
```

For Codex CLI or OpenCode, point your `AGENTS.md` / `opencode.jsonc` at `skills/marvin/SKILL.md`. It's a self-contained instruction file.

Trigger with *"Postgres health check"*, *"bloat audit"*, or *"why is my DB slow"*.

## How an agent uses it

```
1. 00-preflight                 → pg_ver, pg17_plus, pg18_plus, is_replica, stats age
2. abort if pg_ver < 160000
3. 01-existential-threats       → halt on wraparound / lost slot; 'unbounded' slot retention
4. 02-bloat-pgexperts           → table vs B-tree bloat severity from pgexperts numbers
5. 03-vacuum-and-long-xacts     → long xacts, autovacuum urgency (PG18 cap-aware), parents never analyzed
6. 04-locks-and-blocking
7. 05-workload-hotspots         → pg_stat_statements eviction check, then 5b/5k [PG16] vs [PG17+]
8. if azure_sys exists          → reconnect, run 05a-azure-query-store
9. 06-index-health              → unused (FK-aware) / duplicate / prefix-redundant / missing-FK / invalid
10. 07-replication              → lag bytes, xmin horizon, logical slots, subscriptions
11. 08-config-and-capacity      → drift, pg_stat_database counters, connections, sequences, lock table
12. synthesise                  → severity-ranked findings, each citing a catalog row
```

Contracts the agent must not break: read-only, every number sourced from a query, no `EXPLAIN ANALYZE` against production without confirmation.

## Database connection

pglens enforces read-only at the protocol layer. Use a dedicated `pg_monitor` role:

```sql
CREATE USER marvin_ro WITH PASSWORD '...';
GRANT CONNECT ON DATABASE prod TO marvin_ro;
GRANT pg_monitor TO marvin_ro;     -- covers pg_stat_*, pg_ls_waldir(), pg_stat_statements
GRANT USAGE ON SCHEMA public TO marvin_ro;
```

Azure Flexible Server: same role for app-database phases. Phase 5a additionally reads `azure_sys.query_store.*` (covered by `azure_pg_admin`).

Session GUCs the agent sets: `statement_timeout = '30s'` (60s for Phase 2), `lock_timeout = '2s'`, `idle_in_transaction_session_timeout = '60s'`.

If pglens is unreachable, marvin falls back to **user-mediated mode**: it prints queries; the user runs and pastes results back.

## Phases

| # | Phase | Asset |
|---|---|---|
| 0  | Preflight (version, sizes, extensions, settings) | `00-preflight.sql` |
| 1  | Wraparound, slot bloat, WAL | `01-existential-threats.sql` |
| 2  | Table + B-tree bloat (pgexperts) | `02-bloat-pgexperts.sql` |
| 3  | Vacuum lag + long-running transactions | `03-vacuum-and-long-xacts.sql` |
| 4  | Locks & blocking | `04-locks-and-blocking.sql` |
| 5  | Workload hotspots (`pg_stat_statements`, `pg_stat_io`, waits) | `05-workload-hotspots.sql` |
| 5a | Azure Query Store (time-bucketed + per-query waits) | `05a-azure-query-store.sql` |
| 6  | Index health (unused / dup / prefix-redundant / missing-FK / invalid) | `06-index-health.sql` |
| 7  | Replication (physical lag, xmin horizon, logical slots, subscriptions, conflicts) | `07-replication.sql` |
| 8  | Config & capacity (drift, `pg_stat_database` counters, connections, sequences, lock table) | `08-config-and-capacity.sql` |

**Not yet shipped:** structured synthesis template, GIN pending-list / BRIN summarisation checks, low-cardinality index detection, PG19.

## How it works

**Bloat math.** Pgexperts statistics-based estimate, not `n_dead_tup`. For borderline cases marvin recommends `pgstattuple_approx`. See `skills/marvin/references/interpretation-thresholds.md` for the rationale.

**Version branching.** PG16+ hard floor, PG18 supported. `1b`, `5b`, `5k`, `3c-progress` ship in `[PG16]` and `[PG17+]` variants (PG17 renamed `blk_*_time` and moved checkpoint stats). `3f`, `5i2`, `7e [PG18]` are PG18-only blocks (new columns). Everything else is single-variant; PG18-only GUCs are read via `pg_settings` so they simply return no row on older majors. PG19 (beta) is not targeted yet.

**Replica-aware.** `pg_is_in_recovery()` is checked first. No `VACUUM`, no `CREATE INDEX`, no `pg_terminate_backend` against a hot standby.

**Asset format.** Each `assets/NN-*.sql` is a labelled catalogue: `-- ===` block headers, one SELECT per block, runnable through pglens's `query` tool or any SQL client. No psql meta.

## Recommended extensions

| Extension | Phase | Why |
|---|---|---|
| `pg_stat_statements` | 5-2, 5a–5e, 5b2 | Required for cumulative query stats; `5-2` checks eviction (`dealloc`) first |
| `pgstattuple` | 2 follow-up | Exact bloat when the estimate is borderline |
| `pg_repack` | remediation | Online table rewrite |
| `auto_explain` | plan capture | Slow-query plans logged automatically |
| `pg_wait_sampling` | 5j follow-up | Sustained wait distribution |

## Layout

```
marvin/
├── .claude-plugin/{plugin,marketplace}.json
└── skills/marvin/
    ├── SKILL.md
    ├── references/
    │   ├── interpretation-thresholds.md
    │   ├── remediation-playbook.md
    │   └── version-compatibility.md
    └── assets/
        ├── 00-preflight.sql
        ├── 01-existential-threats.sql
        ├── 02-bloat-pgexperts.sql
        ├── 03-vacuum-and-long-xacts.sql
        ├── 04-locks-and-blocking.sql
        ├── 05-workload-hotspots.sql
        ├── 05a-azure-query-store.sql
        ├── 06-index-health.sql
        ├── 07-replication.sql
        └── 08-config-and-capacity.sql
```

## Limitations

- PG16+ only.
- Read-only. No automatic fixes.
- Not a monitoring replacement (no historical trending).
- Single-database run per session (cluster-wide risks surface; per-DB phases hit the connected DB).
- Doesn't profile individual queries. Paste `EXPLAIN (ANALYZE, BUFFERS)` output back.

## License

MIT. The pgexperts bloat queries are derived from [ioguix/pgsql-bloat-estimation](https://github.com/ioguix/pgsql-bloat-estimation) (BSD).

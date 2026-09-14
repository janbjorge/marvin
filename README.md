# marvin

Read-only PostgreSQL audits for LLM agents, at the depth a senior DBA would go. One Skill folder. PG16 and newer.

marvin is a [Claude Skill](https://docs.claude.com/en/docs/claude-code/skills) that makes an MCP-capable agent review a Postgres database without writing to it. Every finding cites the catalog row that produced it. Bloat estimates come from the [pgexperts statistics-based method](https://github.com/ioguix/pgsql-bloat-estimation) instead of the `n_dead_tup` ratio that LLMs tend to hallucinate. It accounts for transaction ID wraparound, replicas, and Azure Flexible Server.

All Postgres access goes through [pglens](https://github.com/janbjorge/pglens), a read-only MCP server.

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

marvin is packaged as a Claude Code plugin. Install it from the marketplace, or copy the skill folder by hand.

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

For Codex CLI or OpenCode, point your `AGENTS.md` or `opencode.jsonc` at `skills/marvin/SKILL.md`. It is a self-contained instruction file.

Trigger it with *"Postgres health check"*, *"bloat audit"*, or *"why is my DB slow"*.

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

The agent must keep three contracts: stay read-only, source every number from a query result, and never run `EXPLAIN ANALYZE` against production without confirmation.

## Database connection

pglens enforces read-only access at the protocol layer. Use a dedicated `pg_monitor` role:

```sql
CREATE USER marvin_ro WITH PASSWORD '...';
GRANT CONNECT ON DATABASE prod TO marvin_ro;
GRANT pg_monitor TO marvin_ro;     -- covers pg_stat_*, pg_ls_waldir(), pg_stat_statements
GRANT USAGE ON SCHEMA public TO marvin_ro;
```

On Azure Flexible Server the same role covers the app-database phases. Phase 5a also reads `azure_sys.query_store.*`, which `azure_pg_admin` covers.

The agent sets these session GUCs: `statement_timeout = '30s'` (60s for Phase 2), `lock_timeout = '2s'`, `idle_in_transaction_session_timeout = '60s'`.

If pglens is unreachable, marvin falls back to user-mediated mode. It prints the queries, and you run them and paste the results back.

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

Not yet shipped: structured synthesis template, GIN pending-list and BRIN summarisation checks, low-cardinality index detection, PG19.

## How it works

Bloat math uses the pgexperts statistics-based estimate, not `n_dead_tup`. For borderline cases marvin recommends `pgstattuple_approx`. The rationale is in `skills/marvin/references/interpretation-thresholds.md`.

Version branching starts at PG16, the hard floor, and goes up to PG18. Blocks `1b`, `5b`, `5k`, and `3c-progress` ship in `[PG16]` and `[PG17+]` variants, because PG17 renamed `blk_*_time` and moved the checkpoint stats. Blocks `3f`, `5i2`, and `7e [PG18]` rely on new PG18 columns and run only there. Everything else is single-variant. PG18-only GUCs are read through `pg_settings`, so on older majors they return no row. PG19 (beta) is not targeted yet.

Replicas are detected up front with `pg_is_in_recovery()`. marvin never proposes `VACUUM`, `CREATE INDEX`, or `pg_terminate_backend` on a hot standby.

Each `assets/NN-*.sql` file is a labelled catalogue with `-- ===` block headers and one SELECT per block. The blocks run through pglens's `query` tool or any SQL client, with no psql meta-commands.

## Recommended extensions

| Extension | Phase | Why |
|---|---|---|
| `pg_stat_statements` | 5-2, 5a-5e, 5b2 | Required for cumulative query stats; `5-2` checks eviction (`dealloc`) first |
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

- PG16 and newer only.
- Read-only. No automatic fixes.
- Not a monitoring replacement. There is no historical trending.
- One database per session. Cluster-wide risks still show up, but the per-database phases only see the connected database.
- Does not profile individual queries. Paste `EXPLAIN (ANALYZE, BUFFERS)` output back to the agent.

## License

MIT. The pgexperts bloat queries are derived from [ioguix/pgsql-bloat-estimation](https://github.com/ioguix/pgsql-bloat-estimation) (BSD).

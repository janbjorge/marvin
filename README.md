# marvin

**Senior-DBA-grade PostgreSQL audits for LLMs. One Skill folder, no daemons, no API keys.**

marvin is a [Claude Skill](https://docs.claude.com/en/docs/claude-code/skills) that turns an MCP-capable agent into a thorough, opinionated, read-only Postgres reviewer. Numbers come from the catalog — every finding cites the view and column it was sourced from. Bloat math is the [pgexperts statistics-based estimate](https://github.com/ioguix/pgsql-bloat-estimation), not the `n_dead_tup` ratio LLMs love to hallucinate. Wraparound-, replica-, and Azure-Flexible-Server-aware.

Talks to Postgres exclusively through **[pglens](https://github.com/janbjorge/pglens)** (a read-only MCP server). Works with [Claude Code](#setup--claude-code), [Codex CLI](#setup--codex-cli), and [OpenCode](#setup--opencode).

```
User:  "Is my Postgres OK?"
Agent: → loads marvin
       → Phase 0: PG 17.8, primary, uptime 42d, stats reset 19d ago
       → Phase 1: relfrozenxid age = 87% of autovacuum_freeze_max_age  ← HIGH
       → Phase 2: orders table 41% bloat / 12 GB reclaimable (pgexperts) ← HIGH
       → Phase 5: 1 query = 38% of total_exec_time, 4 GB temp/day      ← HIGH
       → Phase 6: 7 unused indexes, 3.4 GB                              ← MEDIUM
       Findings ranked by severity, each with the catalog row that proves it.
```

## Contents

- [Install](#install) — Claude Code · Codex CLI · OpenCode
- [How an agent uses marvin](#how-an-agent-uses-marvin) — the decision tree
- [Database connection](#database-connection) — pglens + permissions
- [Phases](#phases) — what gets checked, sourced to which asset
- [How it works](#how-it-works) — bloat math, version branching, replica handling
- [Asset format](#asset-format) — labelled SQL catalogue, no psql meta
- [Layout](#layout)
- [Limitations](#limitations)

## Install

marvin is packaged as a Claude Code plugin (`.claude-plugin/plugin.json` + `skills/marvin/`). Install via the marketplace, drop the skill directly, or reference `SKILL.md` from any agent's instruction file.

### Setup — Claude Code

```bash
claude plugin marketplace add janbjorge/marvin
claude plugin install marvin-skills@marvin
```

Verify with `claude plugin list` — `marvin-skills` should appear. Then `/skills` should list `marvin`. Trigger by asking for a *"Postgres health check"*, *"bloat audit"*, or *"why is my database slow"*.

Or drop the skill directly:

```bash
git clone https://github.com/janbjorge/marvin.git /tmp/marvin
cp -r /tmp/marvin/skills/marvin ~/.claude/skills/marvin   # user-level
# or
cp -r /tmp/marvin/skills/marvin .claude/skills/marvin     # project-level
```

### Setup — Codex CLI

Codex doesn't have a skill system, but `SKILL.md` is a self-contained instruction file the agent can read on demand.

```bash
git clone https://github.com/janbjorge/marvin.git ~/.codex/marvin
```

Add to your project's `AGENTS.md`:

```markdown
For Postgres health, bloat, or performance questions, follow the procedure in
~/.codex/marvin/skills/marvin/SKILL.md.
```

### Setup — OpenCode

OpenCode reads instruction files listed explicitly in `opencode.jsonc` ([OpenCode config docs](https://opencode.ai/docs/config/)).

```bash
git clone https://github.com/janbjorge/marvin.git .opencode/marvin
```

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "instructions": [".opencode/marvin/skills/marvin/SKILL.md"]
}
```

## How an agent uses marvin

The agent does not invent SQL. It runs labelled blocks from the assets, in order, and synthesises findings from the row data.

```
1. Run 00-preflight.sql       → capture pg_ver, pg17_plus, is_replica
2. Abort if pg_ver < 160000   → marvin requires PG16+
3. Run 01-existential.sql     → halt if wraparound or slot bloat is CRITICAL
4. Run 02-bloat-pgexperts.sql → bloat severity from pgexperts numbers
5. Run 03-vacuum-and-xacts    → long transactions block global xmin
6. Run 04-locks-and-blocking  → live operational health
7. Run 05-workload-hotspots   → pick 5b [PG16] vs 5b [PG17+] from preflight
8. If azure_sys exists, also  → reconnect to azure_sys; run 05a-azure-query-store
9. Run 06-index-health        → unused / duplicate / missing-FK / invalid
10. Synthesise                → severity-ranked findings, each citing a catalog row
```

**Decision points the agent owns:**
- Asset selection driven by preflight flags (only `pg17_plus` branches anything today).
- Whether to use the specialised pglens tool (`bloat_stats`, `unused_indexes`, `blocking_locks`, `active_queries`, `table_stats`, `sequence_health`, `matview_status`) or the raw `query` tool with the asset block.
- Severity calls (HIGH / MEDIUM / LOW) using thresholds in `references/interpretation-thresholds.md`.

**Contracts the agent must not break:**
- Read-only. No `VACUUM`, `REINDEX`, `DROP`, `ALTER`, `INSERT`, `UPDATE`, `DELETE` without explicit user confirmation per statement.
- Every number cited comes from a query result in the session. No prose math.
- If a number cannot be sourced, marvin says so — never guesses.

## Database connection

marvin diagnoses, it doesn't connect. The agent talks to Postgres through **[pglens](https://github.com/janbjorge/pglens)** — an MCP server whose tool surface maps onto marvin's phases (`bloat_stats`, `unused_indexes`, `blocking_locks`, `active_queries`, `table_stats`, `sequence_health`, `matview_status`, `list_extensions`, plus a generic `query`). Read-only is enforced at the protocol layer (`readonly=True` transactions, `quote_ident()` for identifiers), so the read-only contract does not depend on the agent's discipline.

If pglens is unreachable, marvin operates in **degraded user-mediated mode**: it prints copyable queries; the user runs them and pastes results back. Slow but always works.

### Required permissions

```sql
CREATE USER marvin_ro WITH PASSWORD '...';
GRANT CONNECT ON DATABASE prod TO marvin_ro;
GRANT pg_monitor TO marvin_ro;     -- covers pg_stat_*, pg_ls_waldir(), pg_stat_statements
GRANT USAGE ON SCHEMA public TO marvin_ro;
```

For Azure Database for PostgreSQL Flexible Server, the same role works for app-database phases. Phase 5a additionally needs read on `azure_sys.query_store.*`, which the built-in `azure_pg_admin` role and Query Store grant model provide.

### Session safety

The agent should set these GUCs before raw queries (pglens does not impose them):

```sql
SET statement_timeout = '30s';   -- 60s for the pgexperts bloat phase
SET lock_timeout = '2s';
SET idle_in_transaction_session_timeout = '60s';
```

An audit that times out gracefully is correct. An audit that holds a long transaction and contributes to the bloat it's measuring is broken.

## Phases

| # | Phase | Asset | Why |
|---|---|---|---|
| 0 | Preflight: version, recovery status, extensions, settings | `assets/00-preflight.sql` | Drives every later branch |
| 1 | Existential threats: xid + multixact wraparound, slot bloat, WAL | `assets/01-existential-threats.sql` | Halt the audit if CRITICAL |
| 2 | Table & B-tree index bloat (pgexperts math) | `assets/02-bloat-pgexperts.sql` | The headline question |
| 3 | Vacuum state & long-running transactions | `assets/03-vacuum-and-long-xacts.sql` | Root cause of most bloat |
| 4 | Locks & blocking chains | `assets/04-locks-and-blocking.sql` | Live operational health |
| 5 | Workload hotspots: `pg_stat_statements`, seq-scan dominance, cache miss, `pg_stat_io`, wait events | `assets/05-workload-hotspots.sql` | Where the load is and why |
| 5a | Azure Flexible Server Query Store (`azure_sys.query_store.*`) + wait sampling | `assets/05a-azure-query-store.sql` | Time-bucketed history + per-query waits that `pg_stat_statements` cannot capture |
| 6 | Index health: unused / duplicate / prefix-redundant / missing-FK / invalid | `assets/06-index-health.sql` | Storage & write amplification |

**Roadmap (not yet shipped):** replication health, checkpoint / WAL pressure, connection pressure & idle-in-transaction, configuration drift audit, structured synthesis template. The current synthesis happens in-conversation from the shipped phases.

### Recommended extensions

| Extension | Phase | Why |
|---|---|---|
| `pg_stat_statements` | 5a, 5b, 5b2, 5c, 5d, 5e | Required for cumulative query stats |
| `pgstattuple` | 2 follow-up | Exact bloat numbers when the estimate is borderline |
| `pg_repack` | Remediation | Online table rewrite (safe alternative to `VACUUM FULL`) |
| `auto_explain` | Plan capture | Plans of slow queries logged automatically |
| `pg_wait_sampling` | 5j follow-up | Sustained wait-event distribution beyond a single snapshot |

## How it works

### Bloat math

marvin uses the [pgexperts statistics-based estimate](https://github.com/ioguix/pgsql-bloat-estimation), not the `n_dead_tup / (n_live_tup + n_dead_tup)` ratio commonly seen in AI-generated audits. The naive ratio measures *unvacuumed dead tuples*, not bloat — they are not the same thing. For borderline cases marvin recommends `pgstattuple_approx` for the exact number (or `pgstattuple` if a full scan is acceptable).

### Version branching

marvin targets **PostgreSQL 16+** as a hard floor (covers `pg_stat_io`, `last_seq_scan` / `last_idx_scan`, `n_tup_newpage_upd`, `total_plan_time`, `wal_bytes`). The only branch that remains is the `shared_blk_*_time` rename in `pg_stat_statements` (PG17). Block `5b` ships in `[PG16]` and `[PG17+]` variants; the agent picks based on `pg17_plus` from `00-preflight.sql`. Everything else is single-variant.

### Replica-aware

`pg_is_in_recovery()` is checked first. Recommendations adjust — no `VACUUM`, no `CREATE INDEX`, no `pg_terminate_backend` against a hot standby.

### Catalog citation

Every finding names its source view and column. Numbers are pasted from query output, not summarised in prose. If you can't re-run the SQL and get the same number, marvin didn't say it.

## Asset format

Each `skills/marvin/assets/NN-*.sql` file is a labelled catalogue of SELECT-only queries. Blocks are separated by `-- ===` headers and labelled by phase (`-- 5a`, `-- 5b [PG16]`, `-- 5b [PG17+]`, …). The agent reads the preflight version flags, then picks the right block per phase and runs it through pglens.

**No psql meta. No `\if`, no `\gset`, no `\echo`.** Each block is a single statement, runnable identically through pglens's `query` tool, `psql -c`, or any other Postgres client.

The pgexperts query in `02-bloat-pgexperts.sql` is derived from [pgexperts/pgsql-bloat-estimation](https://github.com/ioguix/pgsql-bloat-estimation).

## Layout

```
marvin/
├── .claude-plugin/
│   ├── plugin.json                ← plugin manifest
│   └── marketplace.json           ← marketplace manifest
├── skills/
│   └── marvin/
│       ├── SKILL.md               ← main workflow (read by the agent)
│       ├── references/
│       │   ├── version-compatibility.md   ← PG16–17 catalog/column matrix
│       │   ├── bloat-detection.md         ← pgexperts queries + interpretation
│       │   ├── interpretation-thresholds.md
│       │   └── remediation-playbook.md    ← safe patterns w/ lock disclosure
│       └── assets/
│           ├── 00-preflight.sql                ← context + version flags
│           ├── 01-existential-threats.sql      ← wraparound, slot bloat, WAL
│           ├── 02-bloat-pgexperts.sql
│           ├── 03-vacuum-and-long-xacts.sql
│           ├── 04-locks-and-blocking.sql
│           ├── 05-workload-hotspots.sql
│           ├── 05a-azure-query-store.sql       ← Azure Flexible Server (azure_sys DB)
│           └── 06-index-health.sql
├── LICENSE
└── README.md
```

## Limitations

- **Pre-PG16 unsupported.** The audit's headline signals live in PG16+; running against older majors will error on missing columns and views.
- **No fixes applied automatically.** Every remediation requires explicit user confirmation per statement.
- **Not a monitoring replacement.** pganalyze, pgwatch, Datadog DBM, and `pgBadger` do continuous log-history analysis that marvin does not.
- **Doesn't profile individual queries.** Paste `EXPLAIN (ANALYZE, BUFFERS)` output back to the agent for plan-level analysis.
- **Doesn't review schema design.**
- **Single-database audit.** Cluster-wide risks (wraparound, slot bloat) are surfaced; per-database phases run only against the connected database.
- **Point-in-time snapshot.** No historical comparison; for trends use Phase 5a (Azure Query Store) or a monitoring product.

## License

MIT. The pgexperts bloat queries are derived from [ioguix/pgsql-bloat-estimation](https://github.com/ioguix/pgsql-bloat-estimation) (BSD).

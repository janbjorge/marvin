# marvin

**Senior-DBA-grade PostgreSQL audits for LLMs. One Skill folder, no daemons, no API keys.**

marvin is a [Claude Skill](https://docs.claude.com/en/docs/claude-code/skills) that turns an MCP-capable agent into a thorough, opinionated, read-only Postgres reviewer. Findings are sourced from the catalog (no prose math, no hallucinated sums), version-aware (PG 12–17), wraparound-aware, replica-aware, and self-protecting.

Works with any agent that can speak Postgres over MCP or `psql`: [Claude Code](#setup--claude-code), [Codex CLI](#setup--codex-cli), [OpenCode](#setup--opencode).

```
User:  "Is my Postgres OK?"
Agent: → loads marvin
       → SET statement_timeout=30s, lock_timeout=2s, default_transaction_read_only=on
       → Phase 1: relfrozenxid age = 87% of autovacuum_freeze_max_age  ← HIGH
       → Phase 2: orders table 41% bloat, 12 GB reclaimable           ← HIGH
       → Phase 6: 7 unused indexes, 3.4 GB                            ← MEDIUM
       Reports findings ranked by severity, with the SQL that proves each one.
```

## Install

marvin is packaged as a Claude Code plugin (`.claude-plugin/plugin.json` + `skills/marvin/`). Install via the marketplace, drop the skill directly, or reference `SKILL.md` from any agent's instruction file.

## Setup — Claude Code

Two steps. Add the marketplace, install the plugin:

```bash
claude plugin marketplace add janbjorge/marvin
claude plugin install marvin-skills@marvin
```

Verify with `claude plugin list` — `marvin-skills` should appear. Then `/skills` should list `marvin`. Trigger by asking for a *"Postgres health check"*, *"bloat audit"*, or *"why is my database slow"*.

**Or, drop the skill directly without the plugin system:**

```bash
git clone https://github.com/janbjorge/marvin.git /tmp/marvin
cp -r /tmp/marvin/skills/marvin ~/.claude/skills/marvin   # user-level
# or
cp -r /tmp/marvin/skills/marvin .claude/skills/marvin     # project-level
```

> **Database connection.** marvin is instructions, not a client. The agent needs a Postgres channel — see [Database connection](#database-connection) below.

## Setup — Codex CLI

Codex doesn't have a skill system, but `SKILL.md` is a self-contained instruction file the agent can read on demand.

```bash
git clone https://github.com/janbjorge/marvin.git ~/.codex/marvin
```

Add to your project's `AGENTS.md`:

```markdown
For Postgres health, bloat, or performance questions, follow the procedure in
~/.codex/marvin/skills/marvin/SKILL.md.
```

## Setup — OpenCode

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

## Database connection

marvin diagnoses, it doesn't connect. The agent needs a channel to Postgres. In order of preference:

1. **[pglens](https://github.com/janbjorge/pglens)** (recommended) — MCP server whose tools map onto marvin's phases (`bloat_stats`, `unused_indexes`, `blocking_locks`, `active_queries`, `table_stats`, plus a generic `query`). Read-only at the protocol layer.
2. **Other Postgres MCPs** — official `postgres` MCP, Tiger `pg-aiguide`, Supabase, Neon, Crunchy Bridge. Anything with a `query` tool works; marvin issues raw SELECTs through it.
3. **`psql` via shell** — works if the agent has shell access and a read-only role.
4. **User-mediated** — marvin prints copyable queries; user runs them and pastes results back. Slow but always works.

## Required permissions

```sql
CREATE USER marvin_ro WITH PASSWORD '...';
GRANT CONNECT ON DATABASE prod TO marvin_ro;
GRANT pg_monitor TO marvin_ro;  -- PG10+, covers pg_stat_* and pg_ls_waldir()
```

## Phases

marvin runs 12 phases, each sourced to specific catalog views. Findings are tagged HIGH/MEDIUM/LOW and grouped at the end.

| # | Phase | Why |
|---|---|---|
| 0 | Preflight & self-protection | Session limits so the audit can't break the DB |
| 1 | Existential threats: wraparound, slot bloat, disk | Halt and surface immediately |
| 2 | Table & index bloat (pgexperts math) | The headline question |
| 3 | Vacuum state & long-running transactions | Root cause of most bloat |
| 4 | Locks & blocking chains | Live operational health |
| 5 | Query performance via `pg_stat_statements` | Workload hotspots |
| 6 | Index health: unused / duplicate / missing FK / invalid | Storage & write amplification |
| 7 | Replication health | Slot lag, replay lag |
| 8 | I/O, checkpoints, WAL pressure | Throughput ceilings (`pg_stat_io` on PG16+) |
| 9 | Connections & idle-in-transaction | Pooling & leak detection |
| 10 | Configuration audit | Misconfigurations and defaults that bite |
| 11 | Synthesis | Severity-ranked report with remediation SQL |

## Recommended extensions

| Extension | Why |
|---|---|
| `pg_stat_statements` | Required for Phase 5 |
| `pgstattuple` | Exact bloat numbers when the estimate is borderline |
| `pg_repack` | Online table rewrite (safe alternative to `VACUUM FULL`) |
| `auto_explain` | Captures plans of slow queries automatically |

## How it works

### Self-protection

Every script and every phase opens with:

```sql
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET idle_in_transaction_session_timeout = '60s';
SET default_transaction_read_only = on;
```

An audit that times out gracefully is correct. An audit that holds a long transaction and contributes to the bloat it's measuring is broken.

### Bloat math

marvin uses the [pgexperts statistics-based estimate](https://github.com/ioguix/pgsql-bloat-estimation), not the `n_dead_tup / (n_live_tup + n_dead_tup)` ratio commonly seen in AI-generated audits. The naive ratio measures *unvacuumed dead tuples*, not bloat — they are not the same thing. For borderline cases marvin recommends `pgstattuple` for the exact number.

### Version branching

PG13 renamed `pg_stat_statements` columns. PG14 added `pg_stat_wal`. PG16 added `pg_stat_io`. PG17 split `pg_stat_checkpointer`. marvin detects `server_version_num` once at Phase 0 and branches per phase.

### Replica-aware

`pg_is_in_recovery()` is checked first. Recommendations adjust — no `VACUUM` suggestions against a hot standby.

### Catalog citation

Every finding names its source view and column. Numbers are pasted from query output, not summarized in prose. If you can't paste the SQL into `psql` and get the same result, marvin didn't say it.

## Running without an agent

The shipped scripts are runnable directly:

```bash
psql -X -f skills/marvin/assets/00-preflight-and-existential.sql -d "$DATABASE_URL"
psql -X -f skills/marvin/assets/03-vacuum-and-long-xacts.sql      -d "$DATABASE_URL"
psql -X -f skills/marvin/assets/04-locks-and-blocking.sql         -d "$DATABASE_URL"
psql -X -f skills/marvin/assets/06-index-health.sql               -d "$DATABASE_URL"
```

Phases 2, 5, 7, 8, 9, 10 currently live inline in `SKILL.md`. For bloat estimation as a standalone script, use [pgexperts/pgsql-bloat-estimation](https://github.com/ioguix/pgsql-bloat-estimation).

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
│       │   ├── version-compatibility.md   ← PG12–17 catalog/column matrix
│       │   ├── bloat-detection.md         ← pgexperts queries + interpretation
│       │   ├── interpretation-thresholds.md
│       │   └── remediation-playbook.md    ← safe patterns w/ lock disclosure
│       └── assets/
│           ├── 00-preflight-and-existential.sql
│           ├── 03-vacuum-and-long-xacts.sql
│           ├── 04-locks-and-blocking.sql
│           └── 06-index-health.sql
├── LICENSE
└── README.md
```

## Limitations

- Pre-PG12 unsupported.
- Doesn't apply fixes — every remediation requires user confirmation.
- Doesn't replace continuous monitoring (pganalyze, pgwatch, Datadog DBM) or `pgBadger` for log history.
- Doesn't profile individual queries — paste `EXPLAIN (ANALYZE, BUFFERS)` output back to the agent.
- Doesn't review schema design.
- Single-database audit. Cluster-wide risks (wraparound) are surfaced; per-DB phases run only against the connected DB.
- Point-in-time snapshot. No history.

## License

MIT. The pgexperts bloat queries are derived from [ioguix/pgsql-bloat-estimation](https://github.com/ioguix/pgsql-bloat-estimation) (BSD).

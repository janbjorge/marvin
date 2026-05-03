# marvin

> "Here I am, brain the size of a planet, and they ask me to count dead tuples. Call that job satisfaction? 'Cos I don't."

A senior-DBA-grade PostgreSQL health, bloat, and performance audit, packaged as a Claude Skill. Named after Marvin the Paranoid Android — vastly over-qualified, perpetually finding things wrong, and constitutionally incapable of pretending the database is fine when it isn't.

Designed for engineers who want findings backed by the catalog rather than folklore. Read-only by default. Version-aware (PG 12–17). Self-protecting (the audit session can't itself become an incident). Wraparound-aware. Replica-aware. Every reported number is sourced from a SELECT — no prose math, no hallucinated sums. No naive `n_dead_tup` ratios sold as "bloat percentages."

## What it does

| Phase | What | Why |
|---|---|---|
| 0 | Preflight & self-protection | Session limits so the audit can't break the DB |
| 1 | Existential threats: wraparound, slot bloat, disk | Halt the audit and surface immediately if found |
| 2 | Table & index bloat (pgexperts math) | The headline question |
| 3 | Vacuum state & long-running transactions | Root cause of most bloat |
| 4 | Locks & blocking chains | Live operational health |
| 5 | Query performance via `pg_stat_statements` | Workload hotspots |
| 6 | Index health: unused / duplicate / missing FK / invalid | Storage & write amplification waste |
| 7 | Replication health | Slot lag, replay lag |
| 8 | I/O, checkpoints, WAL pressure | Throughput ceilings (uses `pg_stat_io` on PG16+) |
| 9 | Connections & idle-in-transaction | Pooling & leak detection |
| 10 | Configuration audit | Misconfigurations and defaults that bite |
| 11 | Synthesis | Severity-ranked report with remediation SQL |

## What it does NOT do

- Apply fixes automatically. Every remediation is presented with lock impact and rough duration; user confirms each statement.
- Replace continuous monitoring (pganalyze, pgwatch, Datadog DBM).
- Replace pgBadger for log-based historical analysis.
- Profile individual queries (the user runs `EXPLAIN (ANALYZE, BUFFERS)` and pastes the plan back).
- Work well on PG ≤ 11 — flag and warn.

## Layout

```
marvin/
├── SKILL.md                       # main workflow, used by Claude
├── README.md                      # this file
├── references/
│   ├── version-compatibility.md   # PG12–17 catalog/column matrix
│   ├── bloat-detection.md         # full pgexperts bloat queries + interpretation
│   ├── interpretation-thresholds.md
│   └── remediation-playbook.md    # safe patterns w/ lock disclosure
└── assets/
    ├── 00-preflight-and-existential.sql
    ├── 03-vacuum-and-long-xacts.sql
    ├── 04-locks-and-blocking.sql
    └── 06-index-health.sql
    # 02-bloat-estimation.sql is not yet shipped as a standalone file —
    # the bloat queries currently live inline in SKILL.md, sourced from
    # pgexperts (https://github.com/ioguix/pgsql-bloat-estimation).
    # Use that repo directly if you want a `psql -f`-able script today.
```

## Installing as a Claude skill

### Claude Code

```bash
# From the directory containing marvin/
claude plugin install ./marvin
```

Or copy the folder into `~/.claude/skills/` and Claude Code will pick it up automatically.

### Other agents (via skills CLI)

```bash
npx skills add ./marvin --skill marvin
```

## Using it without Claude

The `assets/*.sql` files are runnable directly with `psql`:

```bash
psql -X -f assets/00-preflight-and-existential.sql -d "$DATABASE_URL"
psql -X -f assets/03-vacuum-and-long-xacts.sql      -d "$DATABASE_URL"
psql -X -f assets/04-locks-and-blocking.sql         -d "$DATABASE_URL"
psql -X -f assets/06-index-health.sql               -d "$DATABASE_URL"
# For bloat estimation, run the pgexperts queries directly:
#   https://github.com/ioguix/pgsql-bloat-estimation
```

Each script sets safe session limits up front (`statement_timeout = 30s`, `lock_timeout = 2s`, `default_transaction_read_only = on`) so it can't itself become an incident.

## Required permissions

The audit needs:
- `CONNECT` on the target database
- `pg_monitor` role membership (PG10+) — gives access to all the `pg_stat_*` views without needing superuser

```sql
CREATE USER marvin_ro WITH PASSWORD '...';
GRANT CONNECT ON DATABASE prod TO marvin_ro;
GRANT pg_monitor TO marvin_ro;
```

For wraparound and disk checks, `pg_read_server_files` (or superuser) is needed. The script will degrade gracefully if not granted.

## Database connection

Marvin doesn't connect to the database itself — it's a Claude Skill, which is just instructions. The agent (Claude plus its host) needs a channel to Postgres. In order of preference:

### 1. pglens (recommended)

[pglens](https://github.com/janbjorge/pglens) is a PostgreSQL MCP server whose tool surface lines up with Marvin's diagnostic phases — `bloat_stats`, `unused_indexes`, `blocking_locks`, `table_stats`, `table_sizes`, `sequence_health`, `matview_status`, `active_queries`, plus a generic `query` tool for everything else. Read-only enforced at the protocol layer.

```bash
pip install pglens   # or: uv pip install pglens
```

Configure in Claude Desktop / Claude Code:

```json
{
  "mcpServers": {
    "pglens": {
      "command": "pglens",
      "env": {
        "PGHOST": "...",
        "PGUSER": "marvin_ro",
        "PGPASSWORD": "...",
        "PGDATABASE": "..."
      }
    }
  }
}
```

Caveats Marvin handles in `SKILL.md`:
- pglens's `bloat_stats` reports vacuum/wraparound state, not the pgexperts statistics-based estimate. Marvin uses `bloat_stats` for orientation and the pgexperts query (via the `query` tool) for the rigorous estimate that the HIGH/MEDIUM severity calls hinge on.
- `unused_indexes` should be cross-checked to ensure it excludes primary-key and unique-constraint indexes.

### 2. Other Postgres MCP servers

| MCP | When to use it |
|---|---|
| Official `postgres` MCP (modelcontextprotocol/servers) | Widely deployed, minimal — every Marvin phase becomes a raw SELECT through `query`. |
| Tiger Data `pg-aiguide` MCP | Backed by Tiger; broader Postgres tool surface, oriented toward writing-good-Postgres rather than diagnostics. Fine as a transport. |
| Supabase MCP | If you're on Supabase. |
| `pg-dash-mcp` | Brand-new, overlapping diagnostic tools. Try if pglens unavailable. |
| Neon MCP / Crunchy Bridge MCP | If you're on those platforms. |

### 3. `psql` via shell

If no MCP is configured but Claude has shell access, `psql` with a read-only role works.

### 4. User-mediated

If nothing's reachable, Marvin presents each query as a copyable block; the user runs it and pastes back the result. Slower but always works.

## Recommended extensions

The audit works without these, but they materially improve the findings:

| Extension | Why |
|---|---|
| `pg_stat_statements` | Phase 5 (query performance) requires it |
| `pgstattuple` | Exact bloat numbers when the estimate is borderline |
| `pg_repack` | Online table rewrite (the safe alternative to `VACUUM FULL`) |
| `auto_explain` | Captures plans of slow queries automatically |

## Design choices worth knowing

1. **Wraparound first.** Most AI-generated audits don't even check `relfrozenxid`. It's the #1 thing that takes Postgres offline in production.
2. **pgexperts bloat math, not `n_dead_tup` ratio.** The naive ratio measures *unvacuumed dead tuples*, not bloat — they're different things.
3. **Self-protecting session.** `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout` set up front. An audit that times out gracefully is correct; an audit that holds a transaction open and contributes to the bloat it's measuring is broken.
4. **Replica detection.** `pg_is_in_recovery()` checked first; recommendations adjusted. Don't suggest `VACUUM` against a hot standby.
5. **Version branching.** PG13 renamed `pg_stat_statements` columns. PG14 added `pg_stat_wal`. PG16 added `pg_stat_io`. PG17 split `pg_stat_checkpointer`. The skill detects once and branches.
6. **Severity over volume.** A 200-finding report is noise. Group, dedupe, sort by recoverable bytes / expected impact.
7. **Read-only by default.** Per-session `default_transaction_read_only = on`. No remediation without explicit per-statement confirmation.
8. **Cite the catalog.** Every finding names the source view/column for verifiability.

## Limitations

- **Pre-PG12 unsupported.** Bloat math, `pg_stat_statements` shape, and several other things differ. Patches welcome.
- **Doesn't speak to schema design.** The audit catches bloat, not "this table should have been partitioned three years ago."
- **Single-database audit.** Cluster-wide risks (wraparound) are surfaced, but per-DB phases run against the connected DB only. To audit a cluster, run against each user database.
- **No history.** Point-in-time snapshot. Trends require a monitoring tool.

## License

MIT. Use freely. The pgexperts bloat queries are derived from work at https://github.com/ioguix/pgsql-bloat-estimation (BSD).

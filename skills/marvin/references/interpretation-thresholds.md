# Threshold rationales

Where the numbers in `SKILL.md`'s severity rubric come from. Override per workload as needed (append-only / hot-update / OLAP all want different thresholds).

## Bloat

**Sort by bytes wasted, filter by percentage.** A 90% bloated 10 MB table loses to a 5% bloated 200 GB table. Use `bloat_size` to rank, `bloat_pct > 20` to drop noise.

**Fillfactor is not bloat.** The pgexperts query computes waste against the configured fillfactor target, not against 100% full. A `fillfactor = 70` table that's 30% empty is operating as designed (room for HOT updates).

**`pgstattuple_approx` is ground truth when the estimate is borderline.** Discrepancy causes: stale `pg_statistic`, recent `VACUUM` the estimate hasn't caught up to, or a `pg_catalog.name`-typed column tripping `is_na`.

**`n_dead_tup / (n_live_tup + n_dead_tup)` ≠ bloat.** That ratio is vacuum lag (dead tuples not yet reclaimed). Once vacuum runs it drops to ~0 while the relation file stays bloated (vacuum marks pages reusable, doesn't return them to the OS). Use it in Phase 3, not Phase 2.

## Vacuum / xacts

**1 hour open transaction → HIGH.** xmin held that long blocks autovacuum on every row updated/deleted since the xact started. The single most common production incident is a forgotten psql session.

**`idle in transaction (aborted)` → CRITICAL.** An error fired inside an explicit transaction, the app caught it and didn't `ROLLBACK`. Holds locks + xmin forever until the connection dies. Set `idle_in_transaction_session_timeout = '60s'` cluster-wide.

## Wraparound

| Counter | Default ceiling | Trigger |
|---|---|---|
| `autovacuum_freeze_max_age` | 200 M | anti-wraparound AV starts (uncancelable) |
| `vacuum_failsafe_age` (PG14+) | 1.6 B | emergency mode |
| Hard ceiling | ~2.13 B (`2^31 - 10M`) | cluster refuses new transactions |
| `autovacuum_multixact_freeze_max_age` | 400 M | MultiXact anti-wraparound |

`pct_to_emergency_av >= 90` is advance notice; `>= 100` means anti-wraparound AV is running right now and will contend hard with the workload. MultiXacts have a separate clock — heavy FK-checking / `FOR SHARE` workloads hit MultiXact wraparound first.

## Cache hit ratio

"99% is good" is folklore. The metric measures `shared_buffers` hits, not actual disk I/O — an OS page-cache hit still counts as a "miss" in `blks_read`. A 95% ratio on a tiny DB doing zero physical I/O is fine; a 99% ratio on a working set 10× `shared_buffers` is not.

What to use instead: `pg_stat_io` for backend-attributed I/O (PG16+), `pg_stat_database.blks_read` trends over time, working-set-vs-`shared_buffers` size comparison.

The `< 90%` threshold in `SKILL.md` is directional, not diagnostic.

## Connections

**80% of `max_connections` → investigate.** Each connection is a heavyweight process with per-backend memory cost. At 90% one workload spike triggers `FATAL: sorry, too many clients already`.

`max_connections` is rarely the right knob — overhead is fixed per backend even when idle. Use **PgBouncer in transaction mode** (or similar pooler) to multiplex thousands of client connections over a small pool of real backends. Caveats: breaks `LISTEN/NOTIFY`, session-level `SET`, plain prepared statements (pgbouncer 1.21+ with `max_prepared_statements` handles the last).

## Unused indexes

**100 MB total → flag.** Cost isn't just disk — every write updates the index. 100 MB unused on a high-write table is meaningful write amplification.

**`last_idx_scan` (PG16+) beats `idx_scan = 0`.** Timestamp survives stats resets, lets you say "last used 187 days ago" rather than guessing. Use both: `idx_scan = 0` AND `last_idx_scan IS NULL OR last_idx_scan < now() - interval '...' `.

## Checkpoints

`checkpoints_req / (checkpoints_req + checkpoints_timed) > 30%` → workload is pushing past `max_wal_size` between scheduled checkpoints. Fix is almost always **raise `max_wal_size`** (default 1 GB; 8–16 GB is routine on modern disks). Downside: longer crash recovery.

## Severity tiers

- **CRITICAL** = can-take-the-DB-offline. Halt audit, surface immediately.
- **HIGH** = fix this sprint. Real disk, real throughput, real value bleeding.
- **MEDIUM** = how DBs drift. None urgent, all compound.
- **LOW** = skippable. Real but not action items.

## Workload overrides

| Workload | Override |
|---|---|
| Append-only / analytical | bloat thresholds tighter (5–10% concerning) |
| Heavy update on hot rows | bloat thresholds looser (40% can be steady state) |
| `pg_stat_statements` off | skip Phase 5; note in report |
| OLAP / warehouse | cache hit ratio meaningless; per-query index ratios matter |
| Per-tenant schemas | sample or filter — N tenants × per-table queries blows up |

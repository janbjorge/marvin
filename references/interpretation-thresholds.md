# Interpretation & Threshold Rationales

Every threshold in the SKILL.md has a reason. This file documents them so the user can adapt the audit to their workload — a 99% cache hit ratio is great for OLTP and unremarkable for analytics; a 30% bloat percentage is fine for an update-heavy table with `fillfactor = 70` and a fire for an append-only one.

## Bloat thresholds

**Why "wasted bytes" matters more than "bloat percentage."**

A 90% bloated 10MB table has 9MB of waste. A 5% bloated 200GB table has 10GB of waste. Reclaiming 10GB beats reclaiming 9MB every time, but a percentage-only sort puts the small table on top.

Sort by `bloat_size` (bytes), filter by `bloat_pct > 20` to drop noise. Report both numbers.

**Why fillfactor matters.**

The naive intuition is "all empty space is bloat." For UPDATE-heavy tables with `fillfactor < 100`, empty space is *intentional* — Postgres uses it for HOT (Heap-Only Tuple) updates, which avoid index updates and dead-tuple cleanup. A `fillfactor = 70` table that's 30% empty is operating as designed.

The pgexperts query computes `bloat_size` against the fillfactor target, not against 100% full. That's correct. Don't override it.

**When `pgstattuple_approx` disagrees with the estimate.**

If the estimate says 40% bloat and `pgstattuple_approx` says 8%, trust `pgstattuple_approx`. Possible causes for the discrepancy: stale statistics (run `ANALYZE`), recently completed `VACUUM` that reclaimed space the estimate didn't see yet, or a `pg_catalog.name`-typed column tripping the estimate's `is_na` flag.

## Vacuum thresholds

**Why 1 hour for "long transaction"?**

The xmin held by a 1-hour transaction blocks autovacuum from cleaning any rows updated/deleted in that hour. On a database doing 1000 UPDATEs/sec, that's 3.6M dead tuples that can't be reclaimed. The number itself isn't magic; it's the inflection point where the rate of dead-tuple accumulation typically exceeds reasonable cleanup rates.

The single most common production Postgres incident is: a forgotten `psql` session, an analytics query that's been running for 6 hours, or a stuck application worker holding a transaction. Phase 3a finds these.

**Why `state = 'idle in transaction (aborted)'` is critical.**

This means an error fired inside an explicit transaction, the application caught the error but didn't `ROLLBACK`, and the connection is now wedged. It still holds locks. It still holds xmin. It will never make progress until the connection is closed or rolled back. Many ORMs leak these on retry-without-rollback bugs.

Recommended fix: set `idle_in_transaction_session_timeout` cluster-wide. The default of `0` (no limit) is wrong for almost every production workload. `60s` is a reasonable starting point.

**Why `dead_ratio` isn't a bloat metric.**

`n_dead_tup / (n_live_tup + n_dead_tup)` measures **dead tuples that haven't been vacuumed yet**. Once vacuum runs, `n_dead_tup` drops to (near) zero — but the table is still bloated, because `VACUUM` (without `FULL`) marks space reusable, it doesn't return it to the OS.

`dead_ratio` is an indicator of *vacuum lag* (vacuum hasn't run recently / can't keep up), not bloat (relation has accumulated wasted space over time). Use it in Phase 3, not Phase 2.

## Wraparound thresholds

**The 200M / 2.1B numbers.**

PG defaults:
- `autovacuum_freeze_max_age = 200_000_000` — at this age, autovacuum runs in "anti-wraparound" mode (cannot be skipped, runs even with `autovacuum = off`)
- `vacuum_freeze_table_age = 150_000_000` — at this age, regular VACUUM uses an aggressive scan
- `vacuum_failsafe_age = 1_600_000_000` (PG14+) — emergency mode kicks in
- Hard ceiling: `2^31 - 10_000_000 ≈ 2.13B` — the cluster refuses new transactions

The `pct_to_emergency_av >= 90` threshold gives advance notice before anti-wraparound autovacuum starts, which is good — anti-wraparound AV is uncancelable and will run flat-out, contending heavily with the workload.

**MultiXact wraparound is a separate clock.**

MultiXacts are used for shared row locks (multiple lockers on one row, e.g., FK validation while another transaction has a row-level lock). They have their own counter, their own wraparound risk, and their own `autovacuum_multixact_freeze_max_age` (default 400M). Workloads with heavy SELECT FOR SHARE / FOR KEY SHARE / FK-checking can hit MultiXact wraparound *before* xid wraparound. Don't forget to check both.

## Cache hit ratio thresholds

**The "99% cache hit ratio" target is folklore.**

What the metric actually measures: the ratio of buffer reads served from `shared_buffers` versus those requiring an OS read. A miss in `shared_buffers` is *usually* still satisfied from the OS page cache without a real disk I/O. The ratio doesn't tell you how many actual disk reads are happening.

Implications:
- A 95% hit ratio on a small DB with everything in OS cache may have ZERO disk I/O — performance is fine.
- A 99% hit ratio on a working set 10× the size of `shared_buffers` may be doing significant disk I/O on the 1% — performance is bad.

What to do instead:
- **PG16+**: use `pg_stat_io` to attribute actual reads by backend type and context.
- **All versions**: track `pg_stat_database.blks_read` over time. Trend matters more than absolute number.
- Compare the working set size (sum of `pg_relation_size` for hot tables/indexes) to `shared_buffers` and physical RAM. If working set < `shared_buffers`, ratio is meaningless.

The `< 90%` threshold in the SKILL.md is set conservatively — below that, *something* is missing the buffer cache often, and even if the OS cache is helping, you've burned CPU on lookups. It's a directional flag, not a diagnostic.

## Connection thresholds

**Why 80% of `max_connections`?**

Postgres connections are heavyweight processes with a per-backend memory cost (`work_mem` × concurrent operations + cached relation metadata). Saturation isn't just "queueing" — it's "OOM risk" once the connection count × peak per-backend memory exceeds available RAM.

The 80% threshold is the standard "investigate before you have to firefight." Above 90%, you're one workload spike from outright `FATAL: sorry, too many clients already` errors, which the application sees as outage.

**Why `max_connections` is rarely the right knob.**

Each connection has fixed overhead even when idle. Increasing `max_connections` from 100 to 500 multiplies the overhead 5×. The cost of context switches, lock manager scaling, and memory rises super-linearly past a few hundred concurrent active backends.

The right answer is almost always **PgBouncer in transaction mode** (or a similar pooler). It maintains a small pool of real backends (e.g., 25) and multiplexes thousands of client connections over them. The application thinks it has 5000 connections; Postgres sees 25 active backends. This works because most "connections" are idle most of the time.

Caveats: transaction-mode pooling breaks features that rely on session state — `SET LOCAL` works (transaction-scoped), session-level `SET` does not, `LISTEN/NOTIFY` does not, prepared statements need `protocol = extended` or pgbouncer 1.21+ with `max_prepared_statements`.

## Index thresholds

**Why "100MB total" for unused indexes?**

The cost of an unused index isn't just disk space. Every INSERT, UPDATE (on non-HOT paths), and DELETE on the table updates the index. A 1MB unused index on a low-write table is invisible. A 100MB unused index on a high-write table is meaningful write amplification — every transaction pays for it.

100MB is a triage threshold; the action is "flag for review" not "drop immediately." Each finding still needs the per-index caveats in Phase 6a.

**Why `last_idx_scan` (PG16+) is so much better than `idx_scan`.**

Pre-PG16, "unused" was inferred from `idx_scan = 0` since the last stats reset. If stats reset 2 days ago, the inference is unreliable for any low-traffic index.

PG16's `last_idx_scan` records the *timestamp* of the most recent scan, persistent across stats resets. Now you can say "this index was last used 187 days ago" with certainty. Combined with knowledge of seasonal/quarterly query patterns, this changes "unused index" from a guess to a fact.

## Checkpoint thresholds

**Why `pct_requested > 30%` matters.**

`checkpoints_timed` = checkpoints fired because `checkpoint_timeout` elapsed (the calm, predictable kind). `checkpoints_req` = checkpoints fired because WAL volume hit `max_wal_size` (the rushed kind, with a tighter completion target).

A high `requested` ratio means the database is being pushed past `max_wal_size` between scheduled checkpoints. This causes:
1. Checkpoint write spikes (less time to spread writes)
2. Higher WAL accumulation (and replication slot pressure)
3. Possible I/O saturation during the rushed checkpoints

The fix is almost always **raise `max_wal_size`**. It's a soft cap with one downside: more WAL means longer crash recovery. On modern systems with fast disks, raising `max_wal_size` from the default 1GB to 8–16GB is routine.

`checkpoint_completion_target` (default 0.9) controls how much of the inter-checkpoint time is used for spreading writes — a higher value smooths the I/O. The default is generally fine.

## Severity tier rationales

**Why CRITICAL is so narrow.**

Reserved for *can-take-the-database-offline* findings: wraparound, lost replication slots, disk pressure, idle-in-aborted-xact backends. Anything that fires CRITICAL means "stop the audit, surface this now, don't keep listing other findings."

**Why HIGH spans a wide range.**

HIGH is "fix this within the next sprint" — bloat that's costing real disk and write throughput, queries dominating the workload, missing FK indexes on big tables. Not actively burning the database down, but actively burning value.

**Why MEDIUM matters.**

MEDIUM findings are how databases drift over time. None of them is urgent; all of them compound. A skill that hides MEDIUM behind a `--verbose` flag will produce reports that look great today and worse every quarter.

**Why LOW exists at all.**

To be skippable. The user should be able to say "show me HIGH and CRITICAL only" and get a focused list. LOW gives the audit somewhere to put findings that are real but not action items.

## When the rubric is wrong for a workload

Override thresholds explicitly for the workload, don't argue with the audit:

- **Append-only / analytical**: bloat thresholds can be tighter (5–10% is concerning).
- **Heavy update on hot rows**: bloat thresholds can be looser (40% is steady-state on some workloads).
- **Read-mostly with pg_stat_statements off**: skip Phase 5, note in the report.
- **OLAP / data warehouse**: cache hit ratio target is meaningless; index scan ratios per-query matter more.
- **Single-tenant SaaS with per-tenant schemas**: per-table queries multiply by N tenants — limit by schema or sample.

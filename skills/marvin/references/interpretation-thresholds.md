# Threshold rationales

Where the numbers in `SKILL.md`'s severity rubric come from. Override per workload as needed (append-only / hot-update / OLAP all want different thresholds).

## Bloat

**Sort by bytes wasted, filter by percentage.** A 90% bloated 10 MB table loses to a 5% bloated 200 GB table. Use `bloat_size` to rank, `bloat_pct > 20` to drop noise.

**Fillfactor is not bloat.** The pgexperts query computes waste against the configured fillfactor target, not against 100% full. A `fillfactor = 70` table that's 30% empty is operating as designed (room for HOT updates).

**`pgstattuple_approx` is ground truth when the estimate is borderline.** Discrepancy causes: stale `pg_statistic`, recent `VACUUM` the estimate hasn't caught up to, or a `pg_catalog.name`-typed column tripping `is_na`.

**`n_dead_tup / (n_live_tup + n_dead_tup)` ≠ bloat.** That ratio is vacuum lag (dead tuples not yet reclaimed). Once vacuum runs it drops to ~0 while the relation file stays bloated (vacuum marks pages reusable, doesn't return them to the OS). Use it in Phase 3, not Phase 2.

**B-tree bloat is held to a different bar (`2b`).** Cybertec / Laurenz Albe, "Should I rebuild my PostgreSQL index?": "It is not unusual for the bloat in a B-tree index to reach about 70%. That alone is no reason to rebuild the index." B-trees settle into a steady state well above the table threshold, and the pgexperts index estimate is coarser than the table one. So `2b` is MEDIUM at `bloat_pct > 50` AND > 1 GB, LOW at > 100 MB, never HIGH on the estimate alone. Rebuild trigger is `pgstatindex().avg_leaf_density` low **and falling** across two samples. <https://www.cybertec-postgresql.com/en/should-i-rebuild-my-postgresql-index/>

## Vacuum / xacts

**30 min open transaction → MEDIUM, 1 hour → HIGH.** xmin held that long blocks autovacuum on every row updated/deleted since the xact started. The single most common production incident is a forgotten psql session. pganalyze `idle_transaction` / `active_query` checks warn at 30 min and go critical at 60 min. postgres.ai (howto 0030) calls 30–60 **seconds** long on a heavily loaded OLTP system and recommends `statement_timeout` 15–30 s and `idle_in_transaction_session_timeout` 15–30 s with per-session overrides for migrations and dumps. Marvin's default tiers are audit-safe for mixed workloads; tighten them when the operator says OLTP.

**`idle in transaction (aborted)` → CRITICAL.** An error fired inside an explicit transaction, the app caught it and didn't `ROLLBACK`. Holds locks + xmin forever until the connection dies. Set `idle_in_transaction_session_timeout = '60s'` cluster-wide.

**Autovacuum urgency (`3b2`) replaces "top 25 by `n_dead_tup`" for severity.** Raw dead-tuple counts penalise big tables. Cybertec's autovacuum monitor divides by the trigger autovacuum actually computes: `threshold + scale_factor × reltuples`, per-table reloptions first, and on PG18 capped by `autovacuum_vacuum_max_threshold` (default 100 M, so a 1 B-row table at scale factor 0.2 triggers at 100 M dead tuples, not 200 M). `urgency > 1` = due and waiting (queue); `> 5` = starved. Same for `analyze_urgency` (`n_mod_since_analyze`) — stale planner stats are the silent cause of plan flips in `5d`. Not modelled: PG18 multiplies the insert trigger by `(1 - relallfrozen / relpages)`. <https://www.cybertec-postgresql.com/en/monitor-autovacuum-my-queries/> · <https://www.postgresql.org/docs/18/runtime-config-vacuum.html>

**Partitioned parents are never analyzed by autovacuum (`3e`).** Docs, routine vacuuming: "autovacuum does not run ANALYZE on partitioned tables". Parent-level stats exist only after a manual `ANALYZE parent`. With none, cross-partition joins and aggregates are planned from nothing. PG18 makes `VACUUM`/`ANALYZE` on the parent recurse by default (`ONLY` opts out). <https://www.postgresql.org/docs/18/routine-vacuuming.html>

**Autovacuum cost budget (`3c-capacity`, `3c-progress`).** `autovacuum_vacuum_cost_limit` (default -1 → `vacuum_cost_limit` 200) with 2 ms delay is roughly 80 MB/s of cache hits or 8 MB/s of reads, shared across all workers. Adding workers without raising the limit slows each one. `index_vacuum_count > 1` in `pg_stat_progress_vacuum` means the dead-TID store filled and every index was scanned again — raise `autovacuum_work_mem` (PG17 TID store makes this rarer). PG18 `total_autovacuum_time` (`3f`) shows which tables eat the budget. <https://pganalyze.com/docs/checks/vacuum/inefficient_index_phase>

**pg_stat_statements eviction (`5-2`).** `pg_stat_statements_info.dealloc` counts times the hash table hit `pg_stat_statements.max` and evicted the least-executed entries. Any top-N after that is a ranking of survivors. pganalyze: ~100 deallocs / 10 min is concerning. Default `max` 5000; 10000 is a normal starting point (restart). <https://www.postgresql.org/docs/current/pgstatstatements.html>

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

**80% of app capacity → investigate, 90% → HIGH (`8f`).** Capacity is `max_connections - superuser_reserved_connections - reserved_connections` (PG16), not raw `max_connections`. Each connection is a heavyweight process with per-backend memory cost. At 90% one workload spike triggers `FATAL: sorry, too many clients already`.

**`max_connections > 300` → MEDIUM regardless of usage** (Percona PMM advisor). `max_connections` is rarely the right knob — overhead is fixed per backend even when idle. Use **PgBouncer in transaction mode** (or similar pooler) to multiplex thousands of client connections over a small pool of real backends. Caveats: breaks `LISTEN/NOTIFY`, session-level `SET`, plain prepared statements (pgbouncer 1.21+ with `max_prepared_statements` handles the last). Azure sizes 2–5 × vCores. <https://docs.percona.com/percona-monitoring-and-management/3/advisors/checks/configuration-pg-high-max-connections.html>

**Idle in transaction by duration (`8g`).** pganalyze: warn 30 min, critical 60 min. `application_name = ''` on many rows means nobody set it and 4b / 5j cannot attribute load — recommend fixing at the client.

## Unused indexes

**100 MB total → flag.** Cost isn't just disk — every write updates the index. 100 MB unused on a high-write table is meaningful write amplification.

**Confidence gate: stats age ≥ 30 days AND every replica checked.** pganalyze `index_unused` needs 35 days of data; postgres.ai says one month and to check each standby, because `idx_scan` is per instance — an index only read by reporting queries on a replica shows 0 on the primary. Below the gate, downgrade one severity tier and say "no scans in N days" rather than "unused". <https://pganalyze.com/docs/checks/schema/index_unused> · <https://postgres.ai/docs/postgres-howtos/performance-optimization/indexing/how-to-find-unused-indexes>

**FK-supporting indexes are excluded (`6a`).** `pg_constraint.conindid` on a FOREIGN KEY row points at the *referenced* table's unique index, so the usual "not constraint-backing" filter still lets the referencing-side index through. Those indexes serve cascade `DELETE`/`UPDATE` from the parent and rarely register scans; dropping one recreates finding `6d`. `6a` matches leading key columns against `conkey` (same logic as `6d`) and skips them.

**`last_idx_scan` (PG16+) beats `idx_scan = 0`.** Timestamp survives stats resets, lets you say "last used 187 days ago" rather than guessing. Use both: `idx_scan = 0` AND `last_idx_scan IS NULL OR last_idx_scan < now() - interval '...' `.

**PG18 skip scan does not relax `6c`.** Skip scan lets `(a, b)` serve `WHERE b = ?` when `a` has few distinct values (docs, indexes-multicolumn). That is the reverse direction of the prefix rule — `(a)` is still fully covered by `(a, b)`. Do not tell users a single-column index has become redundant with a composite led by another column, and do not drop `(b)` in favour of `(a, b)` on hot OLTP paths unless `pg_stats.n_distinct` for `a` is small. <https://www.postgresql.org/docs/18/indexes-multicolumn.html>

## Replica identity / missing PK

Source: `06-index-health.sql` block `6f` — `pg_class.relreplident` + `pg_index.indisprimary`.

A heap table with `relreplident = 'n'` (NOTHING), or `'d'` (default) and no primary key, has no usable replica identity. Two concrete failures:

- **Logical replication**: `UPDATE`/`DELETE` on it raises `cannot update table ... it does not have a replica identity and publishes updates`. Silent until the first mutation replicates.
- **`pg_repack`**: refuses the table (`ERROR: table ... must have a primary key or not-null unique keys`). Your bloat remediation stops at the tables that need it most.

`'f'` (FULL) works for logical replication but uses the whole row as the key — every `UPDATE`/`DELETE` scans the subscriber with no index. MEDIUM, not HIGH: correct, just slow. Fix is add a PK or a `NOT NULL` unique index, then `ALTER TABLE ... REPLICA IDENTITY USING INDEX`.

Partitions are excluded — identity is declared on the partitioned parent, not each partition.

## Partition candidates

Source: `05-workload-hotspots.sql` block `5l`. LOW / informational. A > 50 GB non-partitioned heap is a *candidate*, not a defect — partitioning pays off for time-series (drop old partitions instead of mass `DELETE` + bloat) and for per-partition autovacuum tuning. It costs a migration and adds partition-pruning risk if queries don't carry the partition key. Never auto-flag as actionable; surface the size + `n_tup_del` and let the operator judge.

## Checkpoints

Source: `05-workload-hotspots.sql` block `5k` — `req_pct` (PG16 `pg_stat_bgwriter`, PG17 `pg_stat_checkpointer`).

`req_pct > 30%` (`checkpoints_req / (checkpoints_req + checkpoints_timed)`, or PG17 `num_requested / (num_requested + num_timed)`) → workload is pushing past `max_wal_size` between scheduled checkpoints. Fix is almost always **raise `max_wal_size`** (default 1 GB; 8–16 GB is routine on modern disks). Downside: longer crash recovery.

Only meaningful against `stats_reset` age — a checkpointer counter reset an hour ago produces a noisy ratio. Cite `stats_age` from the same row.

**`checkpoint_timeout` is the other half (`8b`).** Percona: production runs 30 min routinely; short checkpoints inflate full-page images (`5b3` `fpi_pct_of_records`) because every first touch of a page after a checkpoint writes the whole page. Raise `checkpoint_timeout` together with `max_wal_size`; `wal_compression` is the last resort, not the first. PG18 `pg_stat_checkpointer.num_done` counts checkpoints actually performed (requested ones can be skipped). <https://www.percona.com/blog/importance-of-tuning-checkpoint-in-postgresql/>

**`wal_buffers_full` (`5b3`).** `pg_stat_wal.wal_buffers_full` increments each time a backend had to write WAL itself because the buffer was full. Non-zero and growing → raise `wal_buffers` (default -1 = 1/32 of `shared_buffers`, capped 16 MB; restart). PG18 adds the same counter per statement in `pg_stat_statements`.

## Replication slots

**`safe_wal_size` NULL means unbounded, not fine (`1b`).** It is NULL when `max_slot_wal_keep_size = -1`, the default. A consumer that stops acknowledging then retains WAL until the disk is full. MEDIUM whenever any slot exists with the default; the fix is a finite `max_slot_wal_keep_size` (slot goes `lost` instead of the server going read-only) plus PG18 `idle_replication_slot_timeout`. `inactive_since` (PG17) and `invalidation_reason` say how long nobody consumed and whether the server already gave up. Logical slots pin `catalog_xmin` even when `xmin` is NULL — catalog bloat with no `pg_stat_activity` trace. <https://www.postgresql.org/docs/current/view-pg-replication-slots.html>

## Replication

**Bytes, not intervals.** `pg_stat_replication.write_lag` / `flush_lag` / `replay_lag` go NULL when the primary is idle (docs), and `now() - pg_last_xact_replay_timestamp()` on a standby inflates for the same reason. Alert on `pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)`. pganalyze `high_lag`: warn 100 MB, critical 1 GB averaged over an hour.

**Where in the pipeline.** `sent` lag = primary CPU or network; `write` = standby receive; `flush` = standby disk; `replay >> flush` = apply blocked, usually a recovery conflict (`7g` `confl_snapshot` / `confl_lock`) or a slow standby. postgres.ai howto 0093. <https://www.cybertec-postgresql.com/en/streaming-replication-conflicts-in-postgresql/>

**`hot_standby_feedback` is a trade, not a setting to recommend.** On: the standby's oldest snapshot pins xmin on the primary (`7a` `backend_xmin`, `7c`) → bloat travels upstream. Off (default): standby queries older than `max_standby_streaming_delay` (30 s) are cancelled. State both sides. <https://www.cybertec-postgresql.com/en/what-hot_standby_feedback-in-postgresql-really-does/>

**Combined xmin horizon (`7c`).** Four holders, one number: `pg_stat_activity.backend_xmin`, `pg_replication_slots.xmin` / `catalog_xmin`, `pg_stat_replication.backend_xmin`, `pg_prepared_xacts`. The oldest is what vacuum waits on. pganalyze warns at 24 h. <https://github.com/postgres-ai/postgres-howtos/blob/main/0045_how_to_monitor_xmin_horizon.md>

**Logical.** `pg_stat_subscription` with no row for an enabled subscription = the apply worker is dead. `pg_stat_replication_slots.spill_bytes` growing = `logical_decoding_work_mem` (64 MB default) too small. PG18 `confl_*` counters on `pg_stat_subscription_stats` expose rows skipped or errored on apply. <https://www.postgresql.org/docs/current/logical-replication-monitoring.html>

## Config sanity (`8b`)

Rules and sources; compiled defaults from `pg_settings.boot_val`.

| GUC | Rule | Source |
|---|---|---|
| `fsync = off` | CRITICAL | pganalyze fsync check |
| `track_counts` / `track_activities = off` | HIGH — autovacuum and `pg_stat_*` are blind | pganalyze stats check |
| `jit = on` on OLTP | MEDIUM — planning overhead on short queries; every major cloud ships off; PG19 flips the default | Cybertec |
| `random_page_cost = 4` on SSD | MEDIUM — planner under-prices index scans; ~1.1 is the SSD norm | Cybertec "Better PostgreSQL performance on SSDs" |
| `statement_timeout` / `lock_timeout` / `idle_in_transaction_session_timeout = 0` | MEDIUM on OLTP — no cluster-wide backstop | postgres.ai howto 0030 |
| `checkpoint_timeout = 300` + `req_pct > 30` | MEDIUM | Percona |
| `log_checkpoints` / `log_lock_waits = off`, `log_autovacuum_min_duration = -1`, `log_temp_files = -1` | LOW — no evidence trail when it matters | Depesz, GitLab, Percona baselines |
| `huge_pages_status = off` (PG17+) with `shared_buffers > 8 GB` | LOW — TLB pressure, higher per-connection memory | PG docs kernel-resources |
| `data_checksums = off` | LOW — cannot be enabled online before PG19; PG18 initdb defaults on | PG docs |
| `effective_io_concurrency = 1` on PG18 | LOW — pinned old advice disables AIO read-ahead (default is now 16) | PG18 release notes, pganalyze AIO post |
| `wal_compression = off` on write-heavy | LOW — lz4/zstd cut FPI volume | PG docs runtime-config-wal |
| `pending_restart = true` | MEDIUM — configured ≠ running | PG docs view-pg-settings |

`shared_buffers` and `work_mem` need RAM, which SQL cannot see. pganalyze's rules of thumb: `shared_buffers` 25% of RAM up to 32 GB then fixed 8 GB; `work_mem` ≈ `shared_buffers / max_connections` clamped 1 MB–256 MB (`8d` prints that number). postgres.ai: budget `work_mem` as available RAM / `max_connections` / 4–5 because hash nodes get `hash_mem_multiplier` × `work_mem`. <https://pganalyze.com/docs/checks/settings/work_mem>

## pg_stat_database counters (`8e`)

`deadlocks > 0` since `stats_reset` → MEDIUM and name the tables from the log. `checksum_failures > 0` → CRITICAL, storage is returning bad pages. `temp_files` / `temp_bytes` → the cluster-wide version of `5c`. `xact_rollback / (commit + rollback) > 10%` → an application error loop (GitLab alerts on rollback rate). `sessions_abandoned` → clients disconnecting mid-query, usually pooler or LB timeouts. `idle_in_transaction_time` is cumulative ms — divide by uptime for a feel.

## Sequences (`8h`)

Two percentages: the sequence's own `last_value / max_value`, and `last_value` against the **owning column's** type maximum. A `bigint` sequence feeding an `integer` column overflows at 2,147,483,647 with `seq_pct` still ~0 (Crunchy, "The integer at the end of the universe"). postgres.ai flags at 10% used; > 50% MEDIUM, > 80% HIGH. The fix is `ALTER COLUMN TYPE bigint`, a full rewrite under `AccessExclusiveLock` with an FK web to follow — budget it early. <https://www.crunchydata.com/blog/the-integer-at-the-end-of-the-universe-integer-overflow-in-postgres>

## Lock table (`8i`)

Capacity = `max_locks_per_transaction × (max_connections + max_prepared_transactions)` (docs). A query on a parent with N partitions takes N+ relation locks per backend; many backends × many partitions exhausts the shared lock table with `out of shared memory` / `You might need to increase max_locks_per_transaction`. Docs also say a standby's value must be ≥ the primary's. <https://www.postgresql.org/docs/current/runtime-config-locks.html>

## Severity tiers

- **CRITICAL** = can-take-the-DB-offline. Halt audit, surface immediately.
- **HIGH** = fix this sprint. Real disk, real throughput, real value bleeding.
- **MEDIUM** = how DBs drift. None urgent, all compound.
- **LOW** = skippable. Real but not action items.

## Workload overrides

| Workload | Override |
|---|---|
| Append-only / analytical | bloat thresholds tighter (5–10% concerning); `autovacuum_vacuum_insert_scale_factor` 0.2 default too coarse for index-only scans — Cybertec suggests per-table 0.005 on big insert-only tables |
| Heavy update on hot rows | bloat thresholds looser (40% can be steady state) |
| OLTP, high TPS | long-transaction tiers in minutes not hours (postgres.ai: 30–60 s is long); cluster-wide `statement_timeout` + `idle_in_transaction_session_timeout` expected; `jit = on` is a finding |
| `pg_stat_statements` off | skip Phase 5; note in report |
| OLAP / warehouse | cache hit ratio meaningless; per-query index ratios matter |
| Per-tenant schemas | sample or filter — N tenants × per-table queries blows up |

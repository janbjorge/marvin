# Remediation Playbook

Every remediation here is presented in the same shape: **what it does**, **the lock it acquires**, **typical duration**, **failure modes**, and **the exact statement(s)**. Always confirm with the user before executing. Never batch confirmations.

For all remediations, **on a primary** unless explicitly noted. Most of these will fail or be no-ops on a replica.

## Bloat remediation

### A. Standard `VACUUM`

Reclaims dead-tuple space within existing pages, marks them reusable. Does NOT shrink the file.

**Lock:** `ShareUpdateExclusiveLock` — concurrent reads, writes, and DDL using the same lock level are blocked, but normal SELECT/INSERT/UPDATE/DELETE proceed.
**Duration:** seconds to hours, proportional to table size + dead tuples.
**Cost:** I/O proportional to scanned pages; controlled by `vacuum_cost_limit`/`vacuum_cost_delay`.
**Failure modes:** can be canceled by user; will yield to incoming `ACCESS EXCLUSIVE` lock requests.

```sql
VACUUM (VERBOSE, ANALYZE) public.events;
```

Watch progress (PG9.6+):
```sql
SELECT * FROM pg_stat_progress_vacuum;
```

### B. `VACUUM (FREEZE)` for wraparound

Aggressively freezes tuples to advance `relfrozenxid`. Use when wraparound risk is high.

**Lock:** `ShareUpdateExclusiveLock` (same as standard).
**Duration:** longer than standard — scans more pages.

```sql
VACUUM (FREEZE, VERBOSE, ANALYZE) public.events;
```

Don't do this preemptively across the whole database during peak hours — it creates I/O. For wraparound fire drills, target the largest tables with oldest `relfrozenxid` first.

### C. `pg_repack` — online table rewrite

Reclaims space AND returns it to the OS. Online — uses triggers + a side table to capture changes during the rebuild, then briefly takes `AccessExclusiveLock` only for the swap.

**Lock:** brief `AccessExclusiveLock` at the end (typically < 1s).
**Duration:** longer than `VACUUM FULL` because it's online — sometimes hours for very large tables.
**Cost:** requires 2× the table's size in free disk space during the rebuild.
**Failure modes:** if the table has no PK or unique-not-null constraint, it can't operate. Aborts cleanly if interrupted.

```bash
# pg_repack runs as a CLI, not a SQL command:
pg_repack -h HOST -d DB -t public.events --no-superuser-check
pg_repack -h HOST -d DB -i public.events_user_idx     # specific index
```

Install: `CREATE EXTENSION pg_repack;` in the target database, plus the OS package providing the CLI. https://github.com/reorg/pg_repack

### D. `VACUUM FULL` — last resort

Rewrites the table from scratch into a new file, then swaps. Reclaims all space. **NOT online.**

**Lock:** `AccessExclusiveLock` for the entire duration. All reads and writes blocked.
**Duration:** depends on size; assume "outage of length X" where X = (size in MB / write throughput in MB/s).
**Cost:** 2× table size in free disk space.

```sql
-- Only with confirmed maintenance window
VACUUM FULL public.events;
```

Prefer `pg_repack` whenever the extension is installable. The only legitimate cases for `VACUUM FULL` are: small tables where the lock duration is acceptable; `pg_repack` extension cannot be installed (rare); recovering from a `pg_repack` failure that left state behind.

### E. `CLUSTER` — rewrite + sort by index

Same lock characteristics as `VACUUM FULL`, but reorders rows by an index. Useful when query patterns benefit from physical ordering (e.g., range scans on a frequently-filtered column).

```sql
CLUSTER public.events USING events_created_at_idx;
```

Same caveats as `VACUUM FULL` — `pg_repack` can do this online: `pg_repack -t public.events -o created_at -h ...`

## Index remediation

### F. Build a missing index online

```sql
CREATE INDEX CONCURRENTLY CONCURRENTLY events_user_id_idx ON public.events (user_id);
```

**Lock:** `ShareUpdateExclusiveLock` on the table; allows reads and writes throughout.
**Duration:** can be long; proportional to table size.
**Failure modes:** any failure leaves an `INVALID` index that consumes disk and is updated by writes but ignored by the planner. Always check after:

```sql
SELECT indexrelid::regclass, indrelid::regclass
FROM pg_index WHERE NOT indisvalid;
```

To rebuild a failed concurrent index: drop it (`DROP INDEX CONCURRENTLY` is fine), then re-run.

### G. Drop an unused index online

```sql
DROP INDEX CONCURRENTLY public.events_legacy_status_idx;
```

**Lock:** `ShareUpdateExclusiveLock` briefly (much shorter than create).
**Duration:** seconds to minutes.

If the index turns out to have been needed, recreate it with `CREATE INDEX CONCURRENTLY`. Watch query latency in pg_stat_statements for the next few hours after dropping a sizable index.

### H. Rebuild a bloated index online (PG12+)

```sql
REINDEX INDEX CONCURRENTLY public.events_user_id_idx;
```

**Lock:** `ShareUpdateExclusiveLock`. Online.
**Duration:** similar to `CREATE INDEX CONCURRENTLY`.
**Failure modes:** like CREATE CONCURRENTLY; may leave INVALID. Same recovery.

```sql
-- Whole-table reindex
REINDEX TABLE CONCURRENTLY public.events;
-- Whole-database reindex (use with care; locks one index at a time but iterates a lot)
REINDEX DATABASE CONCURRENTLY my_db;
```

### I. Add a constraint to a large table without long lock

The trick is `NOT VALID` then `VALIDATE`:

```sql
-- Step 1: add constraint as NOT VALID — brief AccessExclusive on ADD,
--         applies only to NEW rows
ALTER TABLE public.events
  ADD CONSTRAINT events_user_id_fk
  FOREIGN KEY (user_id) REFERENCES public.users (id)
  NOT VALID;

-- Step 2: validate existing rows — ShareUpdateExclusive, online
ALTER TABLE public.events VALIDATE CONSTRAINT events_user_id_fk;
```

The same pattern works for CHECK constraints. Without this dance, `ALTER TABLE ADD CONSTRAINT` would scan the entire table under `AccessExclusiveLock`.

## Vacuum-cause remediation

### J. Terminating a long-running transaction

**This is destructive.** The application may not handle it gracefully.

```sql
-- Cancel the current query (lighter touch — transaction may continue if app retries)
SELECT pg_cancel_backend(18472);

-- Terminate the entire backend (closes the connection)
SELECT pg_terminate_backend(18472);
```

Before running, capture the context:
```sql
SELECT pid, usename, application_name, client_addr,
       state, now() - xact_start AS xact_age,
       backend_xmin,
       left(query, 500) AS query
FROM pg_stat_activity WHERE pid = 18472;
```

Always confirm with the operator running the workload. A "long-running transaction" might be a critical migration or a deliberate analytics job.

### K. Configuring `idle_in_transaction_session_timeout`

Cluster-wide:
```sql
ALTER SYSTEM SET idle_in_transaction_session_timeout = '60s';
SELECT pg_reload_conf();
```

Per-database / per-role:
```sql
ALTER DATABASE prod SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE app_user SET idle_in_transaction_session_timeout = '60s';
```

This automatically cancels backends that sit in `idle in transaction` longer than the timeout, releasing their xmin and locks. The application sees a closed connection on its next attempted query, which the connection pool should handle.

## Configuration changes

### L. Reload-only (no restart)

Most GUCs can be changed with `ALTER SYSTEM` + `pg_reload_conf()`:

```sql
ALTER SYSTEM SET log_lock_waits = on;
ALTER SYSTEM SET log_min_duration_statement = '1000ms';
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
ALTER SYSTEM SET autovacuum_vacuum_scale_factor = 0.05;
SELECT pg_reload_conf();
```

After reload, verify:
```sql
SELECT name, setting, source, pending_restart
FROM pg_settings
WHERE name IN ('log_lock_waits','random_page_cost', /* etc */);
```

### M. Restart-required

`shared_buffers`, `max_connections`, `max_wal_senders`, `shared_preload_libraries`, etc. require a restart. `ALTER SYSTEM` will set `pending_restart = true` until the next restart:

```sql
ALTER SYSTEM SET shared_buffers = '8GB';
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements,auto_explain';
-- Coordinate restart with the team
```

Schedule with the operator. On managed services (RDS, Cloud SQL), this maps to a parameter-group change and an instance reboot.

### N. Per-table autovacuum tuning

For high-churn tables, override the global scale factors:

```sql
ALTER TABLE public.events SET (
  autovacuum_vacuum_scale_factor = 0.02,         -- vacuum at 2% dead instead of 20%
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_cost_limit = 2000            -- give it more I/O budget
);

-- Verify
SELECT reloptions FROM pg_class WHERE oid = 'public.events'::regclass;

-- Remove
ALTER TABLE public.events RESET (
  autovacuum_vacuum_scale_factor,
  autovacuum_analyze_scale_factor,
  autovacuum_vacuum_cost_limit
);
```

## Replication slot remediation

### O. Drop an inactive slot

**This will break the replica or logical consumer using that slot.** Verify nothing legitimate depends on it.

```sql
-- Identify
SELECT slot_name, plugin, slot_type, active, active_pid,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots
WHERE NOT active;

-- Drop
SELECT pg_drop_replication_slot('slot_name_to_drop');
```

After dropping, monitor disk free space — WAL retention pressure should drop within a few minutes (next checkpoint).

## Sequence and TOAST remediation

### P. TOAST compression switch (PG14+)

For wide-text/JSONB tables on the default PGLZ:

```sql
-- One column at a time; takes ShareUpdateExclusive briefly,
-- but only applies to NEW values until rewritten
ALTER TABLE public.events
  ALTER COLUMN payload SET COMPRESSION lz4;

-- To recompress existing values, rewrite the table:
VACUUM FULL public.events;       -- not online; or use pg_repack
```

LZ4 is ~3× faster than PGLZ on writes, decompresses ~5× faster, and gives slightly worse ratio (~5–10% less compression). For most workloads, the throughput win outweighs the ratio loss.

### Q. Sequence approaching max value (rare but real)

```sql
-- Detect
SELECT s.seqrelid::regclass AS sequence_name,
       seq.seqmax AS max_val,
       (SELECT last_value FROM pg_sequences ps
        WHERE ps.sequencename = c.relname AND ps.schemaname = ns.nspname) AS current_val,
       round(100.0 *
         (SELECT last_value FROM pg_sequences ps
          WHERE ps.sequencename = c.relname AND ps.schemaname = ns.nspname)::numeric
         / seqmax::numeric, 2) AS pct_used
FROM pg_sequence seq
JOIN pg_class c ON c.oid = seq.seqrelid
JOIN pg_namespace ns ON ns.oid = c.relnamespace
ORDER BY pct_used DESC NULLS LAST
LIMIT 10;
```

If a SERIAL (int4) is at 85% of its 2.1B ceiling, the migration is to `BIGINT`. There is no online-with-zero-downtime path for changing a column type referenced by FKs; budget a maintenance window or use a multi-step rename-and-cutover.

## What never to do without explicit signed-off plan

1. `DROP INDEX` (non-concurrent) on a large production table — locks the table.
2. `REINDEX TABLE` (non-concurrent) — locks the table.
3. `ALTER TABLE ... ADD COLUMN ... DEFAULT ...` with non-volatile default on PG10 or older — rewrites the table. (PG11+ handles this via `pg_attribute.atthasmissing`; safe.)
4. `ALTER TABLE ... ALTER COLUMN TYPE` with a type change requiring rewrite — locks for the duration.
5. `pg_terminate_backend` on autovacuum workers in anti-wraparound mode — they will be restarted immediately AND the database is closer to wraparound than before.
6. `VACUUM FULL` during business hours.
7. Any `ALTER SYSTEM` change to `shared_preload_libraries` followed by reload (not restart) — the change won't take effect; users assume it did.

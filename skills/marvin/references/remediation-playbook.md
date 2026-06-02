# Remediation playbook

Each entry: lock, duration, exact SQL. Run on a primary unless noted. Confirm with the user per statement; never batch.

## Bloat

| Action | Lock | Duration | Notes |
|---|---|---|---|
| `VACUUM (VERBOSE, ANALYZE) tbl` | `ShareUpdateExclusive` | seconds–hours | Marks pages reusable; does NOT shrink the file. Watch `pg_stat_progress_vacuum`. |
| `VACUUM (FREEZE, ...) tbl` | `ShareUpdateExclusive` | longer | For wraparound fire drills; target largest + oldest `relfrozenxid` first. |
| `pg_repack -t schema.tbl ...` | brief `AccessExclusive` at swap (< 1s) | sometimes hours | Online; needs 2× table size free disk. Requires PK or unique-not-null. Aborts cleanly on interrupt. |
| `VACUUM FULL tbl` | `AccessExclusive` for the duration | size / write-throughput | Last resort. Not online. 2× disk. |
| `CLUSTER tbl USING idx` | `AccessExclusive` for the duration | same | Same lock as FULL; reorders by index. `pg_repack -o col` does it online. |

`pg_repack` install: `CREATE EXTENSION pg_repack;` + OS package. <https://github.com/reorg/pg_repack>

## Indexes

```sql
CREATE INDEX CONCURRENTLY tbl_user_id_idx ON tbl (user_id);
DROP   INDEX CONCURRENTLY tbl_legacy_idx;
REINDEX INDEX CONCURRENTLY tbl_user_id_idx;     -- PG12+
REINDEX TABLE CONCURRENTLY tbl;
```

All take `ShareUpdateExclusive`; reads + writes proceed. Any failure leaves an `INVALID` index that still costs writes. Always re-check:

```sql
SELECT indexrelid::regclass, indrelid::regclass
FROM pg_index WHERE NOT indisvalid;
```

Recovery from a failed `CONCURRENTLY`: `DROP INDEX CONCURRENTLY` the invalid one, then re-run.

After dropping a sizable index, watch `pg_stat_statements` for the next few hours.

## Constraints on big tables — `NOT VALID` then `VALIDATE`

```sql
ALTER TABLE tbl
  ADD CONSTRAINT tbl_user_id_fk FOREIGN KEY (user_id) REFERENCES users(id)
  NOT VALID;                                     -- brief AccessExclusive
ALTER TABLE tbl VALIDATE CONSTRAINT tbl_user_id_fk;  -- ShareUpdateExclusive, online
```

Same pattern for CHECK constraints. Without it, `ADD CONSTRAINT` scans the table under `AccessExclusive`.

## Long-running transactions

Capture before killing:

```sql
SELECT pid, usename, application_name, client_addr, state,
       now() - xact_start AS xact_age, backend_xmin, left(query, 500) AS query
FROM pg_stat_activity WHERE pid = 18472;

SELECT pg_cancel_backend(18472);     -- cancel current query
SELECT pg_terminate_backend(18472);  -- close connection
```

Confirm with the operator owning the workload — long xacts can be legitimate migrations.

**Never** terminate autovacuum workers in anti-wraparound mode. They restart immediately and the DB is now closer to wraparound than before.

```sql
ALTER SYSTEM SET idle_in_transaction_session_timeout = '60s';
SELECT pg_reload_conf();
```

## Configuration

Most GUCs: `ALTER SYSTEM SET ...; SELECT pg_reload_conf();` — verify via `pg_settings.source` / `pending_restart`.

Restart-required: `shared_buffers`, `max_connections`, `max_wal_senders`, `shared_preload_libraries`. Setting them with `ALTER SYSTEM` flips `pending_restart = true` but doesn't take effect until restart — common footgun with `shared_preload_libraries`.

Per-table autovacuum:

```sql
ALTER TABLE tbl SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_cost_limit = 2000
);
-- inspect: SELECT reloptions FROM pg_class WHERE oid = 'tbl'::regclass;
-- reset:   ALTER TABLE tbl RESET (autovacuum_vacuum_scale_factor, ...);
```

## Replication slots

**Dropping breaks any consumer using the slot.** Verify nothing legitimate depends on it.

```sql
SELECT slot_name, plugin, slot_type, active, active_pid,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots WHERE NOT active;

SELECT pg_drop_replication_slot('slot_name');
```

WAL retention drops within a checkpoint or two.

## TOAST compression (PG14+)

```sql
ALTER TABLE tbl ALTER COLUMN payload SET COMPRESSION lz4;   -- only NEW values
-- To recompress existing values, rewrite: pg_repack or VACUUM FULL.
```

LZ4 ≈ 3× faster writes, ≈ 5× faster decompress, ~5–10% worse ratio than PGLZ.

## Sequences near max

If a SERIAL (int4) is at 85% of 2.1 B, you need BIGINT. There is no online-with-zero-downtime path through an FK web — budget a maintenance window or rename-and-cutover.

## Never without an explicit plan

- `DROP INDEX` / `REINDEX TABLE` (non-concurrent) on a production table.
- `ALTER TABLE ALTER COLUMN TYPE` requiring rewrite.
- `pg_terminate_backend` on anti-wraparound autovacuum.
- `VACUUM FULL` during business hours.
- `ALTER SYSTEM SET shared_preload_libraries = ...` followed by reload (must restart).

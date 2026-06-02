-- marvin: 04-locks-and-blocking.sql
-- Phase 4 — blocked queries and lock distribution.
-- Read-only.
--
-- Execution model: labelled query catalogue for the pglens `query` MCP tool.
-- pglens also exposes a specialized `blocking_locks` tool — prefer it when
-- available; the queries below are the equivalent raw SQL.


-- ============================================================================
-- 4a  Currently blocked queries.
-- A non-empty result is always at least MEDIUM; investigate the blocker
-- in 4b before suggesting any remediation.
-- ============================================================================
SELECT
  blocked.pid                      AS blocked_pid,
  blocked.usename                  AS blocked_user,
  blocked.application_name         AS blocked_app,
  now() - blocked.xact_start       AS waited,
  blocked.wait_event_type,
  blocked.wait_event,
  pg_blocking_pids(blocked.pid)    AS blocking_pids,
  left(blocked.query, 200)         AS blocked_query
FROM pg_stat_activity blocked
WHERE pg_blocking_pids(blocked.pid) <> '{}'
ORDER BY waited DESC NULLS LAST;


-- ============================================================================
-- 4b  The blockers (enriched).
-- ============================================================================
SELECT pid, usename, application_name, state,
       wait_event_type, wait_event,
       now() - xact_start  AS xact_age,
       now() - query_start AS query_age,
       backend_xmin,
       left(query, 200)    AS query
FROM pg_stat_activity
WHERE pid IN (
  SELECT DISTINCT unnest(pg_blocking_pids(pid))
  FROM pg_stat_activity
  WHERE pg_blocking_pids(pid) <> '{}'
);


-- ============================================================================
-- 4c  Lock distribution (look for unusual lock types).
-- AccessExclusiveLock outside DDL windows is suspicious.
-- ============================================================================
SELECT mode, locktype, count(*) AS held
FROM pg_locks
GROUP BY mode, locktype
ORDER BY count(*) DESC;

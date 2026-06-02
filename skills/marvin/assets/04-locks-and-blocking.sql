-- marvin: 04-locks-and-blocking.sql — Phase 4. Read-only.
-- pglens `blocking_locks` tool covers this; use the raw SQL when absent.

-- ============================================================================
-- 4a  Blocked queries. Non-empty → MEDIUM+. Investigate 4b before remediating.
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
-- 4b  Blockers (enriched).
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
-- 4c  Lock distribution. AccessExclusiveLock outside DDL window = suspicious.
-- ============================================================================
SELECT mode, locktype, count(*) AS held
FROM pg_locks
GROUP BY mode, locktype
ORDER BY count(*) DESC;

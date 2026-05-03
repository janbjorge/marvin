-- postgres-health-review: 04-locks-and-blocking.sql
-- Phase 4 — blocked queries and lock distribution.
-- Read-only.

\set QUIET on
\pset pager off

SET application_name = 'health-review';
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET default_transaction_read_only = on;

\echo
\echo '================================================================'
\echo ' PHASE 4a — Currently blocked queries'
\echo '================================================================'
\echo

SELECT
  blocked.pid AS blocked_pid,
  blocked.usename AS blocked_user,
  blocked.application_name AS blocked_app,
  now() - blocked.xact_start AS waited,
  blocked.wait_event_type, blocked.wait_event,
  pg_blocking_pids(blocked.pid) AS blocking_pids,
  left(blocked.query, 200) AS blocked_query
FROM pg_stat_activity blocked
WHERE pg_blocking_pids(blocked.pid) <> '{}'
ORDER BY waited DESC NULLS LAST;

\echo
\echo '================================================================'
\echo ' PHASE 4b — The blockers (enriched)'
\echo '================================================================'
\echo

SELECT pid, usename, application_name, state,
       wait_event_type, wait_event,
       now() - xact_start AS xact_age,
       now() - query_start AS query_age,
       backend_xmin,
       left(query, 200) AS query
FROM pg_stat_activity
WHERE pid IN (
  SELECT DISTINCT unnest(pg_blocking_pids(pid))
  FROM pg_stat_activity
  WHERE pg_blocking_pids(pid) <> '{}'
);

\echo
\echo '================================================================'
\echo ' PHASE 4c — Lock distribution (look for unusual lock types)'
\echo '================================================================'
\echo '   AccessExclusiveLock outside DDL windows is suspicious.'
\echo

SELECT mode, locktype, count(*) AS held
FROM pg_locks
GROUP BY mode, locktype
ORDER BY count(*) DESC;

\echo
\echo '-- Phase 4 complete --'

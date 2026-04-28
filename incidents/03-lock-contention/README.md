# Incident 03 — Lock Contention & Deadlock

## Symptoms
Customer reports a query has been running for several minutes
with no result. Application appears frozen on certain operations.
Other customers on shared infrastructure report slowdowns.

## Environment
- Database: PostgreSQL 18 + TimescaleDB
- Table: bloat_test (regular transactional table)
- Lock type: RowExclusiveLock (UPDATE conflict)

## Background — Why Locks Happen
PostgreSQL locks rows during UPDATE and DELETE to prevent
concurrent modifications corrupting data. If Transaction A
holds a lock and Transaction B wants the same rows, Transaction B
waits until A commits or rolls back. If A never commits
(e.g. a forgotten open transaction), B waits indefinitely.

## Diagnosis Steps

### Step 1 — Identify blocked and blocking sessions
```sql
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query,
    blocking.state AS blocking_state,
    now() - blocked.query_start AS blocked_duration
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.wait_event_type = 'Lock';
```

### Observations
- Blocked PID: 2816
- Blocking PID: 2794
- Blocked duration: 00:01:57.673961
- Blocking query state: idle in transaction

### Step 2 — Verify with pg_locks
```sql
SELECT locktype, relation::regclass, mode, granted, pid
FROM pg_locks
WHERE relation::regclass::text = 'bloat_test'
ORDER BY granted DESC;
```
- granted = true: 2794 holds the lock
- granted = false:2816 is waiting

## Root Cause
Session A began a transaction and updated rows but never committed.
This held RowExclusiveLocks on those rows indefinitely. Session B
attempted to update the same rows and entered an infinite wait state.

## Resolution
Identified the blocking PID using pg_blocking_pids() and terminated
the blocking session:
```sql
SELECT pg_terminate_backend(2794);
```
Result: Window B — UPDATE completed

## Deadlock Simulation
When two sessions hold locks each other needs, PostgreSQL 18
automatically detects the cycle and cancels one transaction:

```bash
ERROR:  deadlock detected
DETAIL:  Process 2816 waits for ShareLock on transaction 1802; blocked by process 3129.
Process 3129 waits for ShareLock on transaction 1803; blocked by process 2816.
```

One transaction is automatically rolled back — the other proceeds.

## Prevention
- Always commit or rollback transactions promptly
- Keep transactions as short as possible
- Use statement_timeout to auto-cancel long-running queries:
  SET statement_timeout = '30s';
- Use lock_timeout to fail fast instead of waiting indefinitely:
  SET lock_timeout = '5s';
- Monitor pg_stat_activity regularly for idle in transaction sessions

## Key Diagnostic Queries (Save These)
```sql
-- Find all blocked sessions and their blockers
SELECT blocked.pid, blocked.query, blocking.pid AS blocker,
       now() - blocked.query_start AS waiting_for
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.wait_event_type = 'Lock';

-- Terminate a blocking session safely
SELECT pg_terminate_backend([Blocking PID]);
```
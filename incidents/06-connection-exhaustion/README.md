# Incident 06 — Connection Pool Exhaustion

## Symptoms
Application throws errors: "FATAL: sorry, too many clients already"
New database connections are completely refused.
Application is down — no queries can execute.
Dashboard and APIs return 500 errors or timeouts.

## Environment
- Database: PostgreSQL 18 + TimescaleDB
- max_connections setting: 100
- Connections at time of incident: 12

## Background — How PostgreSQL Manages Connections
Each PostgreSQL connection is a real OS process consuming RAM
(typically 5–10MB each). When connections reach max_connections,
PostgreSQL refuses all new connection attempts immediately.
Applications that open connections without closing them — connection
leaks — are the most common cause of this incident.

## Diagnosis Steps

### Step 1 — Check total connections and state breakdown
```sql
SELECT state, COUNT(*) AS connection_count,
       MAX(now() - backend_start) AS longest_connection
FROM pg_stat_activity
GROUP BY state
ORDER BY connection_count DESC;
```

### Observations
- Total connections at incident: 31
- max_connections limit: 20
- Idle connections (leaked): 19
- Remaining slots available: -11

### Step 2 — Identify leaked connections
```sql
SELECT pid, usename, application_name, state,
       now() - backend_start AS connection_age
FROM pg_stat_activity
WHERE state = 'idle'
ORDER BY backend_start;
```
Finding: 19 connections sitting idle — never returned
to a pool or closed by the application.

### Step 3 — Check error in PostgreSQL logs

```
FATAL: sorry, too many clients already
```
## Root Cause
Application code opened database connections in a loop without
closing them — a classic connection leak pattern. Each connection
remained open consuming a slot until max_connections was reached
and all new connection attempts were refused.

## Resolution

### Step 1 — Immediate fix: terminate idle leaked connections
```sql
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND usename = 'postgres'
  AND pid <> pg_backend_pid();
```
Result: 21 connections terminated, service restored

### Step 2 — Root cause fix: implement connection pooling
Replace raw connections with a connection pool:
```python
from psycopg2 import pool

connection_pool = psycopg2.pool.ThreadedConnectionPool(
    minconn=2,
    maxconn=5,
    host="localhost", port=****,
    database="********",
    user="postgres", password="**********"
)

conn = connection_pool.getconn()
try:
    # use connection
finally:
    connection_pool.putconn(conn)
```
Result: 15 concurrent threads served using only 5 connections.

## Prevention
- Always use a connection pool — never open raw connections in loops
- Set connection_limit on specific database users:
  ALTER USER appuser CONNECTION LIMIT 10;
- Set statement_timeout and idle_in_transaction_session_timeout:
  SET idle_in_transaction_session_timeout = '5min';
- Monitor pg_stat_activity.state for 'idle' accumulation regularly
- Consider PgBouncer for application-level connection pooling at scale

## Key Numbers

| Metric | Bad Script | Fixed Script |
|---|---|---|
| Connections opened | 19 | 5 (pooled) |
| Operations completed | Failed at 20 | 15 (all succeeded) |
| Error encountered | FATAL: too many clients | None |

## Key Diagnostic Queries
```sql
-- Full connection breakdown
SELECT state, COUNT(*), MAX(now() - backend_start) AS longest
FROM pg_stat_activity GROUP BY state;

-- Check remaining capacity
SELECT MAX(setting::INT) - COUNT(*) AS free_slots
FROM pg_stat_activity, pg_settings
WHERE name = 'max_connections' GROUP BY setting;

-- Emergency termination of idle connections
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE state = 'idle' AND pid <> pg_backend_pid();
```
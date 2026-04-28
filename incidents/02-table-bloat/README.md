# Incident 02 — Table Bloat & VACUUM

## Symptoms
Customer reports their database is consuming unexpected disk space.
Queries that were previously fast are gradually slowing down.
Table size keeps growing despite no significant new data being inserted.

## Environment
- Database: PostgreSQL 18 + TimescaleDB
- Table: bloat_test (100,000 rows — regular table)
- Root cause type: MVCC dead tuple accumulation

## Background — Why Dead Tuples Happen
PostgreSQL uses MVCC (Multi-Version Concurrency Control). When a row
is UPDATEd, PostgreSQL does NOT overwrite the old row. Instead it
marks the old version as dead and writes a new version. Dead tuples
accumulate until VACUUM cleans them up.

## Diagnosis Steps

### Step 1 — Check pg_stat_user_tables for dead tuples
```sql
SELECT relname, n_live_tup, n_dead_tup,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE relname = 'bloat_test';
```

### Observations BEFORE VACUUM
- Live tuples: 100000
- Dead tuples: 150188
- Dead tuple %: 60.03 %
- Table size: 25 MB

## Root Cause
100,000 rows were updated twice in rapid succession. Each UPDATE
created a dead tuple version of every row. PostgreSQL's autovacuum
had not yet run, so dead tuples accumulated causing table bloat.

## Resolution

### Step 1 — VACUUM ANALYZE (reclaim space for reuse)
```sql
VACUUM ANALYZE bloat_test;
```
Result: Dead tuples dropped from 150188 to 0

### Step 2 — VACUUM FULL (reclaim actual disk space)
```sql
VACUUM FULL ANALYZE bloat_test;
```
Result: Table size reduced from 25 MB to 10 MB

## Important — Hypertable VACUUM Behavior
order_events is a TimescaleDB hypertable partitioned into chunks.
VACUUM on a hypertable propagates to all child chunks automatically:
```sql
VACUUM ANALYZE order_events;
```
VACUUM FULL is NOT recommended on hypertables — TimescaleDB manages
chunk storage and compression independently. Use TimescaleDB's native
compression policies instead for long-term storage management on
hypertables (covered in Incident 04).

## Prevention
- Ensure autovacuum is enabled (it is by default)
- For high-UPDATE tables, tune autovacuum_vacuum_scale_factor lower
- Monitor pg_stat_user_tables.n_dead_tup regularly
- For hypertables — use TimescaleDB compression policies instead of
  relying solely on VACUUM for storage reclamation

## Key Numbers
| Metric | Before | After VACUUM | After VACUUM FULL |
|---|---|---|---|
| Dead tuples | 150188 | 0 | 0 |
| Table size | 25 MB | 25 MB | 10 MB |
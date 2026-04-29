# Incident 05 — Continuous Aggregate Lag

## Symptoms
Customer reports their analytics dashboard is showing stale or
missing data. Real-time metrics appear hours behind actual events.
Hourly revenue reports show zero rows for recent time periods.

## Environment
- Database: PostgreSQL 18 + TimescaleDB
- Table: order_events (hypertable, compression enabled)
- Aggregate: order_summary_hourly (1-hour buckets by region and status)

## Background — How Continuous Aggregates Work
A continuous aggregate is a pre-computed materialized view backed
by its own internal hypertable. TimescaleDB refreshes it on a
schedule. Between refreshes, new data in the source hypertable
is NOT reflected in the aggregate — this is intentional and
expected behaviour. The lag window is controlled by refresh policy
settings.

## Diagnosis Steps

### Step 1 — Check if the aggregate has any data
```sql
SELECT COUNT(*) FROM order_summary_hourly;
```
Result: 0

### Step 2 — Check for existing refresh jobs
```sql
SELECT job_id, application_name, schedule_interval,
       last_run_status, last_successful_finish
FROM timescaledb_information.jobs
WHERE application_name LIKE '%Continuous%';
```
Finding: No refresh policy was configured — aggregate was created
with no automated refresh schedule.

### Step 3 — Verify lag by comparing raw vs aggregate counts
- Raw order_events count: 205000
- Aggregate order_count sum: 200000
- Discrepancy: 5000 rows not yet reflected

## Version Note
In this TimescaleDB version, job run history is stored separately
in timescaledb_information.job_stats — not in the jobs view.
Always inspect view columns first:
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'timescaledb_information' AND table_name = 'jobs';

## Root Cause
The continuous aggregate was created without a refresh policy.
No automated refresh was ever scheduled, causing the materialized
view to remain permanently stale after initial creation.

## Resolution

### Step 1 — Manual full refresh (immediate fix)
```sql
CALL refresh_continuous_aggregate('order_summary_hourly', NULL, NULL);
```
Result: 204918 rows now visible in aggregate

### Step 2 — Targeted refresh for recent data only
```sql
CALL refresh_continuous_aggregate(
    'order_summary_hourly',
    NOW() - INTERVAL '3 days',
    NOW()
);
```
Use this in production to avoid refreshing full history every time.

### Step 3 — Add automated refresh policy (permanent fix)
```sql
SELECT add_continuous_aggregate_policy(
    'order_summary_hourly',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour'
);
```
Policy job ID: 1001

## Results After Fix

| Metric | Before | After |
|---|---|---|
| Aggregate row count | 200000 | 204918 |
| Raw vs aggregate match | No | Close Enough |
| Refresh policy | None | Every 1 hour |
| Lag window | Indefinite | Max 1 hour |

## Advanced — Aggregate Compression
Continuous aggregates can also be compressed for storage savings:
```sql
ALTER MATERIALIZED VIEW order_summary_hourly
SET (timescaledb.compress = true);

SELECT add_compression_policy('order_summary_hourly', INTERVAL '7 days');
```

## Prevention
Always create a refresh policy immediately after creating a
continuous aggregate:
```sql
SELECT add_continuous_aggregate_policy(
    'your_aggregate',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour'
);
```
Choose schedule_interval based on how fresh your dashboard data
needs to be. For real-time dashboards use shorter intervals.
For daily reports, hourly or daily refresh is sufficient.

## Key Diagnostic Queries
```sql
-- Check aggregate freshness
SELECT view_name, last_run_started_at, last_run_status
FROM timescaledb_information.jobs
WHERE application_name LIKE '%Continuous%';

-- Compare raw vs aggregate
SELECT COUNT(*) FROM order_events;
SELECT SUM(order_count) FROM order_summary_hourly;

-- Manual refresh for specific window
CALL refresh_continuous_aggregate('order_summary_hourly',
    NOW() - INTERVAL '3 days', NOW());
```

# PostgreSQL War Room
### A Database Troubleshooting Knowledge Base Built on PostgreSQL 18 + TimescaleDB

---

## What This Project Is

This is a hands-on incident simulation and documentation system
built to demonstrate real-world PostgreSQL and TimescaleDB support
engineering skills. Every incident was deliberately reproduced,
diagnosed using production-grade tools, resolved, and documented
as if explaining to a real customer.

This project covers the full support engineer stack - from query
optimization and TimescaleDB internals to connection pooling,
vector search, and backup/restore procedures.

---

## Environment

| Component | Version |
|---|---|
| PostgreSQL | 18 |
| TimescaleDB | 2.26.3 |
| pgvector | 0.8.1 |
| Docker | 4.70.0 |
| Python | 3.12.3 |
| OS | Windows |

---

## Database Architecture

### Core Tables

| Table | Type | Rows | Purpose |
|---|---|---|---|
| order_events | TimescaleDB Hypertable | ~145,000 | Primary time-series table - e-commerce order events |
| customers | Regular table | 500 | Customer reference data |
| products | Regular table | 100 | Product catalog |
| product_embeddings | Regular table + pgvector | 10,000 | AI vector embeddings for similarity search |
| order_events_archive | Regular table | varies | Archived cancelled/refunded orders |
| order_events_audit | Regular table | varies | Audit log for DELETE operations |
| bloat_test | Regular table | 100,000 | Dedicated table for bloat simulation |

### TimescaleDB Features Configured
- Hypertable on order_events (partitioned by event_time)
- Compression enabled (segmentby: region, orderby: event_time DESC)
- Compression policy: auto-compress chunks older than 30 days
- Continuous aggregate: order_summary_hourly
- Continuous aggregate refresh policy: every 1 hour

---

## How to Reproduce This Environment

### Prerequisites
- Docker Desktop installed and running
- Python 3.x installed
- PostgreSQL 18 client tools installed (for psql, pg_dump, pg_restore)

### Step 1 - Start TimescaleDB Container
```cmd
docker run -d --name timescale-warroom ^
  -e POSTGRES_PASSWORD=<password> ^
  -e POSTGRES_DB=warroom ^
  -p 5433:5432 ^
  timescale/timescaledb:latest-pg15
```

### Step 2 - Enable Extensions
```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS vector;
```

### Step 3 - Create Schema and Generate Data
```cmd
psql -h localhost -p 5433 -U postgres -d warroom -f setup\schema.sql
python setup\generate_data.py
```

### Step 4 - Verify Setup
```sql
SELECT hypertable_name, num_chunks
FROM timescaledb_information.hypertables;

SELECT COUNT(*) FROM order_events;
```

---

## Incident Index

| # | Incident | Category | Key Skills Demonstrated |
|---|---|---|---|
| [01](#incident-01---slow-query) | Slow Query - Missing Index | Query Optimization | EXPLAIN ANALYZE, composite indexing, Seq Scan vs Index Scan |
| [02](#incident-02---table-bloat) | Table Bloat & VACUUM | Maintenance | MVCC, pg_stat_user_tables, VACUUM vs VACUUM FULL |
| [03](#incident-03---lock-contention) | Lock Contention & Deadlock | Concurrency | pg_stat_activity, pg_locks, pg_blocking_pids, deadlock detection |
| [04](#incident-04---timescaledb-compression) | TimescaleDB Chunk Compression | TimescaleDB | compress_chunk, compression policies, storage savings measurement |
| [05](#incident-05---continuous-aggregate-lag) | Continuous Aggregate Lag | TimescaleDB | refresh_continuous_aggregate, aggregate policies, lag diagnosis |
| [06](#incident-06---connection-exhaustion) | Connection Pool Exhaustion | Infrastructure | pg_stat_activity, pg_terminate_backend, psycopg2 connection pooling |
| [07](#incident-07---pgvector-ai-query-slowdown) | pgvector AI Query Slowdown | AI / pgvector | IVFFlat index, HNSW index, cosine similarity, hybrid SQL+vector search |
| [08](#incident-08---backup--restore) | Backup, Restore & Migration | Operations | pg_dump, pg_restore, partial restore, TimescaleDB restore procedure |

---

## [Incident 01 - Slow Query](incidents/01-slow-query)
**Category:** Query Optimization

**Symptom:** Customer reports a filtered aggregation query is timing out on their dashboard.

**Root Cause:** No index on `status` and `region` columns - PostgreSQL performed a full sequential scan of `150,000` rows.

**Resolution:** Created composite index `idx_status_region ON order_events(status, region)`

**Result:** Execution time improved from 87.994 ms to 17.796 ms - ~ 5x faster. Scan type changed from Seq Scan to Index Scan.

[View full incident →](incidents/01-slow-query/README.md)

---

## [Incident 02 - Table Bloat](incidents/02-table-bloat)
**Category:** Maintenance

**Symptom:** Customer reports database consuming unexpected disk space despite no new data.

**Root Cause:** Mass UPDATE operations generated 150188 dead tuples via PostgreSQL MVCC. Autovacuum had not yet run.

**Resolution:** VACUUM ANALYZE reduced dead tuples from 150188 to 0. VACUUM FULL reclaimed actual disk space from 25 MB to 10 MB.

**TimescaleDB Note:** VACUUM FULL not recommended on hypertables - TimescaleDB compression policies handle storage reclamation more efficiently.

[View full incident →](incidents/02-table-bloat/README.md)

---

## [Incident 03 - Lock Contention](incidents/03-lock-contention)
**Category:** Concurrency

**Symptom:** Customer reports query has been running for several minutes with no result.

**Root Cause:** Session A held a RowExclusiveLock on rows via an uncommitted transaction. Session B waited indefinitely for the same rows.

**Resolution:** Identified blocking PID using `pg_blocking_pids()`. Terminated blocking session with `pg_terminate_backend()`. Also simulated and documented PostgreSQL 18's automatic deadlock detection.

[View full incident →](incidents/03-lock-contention/README.md)

---

## [Incident 04 - TimescaleDB Compression](incidents/04-compression)
**Category:** TimescaleDB

**Symptom:** Customer reports storage costs growing month over month with no end in sight.

**Root Cause:** No compression policy configured. All 53 historical chunks stored in full uncompressed row format.

**Resolution:** Enabled compression with `compress_segmentby = 'region'`, compressed 53 historical chunks, added automated 30-day compression policy.

**Result:** Total storage reduced from 48 MB to 20 MB - average 60 % savings per chunk.

[View full incident →](incidents/04-compression/README.md)

---

## [Incident 05 - Continuous Aggregate Lag](incidents/05-continuous-aggregate)
**Category:** TimescaleDB

**Symptom:** Customer reports analytics dashboard showing stale or missing data.

**Root Cause:** Continuous aggregate `order_summary_hourly` was created without a refresh policy - it had never been refreshed since creation.

**Resolution:** Manual full refresh via `CALL refresh_continuous_aggregate()`. Added automated hourly refresh policy with 3-day lookback window.

[View full incident →](incidents/05-continuous-aggregate/README.md)

---

## [Incident 06 - Connection Exhaustion](incidents/06-connection-exhaustion)
**Category:** Infrastructure

**Symptom:** Application throwing `FATAL: sorry, too many clients already`. All new connections refused.

**Root Cause:** Application code opened 31 connections in a loop without closing them - classic connection leak pattern.

**Resolution:** Terminated 19 idle leaked connections via `pg_terminate_backend()`. Fixed application code with `psycopg2.pool.ThreadedConnectionPool` - 15 operations now served by 5 pooled connections.

[View full incident →](incidents/06-connection-exhaustion/README.md)

---

## [Incident 07 - pgvector AI Query Slowdown](incidents/07-pgvector)
**Category:** AI / pgvector

**Symptom:** AI-powered product recommendation feature degrading as catalog grows. Similarity search queries timing out.

**Root Cause:** No vector index on 10,000-row embeddings table. pgvector performing exact exhaustive search - O(n) complexity.

**Resolution:** Benchmarked IVFFlat vs HNSW indexes on 128-dimensional vectors.

| Method | Execution Time |
|---|---|
| No index | 17.265 ms |
| IVFFlat (lists=100, probes=10) | 5.860 ms |
| HNSW (m=16, ef_construction=64) | 1.344 ms |

[View full incident →](incidents/07-pgvector/README.md)

---

## [Incident 08 - Backup & Restore](incidents/08-backup-restore)
**Category:** Operations

**Symptom:** Customer needs to recover a dropped table from last known backup.

**Key Learning:** Standard pg_restore on TimescaleDB hypertables produces FK constraint errors (`ONLY option not supported`) that cause chunk data to not be loaded - tables appear with 0 rows despite chunks existing.

**Correct TimescaleDB Restore Procedure:**
1. Enable TimescaleDB extension before restoring
2. Restore schema and data separately
3. Use `--data-only --disable-triggers` for data restore
4. Manually recreate FK constraints without `ONLY` keyword
5. Always verify row counts after restore

[View full incident →](incidents/08-backup-restore/README.md)

---

## [SQL Showcase](sql-showcase)

8 complex analytical queries demonstrating advanced SQL on a
TimescaleDB hypertable - window functions, CTEs, recursive
queries, and query optimization with EXPLAIN ANALYZE.

| Query | Technique | Execution Time |
|---|---|---|
| Revenue ranking per region | RANK() OVER PARTITION BY | 553.154 ms |
| Month-over-month growth | LAG() window function | 103.562 ms |
| Running revenue total | SUM() OVER with frame | 61.952 ms |
| Customer tier segmentation | NTILE(4) | 78.586 ms |
| Order gap analysis | LAG() per customer partition | 63.517 ms |
| Top products per region | Multi-level CTE | 106.462 ms |
| Statistical anomaly detection | CROSS JOIN CTE + z-score | 125.264 ms |
| Customer order sequence | Recursive CTE | 62126.697 ms |

[View SQL showcase →](sql-showcase/README.md)

---

## [PL/pgSQL Objects](plpgsql)

| Object | Type | Purpose |
|---|---|---|
| detect_anomalous_orders() | Function | Flags orders beyond z-score threshold |
| get_monthly_summary() | Function | Returns formatted monthly revenue by region |
| archive_old_orders() | Procedure | Archives old cancelled/refunded orders chunk-by-chunk |
| trg_audit_order_deletion | Trigger | Captures every DELETE into audit log |

[View PL/pgSQL documentation →](plpgsql/README.md)

---

## Key Diagnostic Queries Quick Reference

```sql
-- Find blocked sessions and their blockers
SELECT blocked.pid, blocked.query, blocking.pid AS blocker
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.wait_event_type = 'Lock';

-- Check connection usage vs limit
SELECT MAX(setting::INT) - COUNT(*) AS free_slots
FROM pg_stat_activity, pg_settings
WHERE name = 'max_connections' GROUP BY setting;

-- Check TimescaleDB chunk compression status
SELECT chunk_name, is_compressed,
       pg_size_pretty(before_compression_total_bytes) AS before,
       pg_size_pretty(after_compression_total_bytes) AS after
FROM chunk_compression_stats('order_events');

-- Check continuous aggregate freshness
SELECT view_name, last_run_status, last_successful_finish
FROM timescaledb_information.jobs
WHERE application_name LIKE '%Continuous%';

-- Find slow queries via pg_stat_statements
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```

---

## What This Project Demonstrates

- Deep PostgreSQL internals knowledge - MVCC, execution plans,
  locking, connection management
- TimescaleDB expertise - hypertables, compression, continuous
  aggregates, chunk management
- Full stack debugging mindset - from query plans to application
  code to backup procedures
- AI/ML database capability - pgvector, IVFFlat, HNSW indexes,
  hybrid SQL + vector search
- Support engineer communication - every incident documented as
  if explaining to a real customer
- Real troubleshooting experience - actual errors encountered,
  diagnosed, and resolved during build

# Incident 04 — Chunk Overload & TimescaleDB Compression

## Symptoms
Customer reports database storage growing rapidly. Historical data
queries are slower than expected. Storage costs on cloud platform
are increasing month over month with no end in sight.

## Environment
- Database: PostgreSQL 18 + TimescaleDB
- Table: order_events (hypertable, 200,000+ rows across multiple chunks)
- Problem type: Uncompressed historical data accumulation

## Background — How TimescaleDB Chunks Work
TimescaleDB partitions hypertables into time-based chunks. Each chunk
is a real PostgreSQL table under the hood. Without compression, every
chunk stores data in full row format — identical to a regular table.
As data grows, uncompressed chunks consume increasing storage.

## Diagnosis Steps

### Step 1 — Inspect chunk count and sizes
```sql
SELECT chunk_name, range_start, range_end, is_compressed,
       pg_size_pretty(pg_total_relation_size(
           format('%I.%I', chunk_schema, chunk_name)::regclass)) AS size
FROM timescaledb_information.chunks
WHERE hypertable_name = 'order_events'
ORDER BY range_start;
```

### Observations Before Compression
- Total chunks: 53
- Total uncompressed size: 48 MB
- All chunks is_compressed: false

## Root Cause
No compression policy was configured. All historical chunks retained
full uncompressed row storage indefinitely, causing continuous
storage growth with no automated reclamation.

## Resolution

### Step 1 — Enable compression with optimal settings
```sql
ALTER TABLE order_events SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'region',
    timescaledb.compress_orderby = 'event_time DESC'
);
```
compress_segmentby chosen as 'region' because most queries filter by
region — this keeps compressed data queryable at speed.

### Step 2 — Compress historical chunks
```sql
SELECT compress_chunk(c.chunk_schema || '.' || c.chunk_name)
FROM timescaledb_information.chunks c
WHERE c.hypertable_name = 'order_events'
  AND c.range_end < NOW() - INTERVAL '30 days'
  AND c.is_compressed = false;
```
Chunks compressed: 53

### Step 3 — Add automated compression policy
```sql
SELECT add_compression_policy('order_events', INTERVAL '30 days');
```
Future chunks older than 30 days will compress automatically.

## Results After Compression

| Metric | Before | After |
|---|---|---|
| Total size | 48 MB | 20 MB |
| Compressed chunks | 0 | 53 |
| Average savings per chunk | — | 60 % |

## Important — Compressed Data Remains Queryable
TimescaleDB decompresses data transparently at query time.
No application changes are required after enabling compression.
Queries on compressed historical data remain accurate and performant.

## Prevention
Always configure a compression policy immediately after creating
a hypertable in production:
```sql
SELECT add_compression_policy('your_table', INTERVAL '7 days');
```
Choose compress_segmentby based on your most common WHERE clause columns.

## Key Commands Reference
```sql
-- Check compression status per chunk
SELECT chunk_name, is_compressed,
       pg_size_pretty(before_compression_total_bytes) AS before,
       pg_size_pretty(after_compression_total_bytes) AS after
FROM chunk_compression_stats('order_events');

-- Manually compress a single chunk
SELECT compress_chunk('_timescaledb_internal._hyper_X_Y_chunk');

-- View active compression policies
SELECT * FROM timescaledb_information.jobs
WHERE proc_name = 'policy_compression';
```
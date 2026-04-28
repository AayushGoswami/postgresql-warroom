\# Incident 01 — Slow Query (Missing Index)



\## Symptoms

Customer reports a query filtering orders by status and region

is taking several seconds to return results. Dashboard is timing out.



\## Environment

\- Database: PostgreSQL 15 + TimescaleDB

\- Table: order\_events (150,000 rows, hypertable)

\- Query type: Filtered aggregation with GROUP BY



\## Diagnosis Steps



\### Step 1 — Run EXPLAIN ANALYZE on the reported query

```sql

EXPLAIN ANALYZE

SELECT customer\_id, region, COUNT(\*), SUM(total\_amount), AVG(total\_amount)

FROM order\_events

WHERE status = 'completed' AND region = 'North'

GROUP BY customer\_id, region

ORDER BY SUM(total\_amount) DESC;

```



\### Step 2 — Observations from execution plan (BEFORE)

\- Scan type: Seq Scan

\- Planning time: 9.663 ms

\- Execution time: 87.994 ms



\### Step 3 — Checked scan ratio

\- Total rows in table: 150,000

\- Rows matching the filter: 7430

\- Efficiency: PostgreSQL scanned ALL rows to return only 7430 rows



\## Root Cause

No index existed on the `status` and `region` columns. PostgreSQL

performed a full sequential scan of all 150,000 rows to find

matching records — extremely inefficient for selective filter queries.



\## Resolution

Created a composite index covering both filter columns:

```sql

CREATE INDEX idx\_status\_region ON order\_events(status, region);

```

A composite index was chosen over two separate indexes because

the query always filters on both columns together.



\### Results After Fix (AFTER)

\- Scan type: Bitmap Heap Scan

\- Planning time: 7.489 ms

\- Execution time: 17.796 ms

\- Performance improvement: 4x faster



\## Prevention

\- Always analyse query patterns before go-live

\- Add indexes on columns used in WHERE clauses with high selectivity

\- Use EXPLAIN ANALYZE during development, not after complaints arise

\- Monitor pg\_stat\_statements for slow queries proactively



\## Files

\- screenshots/before.png — execution plan before indexing

\- screenshots/after.png — execution plan after indexing


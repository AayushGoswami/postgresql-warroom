# SQL Showcase - Advanced Analytical Queries

## Overview

8 complex SQL queries demonstrating window functions, CTEs, recursive queries, and query optimization on a 200,000+ row TimescaleDB hypertable (order_events).

## Environment

* PostgreSQL 18 + TimescaleDB
* Primary table: order_events (hypertable, ~200,000 rows)
* Supporting tables: customers (500 rows), products (100 rows)

## Window Function Queries

### Query 1 - Revenue Ranking per Region (RANK)

Ranks monthly revenue per region using RANK() with PARTITION BY.

* Execution time before index: 553.154 ms
* Execution time after partial index on status='completed': 84.861 ms
* Improvement: **~ 6.5 x faster**

### Query 2 - Month-over-Month Change (LAG)

Calculates revenue growth rate between consecutive months.
Uses LAG() to access previous row values within ordered window.

* Execution time: 103.562 ms

### Query 3 - Running Total Revenue (SUM OVER)

Computes cumulative revenue per region across weeks.
Uses ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW frame.

* Execution time: 61.952 ms

### Query 4 - Customer Tier Segmentation (NTILE)

Segments customers into quartiles by lifetime value.

* Platinum customers (top 25%): 125
* Bronze customers (bottom 25%): 125

### Query 5 - Order Gap Analysis (LEAD/LAG)

Calculates days between consecutive orders per customer.
Useful for churn detection and re-engagement targeting.

* Execution time: 63.517 ms

## CTE Queries

### Query 6 - Top 3 Products per Region (Multi-level CTE)

Three chained CTEs: regional_sales → ranked_products → top_products.
Final result joined to products table for readable names.

* Execution time: 106.462 ms

### Query 7 - Statistical Anomaly Detection (CROSS JOIN CTE)

Flags orders more than 2 standard deviations above the mean.
Uses z-score formula across a CROSS JOIN with aggregate stats.

* Flagged orders found: 20
* Threshold (avg + 2*stddev): 6911.80

### Query 8 - Recursive Order Sequence (Recursive CTE)

Builds each customer's complete order history sequentially.
Most complex query - recursive CTE with ordered self-join.

* Execution time: 62126.697 ms -> **EXCESSIVELY HIGH** execution time 

The initial recursive CTE implementation used correlated subqueries inside the recursive term — causing exponential lookup growth on 200,000 rows and making the query non-terminating in practice.
Replaced with ROW_NUMBER() + SUM() OVER() window functions which produce identical results in milliseconds.

* New Execution time: 34.159 ms

* Improvement: **~ 1820 x faster**

**Lesson**: recursive CTEs are powerful but should only be used when the data is genuinely
hierarchical (e.g. org charts, category trees). Sequential order analysis is better served by window functions.



## Key Takeaway

Window functions and CTEs allow complex analytical questions to be answered in a single readable SQL statement without application-level processing - critical for dashboard and reporting workloads on TimescaleDB.
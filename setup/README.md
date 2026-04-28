# Setup — Schema Design



## Why This Schema

This e-commerce order events database was designed to simulate

real-world time-series workloads similar to what Tiger Data

customers run on TimescaleDB.



## Tables



### customers

Holds 500 customers across 7 countries.

Used to simulate multi-region support scenarios.



### products

100 products across 6 categories with varying prices.

Used for join-heavy analytical queries.



### order_events (Hypertable)

Core time-series table — 150,000 events spanning 1 full year.

Partitioned by event_time into chunks by TimescaleDB.

This is the primary table for all incident simulations.



## Design Decisions

- order_events uses TIMESTAMPTZ (timezone-aware) — best practice for time-series

- Hypertable chunk interval defaults to 7 days — appropriate for this data volume

- Indexes on status, region, customer_id added for selective query testing



## Row Counts

- customers: 500

- products: 100

- order_events: 150,000


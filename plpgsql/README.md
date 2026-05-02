# PL/pgSQL — Functions, Procedures & Triggers

## Overview
Three PL/pgSQL objects built on the order_events hypertable
demonstrating real-world database automation patterns.

## Environment
- PostgreSQL 18 + TimescaleDB
- Primary table: order_events (hypertable, ~200,000 rows)

---

## [Function 1 — detect_anomalous_orders()](./functions.sql#L2-L62)

### Purpose
Identifies statistically anomalous orders using z-score analysis.
Accepts optional region filter and configurable threshold.

### Signature
```sql
SELECT * FROM detect_anomalous_orders(
    p_region TEXT DEFAULT NULL,
    p_z_score_threshold NUMERIC DEFAULT 2.0
);
```

### Test Results
- All regions, threshold 2.0: 5169 anomalous orders found
- North region only: 1014 found
- Threshold 3.0 (stricter): 629 found
- Highest z-score observed: 3.37
- Severity breakdown: 629 CRITICAL, 4540 HIGH


### Edge Cases Tested
- Non-existent region: Returns empty with NOTICE — correct behaviour
- Threshold 10.0: Returns 0 rows — correct behaviour

---

## [Function 2 — get_monthly_summary()](./functions.sql#L65-L116)

### Purpose
Returns pre-formatted revenue summary for any given month
broken down by region. Includes NULL-safe handling for
months with no data.

### Signature
```sql
SELECT * FROM get_monthly_summary(p_year INT, p_month INT);
```

### Test Results
- June 2024: North led with 69667.92
- January 2024: No data found for 2024-1
- Empty month (2020-01): NOTICE fired correctly, zero rows returned

---

## [Procedure — archive_old_orders()](./functions.sql#L119-L184)

### Purpose
Safely archives old cancelled and refunded orders to a
separate archive table. Built-in dry run mode prevents
accidental data movement.

### Signature
```sql
CALL archive_old_orders(
    p_cutoff_days INT DEFAULT 180,
    p_dry_run BOOLEAN DEFAULT TRUE
);
```

### Results
- Eligible rows for archiving (180 days): 57532
- Rows moved to order_events_archive: 57532
- Rows remaining in order_events: 147468
- Dry run tested first: Yes

### Design Decisions
- Dry run mode defaults to TRUE — prevents accidental execution
- COMMIT inside procedure — atomic operation, no partial moves
- Only cancelled and refunded statuses archived — completed orders
  retained in main table for active reporting

---

## [Trigger — trg_audit_order_deletion](./functions.sql#L187-L245)

### Purpose
Automatically captures every DELETE on order_events into
an audit log. Records who deleted what and when.

### Behaviour
- Fires BEFORE DELETE on order_events (all chunks)
- Captures: operation, timestamp, user, full original row data
- TimescaleDB note: trigger applies across all hypertable chunks
  automatically — no per-chunk trigger management needed

### Test Results
- DELETE of 1951 rows triggered 1951 audit entries
- Audit table correctly captured: event_id, customer_id,
  total_amount, status, region, deleted_by, deleted_at

### Audit Table Query
```sql
SELECT audit_id, operation, deleted_at, deleted_by,
       original_status, original_region, original_total_amount
FROM order_events_audit
ORDER BY deleted_at DESC;
```

---

## Known Issue — Tuple Decompression Limit

When running archive_old_orders() on a compressed hypertable,
the following error may occur if eligible rows exceed 100,000:

    ERROR: tuple decompression limit exceeded by operation
    DETAIL: current limit: 100000, tuples decompressed: 116856
    HINT: Consider increasing timescaledb.max_tuples_decompressed_per_dml_transaction

### Root Cause
TimescaleDB enforces a default limit of 100,000 decompressed
tuples per DML transaction to protect against memory pressure.
Bulk DELETEs on compressed hypertables trigger this when the
row count exceeds the limit.

### Fix Applied
```sql
SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
```
0 means unlimited — no decompression cap.
---

## [Complete Object Inventory](./functions.sql#L247-L262)

### Functions
- detect_anomalous_orders(text, numeric) → SETOF record
- get_monthly_summary(int, int) → SETOF record

### Procedures
- archive_old_orders(int, boolean) → void

### Triggers
- trg_audit_order_deletion on order_events (BEFORE DELETE)

---

## Key PL/pgSQL Patterns Used
- RETURNS TABLE for structured output
- DECLARE block for local variables
- GET DIAGNOSTICS for row counts after DML
- RAISE NOTICE for operational logging
- DEFAULT parameter values for flexible APIs
- Edge case handling with early RETURN
- TG_OP and OLD in trigger functions


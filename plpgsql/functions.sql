/*
Function 1: Anomaly Detection
This function flags orders that are statistically anomalous
*/

CREATE OR REPLACE FUNCTION detect_anomalous_orders(
    p_region TEXT DEFAULT NULL,
    p_z_score_threshold NUMERIC DEFAULT 2.0
)
RETURNS TABLE (
    event_time      TIMESTAMPTZ,
    customer_id     INT,
    region          TEXT,
    total_amount    NUMERIC,
    z_score         NUMERIC,
    severity        TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_avg    NUMERIC;
    v_stddev NUMERIC;
BEGIN
    SELECT
        AVG(o.total_amount),
        STDDEV(o.total_amount)
    INTO v_avg, v_stddev
    FROM order_events o
    WHERE o.status = 'completed'
      AND (p_region IS NULL OR o.region = p_region);

    IF v_stddev IS NULL OR v_stddev = 0 THEN
        RAISE NOTICE 'Insufficient data to calculate standard deviation';
        RETURN;
    END IF;

    RAISE NOTICE 'Mean: %, StdDev: %, Threshold: % z-score', 
        ROUND(v_avg, 2), ROUND(v_stddev, 2), p_z_score_threshold;

    RETURN QUERY
    SELECT
        o.event_time,
        o.customer_id,
        o.region,
        ROUND(o.total_amount::NUMERIC, 2),
        ROUND(
            (o.total_amount - v_avg) / v_stddev,
        2) AS z_score,
        CASE
            WHEN (o.total_amount - v_avg) / v_stddev >= 3 THEN 'CRITICAL'
            WHEN (o.total_amount - v_avg) / v_stddev >= 2 THEN 'HIGH'
            ELSE 'MEDIUM'
        END AS severity
    FROM order_events o
    WHERE o.status = 'completed'
      AND (p_region IS NULL OR o.region = p_region)
      AND ABS((o.total_amount - v_avg) / v_stddev) >= p_z_score_threshold
    ORDER BY z_score DESC;
END;
$$;

/*----------------------------------------------------------------------------------------------*/

/*
Function 2: Monthly Revenue Summary
A clean reporting function that returns a formatted revenue summary for any given month.
*/

CREATE OR REPLACE FUNCTION get_monthly_summary(
    p_year  INT,
    p_month INT
)
RETURNS TABLE (
    region          TEXT,
    total_orders    BIGINT,
    completed_orders BIGINT,
    total_revenue   NUMERIC,
    avg_order_value NUMERIC,
    top_status      TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start TIMESTAMPTZ;
    v_end   TIMESTAMPTZ;
BEGIN
    v_start := MAKE_TIMESTAMPTZ(p_year, p_month, 1, 0, 0, 0, 'UTC');
    v_end   := v_start + INTERVAL '1 month';

    IF NOT EXISTS (
        SELECT 1 FROM order_events
        WHERE event_time >= v_start AND event_time < v_end
    ) THEN
        RAISE NOTICE 'No data found for %-%', p_year, p_month;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        o.region,
        COUNT(*) AS total_orders,
        COUNT(*) FILTER (WHERE o.status = 'completed') AS completed_orders,
        ROUND(SUM(o.total_amount) FILTER (
            WHERE o.status = 'completed')::NUMERIC, 2) AS total_revenue,
        ROUND(AVG(o.total_amount) FILTER (
            WHERE o.status = 'completed')::NUMERIC, 2) AS avg_order_value,
        MODE() WITHIN GROUP (ORDER BY o.status) AS top_status
    FROM order_events o
    WHERE o.event_time >= v_start
      AND o.event_time < v_end
    GROUP BY o.region
    ORDER BY total_revenue DESC NULLS LAST;
END;
$$;

/*--------------------------------------------------------------------------------------------*/

/*
Procedure: Archive Old Orders
A stored procedure that moves old cancelled/refunded orders into an archive table — a real maintenance operation customers request
*/

/*Create the Archive Table First*/

CREATE TABLE IF NOT EXISTS order_events_archive (
    LIKE order_events INCLUDING ALL
);

/* Create the Archiving Procedure*/

CREATE OR REPLACE PROCEDURE archive_old_orders(
    p_cutoff_days   INT DEFAULT 180,
    p_dry_run       BOOLEAN DEFAULT TRUE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_cutoff_date   TIMESTAMPTZ;
    v_row_count     INT := 0;
    v_archive_count INT := 0;
BEGIN
    v_cutoff_date := NOW() - (p_cutoff_days || ' days')::INTERVAL;

    RAISE NOTICE 'Archive procedure started';
    RAISE NOTICE 'Cutoff date: %', v_cutoff_date;
    RAISE NOTICE 'Dry run mode: %', p_dry_run;

    SELECT COUNT(*) INTO v_row_count
    FROM order_events
    WHERE event_time < v_cutoff_date
      AND status IN ('cancelled', 'refunded');

    RAISE NOTICE 'Rows eligible for archiving: %', v_row_count;

    IF v_row_count = 0 THEN
        RAISE NOTICE 'Nothing to archive. Exiting.';
        RETURN;
    END IF;

    IF p_dry_run THEN
        RAISE NOTICE 'DRY RUN — no data moved. Re-run with p_dry_run => FALSE to execute.';
        RETURN;
    END IF;

    INSERT INTO order_events_archive
    SELECT * FROM order_events
    WHERE event_time < v_cutoff_date
      AND status IN ('cancelled', 'refunded');

    GET DIAGNOSTICS v_archive_count = ROW_COUNT;
    RAISE NOTICE 'Rows inserted into archive: %', v_archive_count;

    DELETE FROM order_events
    WHERE event_time < v_cutoff_date
      AND status IN ('cancelled', 'refunded');

    RAISE NOTICE 'Rows deleted from main table: %', v_archive_count;

    COMMIT;
    RAISE NOTICE 'Archive procedure completed successfully.';
END;
$$;

/*-----------------------------------------------------------------------------------------------*/

/*
Trigger: Audit Log for DELETE Operations
A trigger that automatically records every DELETE on order_events into an audit table — critical for compliance and debugging
*/

/*First Create the table order_events_audit*/

CREATE TABLE IF NOT EXISTS order_events_audit (
    audit_id        BIGSERIAL PRIMARY KEY,
    operation       TEXT NOT NULL,
    deleted_at      TIMESTAMPTZ DEFAULT NOW(),
    deleted_by      TEXT DEFAULT CURRENT_USER,
    original_event_id BIGINT,
    original_event_time TIMESTAMPTZ,
    original_customer_id INT,
    original_total_amount NUMERIC,
    original_status TEXT,
    original_region TEXT
);

/*Create the Trigger Function*/

CREATE OR REPLACE FUNCTION log_order_deletion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO order_events_audit (
        operation,
        deleted_at,
        deleted_by,
        original_event_id,
        original_event_time,
        original_customer_id,
        original_total_amount,
        original_status,
        original_region
    ) VALUES (
        TG_OP,
        NOW(),
        CURRENT_USER,
        OLD.event_id,
        OLD.event_time,
        OLD.customer_id,
        OLD.total_amount,
        OLD.status,
        OLD.region
    );
    RETURN OLD;
END;
$$;

/*Attach the Trigger*/

CREATE TRIGGER trg_audit_order_deletion
BEFORE DELETE ON order_events
FOR EACH ROW
EXECUTE FUNCTION log_order_deletion();

/*-------------------------------------------------------------------------------------------*/

/* List All Your PL/pgSQL Objects */


SELECT
    routine_name,
    routine_type,
    data_type AS return_type
FROM information_schema.routines
WHERE routine_schema = 'public'
ORDER BY routine_type, routine_name;

SELECT trigger_name, event_object_table, action_timing, event_manipulation
FROM information_schema.triggers
WHERE trigger_schema = 'public';

/*-------------------------------------------------------------------------------------------*/
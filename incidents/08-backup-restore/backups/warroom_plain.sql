--
-- PostgreSQL database dump
--

\restrict yCS8lF1NjtLULEsalWj4z3z9YAwWuNa5NymYq9lW6rAVdnNr7rTaoFsygJETITK

-- Dumped from database version 18.3
-- Dumped by pg_dump version 18.3

-- Started on 2026-05-03 12:52:16

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 4 (class 3079 OID 18051)
-- Name: timescaledb; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS timescaledb WITH SCHEMA public;


--
-- TOC entry 6810 (class 0 OID 0)
-- Dependencies: 4
-- Name: EXTENSION timescaledb; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION timescaledb IS 'Enables scalable inserts and complex queries for time-series data (Community Edition)';


--
-- TOC entry 2 (class 3079 OID 18897)
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- TOC entry 6811 (class 0 OID 0)
-- Dependencies: 2
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_stat_statements IS 'track planning and execution statistics of all SQL statements executed';


--
-- TOC entry 3 (class 3079 OID 32151)
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- TOC entry 6812 (class 0 OID 0)
-- Dependencies: 3
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- TOC entry 896 (class 1255 OID 32008)
-- Name: archive_old_orders(integer, boolean); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.archive_old_orders(IN p_cutoff_days integer DEFAULT 180, IN p_dry_run boolean DEFAULT true)
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
        RAISE NOTICE 'DRY RUN - no data moved. Re-run with p_dry_run => FALSE to execute.';
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


ALTER PROCEDURE public.archive_old_orders(IN p_cutoff_days integer, IN p_dry_run boolean) OWNER TO postgres;

--
-- TOC entry 609 (class 1255 OID 31986)
-- Name: detect_anomalous_orders(text, numeric); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.detect_anomalous_orders(p_region text DEFAULT NULL::text, p_z_score_threshold numeric DEFAULT 2.0) RETURNS TABLE(event_time timestamp with time zone, customer_id integer, region text, total_amount numeric, z_score numeric, severity text)
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


ALTER FUNCTION public.detect_anomalous_orders(p_region text, p_z_score_threshold numeric) OWNER TO postgres;

--
-- TOC entry 719 (class 1255 OID 31987)
-- Name: get_monthly_summary(integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_monthly_summary(p_year integer, p_month integer) RETURNS TABLE(region text, total_orders bigint, completed_orders bigint, total_revenue numeric, avg_order_value numeric, top_status text)
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


ALTER FUNCTION public.get_monthly_summary(p_year integer, p_month integer) OWNER TO postgres;

--
-- TOC entry 619 (class 1255 OID 32022)
-- Name: log_order_deletion(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_order_deletion() RETURNS trigger
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


ALTER FUNCTION public.log_order_deletion() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 410 (class 1259 OID 25210)
-- Name: _compressed_hypertable_2; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._compressed_hypertable_2 (
);


ALTER TABLE _timescaledb_internal._compressed_hypertable_2 OWNER TO postgres;

--
-- TOC entry 526 (class 1259 OID 30685)
-- Name: _compressed_hypertable_4; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._compressed_hypertable_4 (
);


ALTER TABLE _timescaledb_internal._compressed_hypertable_4 OWNER TO postgres;

--
-- TOC entry 302 (class 1259 OID 18973)
-- Name: order_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_events (
    event_id bigint NOT NULL,
    event_time timestamp with time zone DEFAULT now() NOT NULL,
    customer_id integer,
    product_id integer,
    quantity integer NOT NULL,
    total_amount numeric(10,2) NOT NULL,
    status text NOT NULL,
    region text NOT NULL
);


ALTER TABLE public.order_events OWNER TO postgres;

--
-- TOC entry 514 (class 1259 OID 30575)
-- Name: _direct_view_3; Type: VIEW; Schema: _timescaledb_internal; Owner: postgres
--

CREATE VIEW _timescaledb_internal._direct_view_3 AS
 SELECT public.time_bucket('01:00:00'::interval, event_time) AS bucket,
    region,
    status,
    count(*) AS order_count,
    sum(total_amount) AS total_revenue,
    avg(total_amount) AS avg_order_value,
    max(total_amount) AS max_order_value
   FROM public.order_events
  GROUP BY (public.time_bucket('01:00:00'::interval, event_time)), region, status;


ALTER VIEW _timescaledb_internal._direct_view_3 OWNER TO postgres;

--
-- TOC entry 358 (class 1259 OID 23700)
-- Name: _hyper_1_106_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_106_chunk (
    CONSTRAINT constraint_106 CHECK (((event_time >= '2025-04-17 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-04-24 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_106_chunk OWNER TO postgres;

--
-- TOC entry 359 (class 1259 OID 23729)
-- Name: _hyper_1_107_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_107_chunk (
    CONSTRAINT constraint_107 CHECK (((event_time >= '2024-06-20 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-06-27 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_107_chunk OWNER TO postgres;

--
-- TOC entry 360 (class 1259 OID 23758)
-- Name: _hyper_1_108_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_108_chunk (
    CONSTRAINT constraint_108 CHECK (((event_time >= '2024-07-04 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-07-11 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_108_chunk OWNER TO postgres;

--
-- TOC entry 361 (class 1259 OID 23787)
-- Name: _hyper_1_109_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_109_chunk (
    CONSTRAINT constraint_109 CHECK (((event_time >= '2024-11-21 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-11-28 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_109_chunk OWNER TO postgres;

--
-- TOC entry 312 (class 1259 OID 19225)
-- Name: _hyper_1_10_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_10_chunk (
    CONSTRAINT constraint_10 CHECK (((event_time >= '2025-07-17 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-07-24 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_10_chunk OWNER TO postgres;

--
-- TOC entry 362 (class 1259 OID 23816)
-- Name: _hyper_1_110_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_110_chunk (
    CONSTRAINT constraint_110 CHECK (((event_time >= '2024-07-11 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-07-18 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_110_chunk OWNER TO postgres;

--
-- TOC entry 363 (class 1259 OID 23845)
-- Name: _hyper_1_111_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_111_chunk (
    CONSTRAINT constraint_111 CHECK (((event_time >= '2025-01-16 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-01-23 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_111_chunk OWNER TO postgres;

--
-- TOC entry 364 (class 1259 OID 23874)
-- Name: _hyper_1_112_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_112_chunk (
    CONSTRAINT constraint_112 CHECK (((event_time >= '2024-10-17 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-10-24 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_112_chunk OWNER TO postgres;

--
-- TOC entry 365 (class 1259 OID 23903)
-- Name: _hyper_1_113_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_113_chunk (
    CONSTRAINT constraint_113 CHECK (((event_time >= '2025-02-27 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-03-06 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_113_chunk OWNER TO postgres;

--
-- TOC entry 366 (class 1259 OID 23932)
-- Name: _hyper_1_114_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_114_chunk (
    CONSTRAINT constraint_114 CHECK (((event_time >= '2024-11-28 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-12-05 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_114_chunk OWNER TO postgres;

--
-- TOC entry 367 (class 1259 OID 23961)
-- Name: _hyper_1_115_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_115_chunk (
    CONSTRAINT constraint_115 CHECK (((event_time >= '2025-01-09 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-01-16 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_115_chunk OWNER TO postgres;

--
-- TOC entry 368 (class 1259 OID 23990)
-- Name: _hyper_1_116_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_116_chunk (
    CONSTRAINT constraint_116 CHECK (((event_time >= '2025-04-03 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-04-10 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_116_chunk OWNER TO postgres;

--
-- TOC entry 369 (class 1259 OID 24019)
-- Name: _hyper_1_117_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_117_chunk (
    CONSTRAINT constraint_117 CHECK (((event_time >= '2024-08-15 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-08-22 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_117_chunk OWNER TO postgres;

--
-- TOC entry 370 (class 1259 OID 24048)
-- Name: _hyper_1_118_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_118_chunk (
    CONSTRAINT constraint_118 CHECK (((event_time >= '2024-08-01 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-08-08 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_118_chunk OWNER TO postgres;

--
-- TOC entry 371 (class 1259 OID 24077)
-- Name: _hyper_1_119_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_119_chunk (
    CONSTRAINT constraint_119 CHECK (((event_time >= '2025-01-02 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-01-09 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_119_chunk OWNER TO postgres;

--
-- TOC entry 313 (class 1259 OID 19250)
-- Name: _hyper_1_11_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_11_chunk (
    CONSTRAINT constraint_11 CHECK (((event_time >= '2025-07-03 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-07-10 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_11_chunk OWNER TO postgres;

--
-- TOC entry 372 (class 1259 OID 24106)
-- Name: _hyper_1_120_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_120_chunk (
    CONSTRAINT constraint_120 CHECK (((event_time >= '2024-10-10 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-10-17 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_120_chunk OWNER TO postgres;

--
-- TOC entry 373 (class 1259 OID 24135)
-- Name: _hyper_1_121_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_121_chunk (
    CONSTRAINT constraint_121 CHECK (((event_time >= '2024-05-23 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-05-30 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_121_chunk OWNER TO postgres;

--
-- TOC entry 374 (class 1259 OID 24164)
-- Name: _hyper_1_122_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_122_chunk (
    CONSTRAINT constraint_122 CHECK (((event_time >= '2025-01-30 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-02-06 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_122_chunk OWNER TO postgres;

--
-- TOC entry 375 (class 1259 OID 24193)
-- Name: _hyper_1_123_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_123_chunk (
    CONSTRAINT constraint_123 CHECK (((event_time >= '2025-02-06 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-02-13 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_123_chunk OWNER TO postgres;

--
-- TOC entry 376 (class 1259 OID 24222)
-- Name: _hyper_1_124_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_124_chunk (
    CONSTRAINT constraint_124 CHECK (((event_time >= '2024-09-05 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-09-12 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_124_chunk OWNER TO postgres;

--
-- TOC entry 377 (class 1259 OID 24251)
-- Name: _hyper_1_125_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_125_chunk (
    CONSTRAINT constraint_125 CHECK (((event_time >= '2024-06-27 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-07-04 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_125_chunk OWNER TO postgres;

--
-- TOC entry 378 (class 1259 OID 24280)
-- Name: _hyper_1_126_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_126_chunk (
    CONSTRAINT constraint_126 CHECK (((event_time >= '2025-03-27 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-04-03 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_126_chunk OWNER TO postgres;

--
-- TOC entry 379 (class 1259 OID 24309)
-- Name: _hyper_1_127_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_127_chunk (
    CONSTRAINT constraint_127 CHECK (((event_time >= '2025-03-20 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-03-27 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_127_chunk OWNER TO postgres;

--
-- TOC entry 380 (class 1259 OID 24338)
-- Name: _hyper_1_128_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_128_chunk (
    CONSTRAINT constraint_128 CHECK (((event_time >= '2024-06-13 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-06-20 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_128_chunk OWNER TO postgres;

--
-- TOC entry 381 (class 1259 OID 24367)
-- Name: _hyper_1_129_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_129_chunk (
    CONSTRAINT constraint_129 CHECK (((event_time >= '2024-12-26 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-01-02 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_129_chunk OWNER TO postgres;

--
-- TOC entry 314 (class 1259 OID 19275)
-- Name: _hyper_1_12_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_12_chunk (
    CONSTRAINT constraint_12 CHECK (((event_time >= '2026-01-29 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-02-05 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_12_chunk OWNER TO postgres;

--
-- TOC entry 382 (class 1259 OID 24396)
-- Name: _hyper_1_130_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_130_chunk (
    CONSTRAINT constraint_130 CHECK (((event_time >= '2024-11-14 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-11-21 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_130_chunk OWNER TO postgres;

--
-- TOC entry 383 (class 1259 OID 24425)
-- Name: _hyper_1_131_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_131_chunk (
    CONSTRAINT constraint_131 CHECK (((event_time >= '2024-08-22 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-08-29 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_131_chunk OWNER TO postgres;

--
-- TOC entry 384 (class 1259 OID 24454)
-- Name: _hyper_1_132_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_132_chunk (
    CONSTRAINT constraint_132 CHECK (((event_time >= '2024-06-06 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-06-13 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_132_chunk OWNER TO postgres;

--
-- TOC entry 385 (class 1259 OID 24483)
-- Name: _hyper_1_133_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_133_chunk (
    CONSTRAINT constraint_133 CHECK (((event_time >= '2024-12-12 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-12-19 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_133_chunk OWNER TO postgres;

--
-- TOC entry 386 (class 1259 OID 24512)
-- Name: _hyper_1_134_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_134_chunk (
    CONSTRAINT constraint_134 CHECK (((event_time >= '2024-09-12 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-09-19 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_134_chunk OWNER TO postgres;

--
-- TOC entry 387 (class 1259 OID 24541)
-- Name: _hyper_1_135_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_135_chunk (
    CONSTRAINT constraint_135 CHECK (((event_time >= '2024-05-02 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-05-09 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_135_chunk OWNER TO postgres;

--
-- TOC entry 388 (class 1259 OID 24570)
-- Name: _hyper_1_136_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_136_chunk (
    CONSTRAINT constraint_136 CHECK (((event_time >= '2024-05-09 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-05-16 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_136_chunk OWNER TO postgres;

--
-- TOC entry 389 (class 1259 OID 24599)
-- Name: _hyper_1_137_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_137_chunk (
    CONSTRAINT constraint_137 CHECK (((event_time >= '2025-03-06 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-03-13 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_137_chunk OWNER TO postgres;

--
-- TOC entry 390 (class 1259 OID 24628)
-- Name: _hyper_1_138_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_138_chunk (
    CONSTRAINT constraint_138 CHECK (((event_time >= '2025-02-13 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-02-20 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_138_chunk OWNER TO postgres;

--
-- TOC entry 391 (class 1259 OID 24657)
-- Name: _hyper_1_139_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_139_chunk (
    CONSTRAINT constraint_139 CHECK (((event_time >= '2024-11-07 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-11-14 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_139_chunk OWNER TO postgres;

--
-- TOC entry 315 (class 1259 OID 19300)
-- Name: _hyper_1_13_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_13_chunk (
    CONSTRAINT constraint_13 CHECK (((event_time >= '2025-05-01 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-05-08 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_13_chunk OWNER TO postgres;

--
-- TOC entry 392 (class 1259 OID 24686)
-- Name: _hyper_1_140_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_140_chunk (
    CONSTRAINT constraint_140 CHECK (((event_time >= '2024-08-29 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-09-05 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_140_chunk OWNER TO postgres;

--
-- TOC entry 393 (class 1259 OID 24715)
-- Name: _hyper_1_141_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_141_chunk (
    CONSTRAINT constraint_141 CHECK (((event_time >= '2024-08-08 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-08-15 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_141_chunk OWNER TO postgres;

--
-- TOC entry 394 (class 1259 OID 24744)
-- Name: _hyper_1_142_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_142_chunk (
    CONSTRAINT constraint_142 CHECK (((event_time >= '2025-04-10 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-04-17 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_142_chunk OWNER TO postgres;

--
-- TOC entry 395 (class 1259 OID 24773)
-- Name: _hyper_1_143_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_143_chunk (
    CONSTRAINT constraint_143 CHECK (((event_time >= '2024-12-05 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-12-12 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_143_chunk OWNER TO postgres;

--
-- TOC entry 396 (class 1259 OID 24802)
-- Name: _hyper_1_144_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_144_chunk (
    CONSTRAINT constraint_144 CHECK (((event_time >= '2024-04-25 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-05-02 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_144_chunk OWNER TO postgres;

--
-- TOC entry 397 (class 1259 OID 24831)
-- Name: _hyper_1_145_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_145_chunk (
    CONSTRAINT constraint_145 CHECK (((event_time >= '2025-03-13 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-03-20 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_145_chunk OWNER TO postgres;

--
-- TOC entry 398 (class 1259 OID 24860)
-- Name: _hyper_1_146_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_146_chunk (
    CONSTRAINT constraint_146 CHECK (((event_time >= '2024-12-19 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-12-26 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_146_chunk OWNER TO postgres;

--
-- TOC entry 399 (class 1259 OID 24889)
-- Name: _hyper_1_147_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_147_chunk (
    CONSTRAINT constraint_147 CHECK (((event_time >= '2024-09-19 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-09-26 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_147_chunk OWNER TO postgres;

--
-- TOC entry 400 (class 1259 OID 24918)
-- Name: _hyper_1_148_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_148_chunk (
    CONSTRAINT constraint_148 CHECK (((event_time >= '2024-10-03 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-10-10 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_148_chunk OWNER TO postgres;

--
-- TOC entry 401 (class 1259 OID 24947)
-- Name: _hyper_1_149_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_149_chunk (
    CONSTRAINT constraint_149 CHECK (((event_time >= '2024-10-31 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-11-07 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_149_chunk OWNER TO postgres;

--
-- TOC entry 316 (class 1259 OID 19325)
-- Name: _hyper_1_14_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_14_chunk (
    CONSTRAINT constraint_14 CHECK (((event_time >= '2025-11-06 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-11-13 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_14_chunk OWNER TO postgres;

--
-- TOC entry 402 (class 1259 OID 24976)
-- Name: _hyper_1_150_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_150_chunk (
    CONSTRAINT constraint_150 CHECK (((event_time >= '2024-05-16 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-05-23 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_150_chunk OWNER TO postgres;

--
-- TOC entry 403 (class 1259 OID 25005)
-- Name: _hyper_1_151_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_151_chunk (
    CONSTRAINT constraint_151 CHECK (((event_time >= '2025-01-23 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-01-30 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_151_chunk OWNER TO postgres;

--
-- TOC entry 404 (class 1259 OID 25034)
-- Name: _hyper_1_152_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_152_chunk (
    CONSTRAINT constraint_152 CHECK (((event_time >= '2024-10-24 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-10-31 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_152_chunk OWNER TO postgres;

--
-- TOC entry 405 (class 1259 OID 25063)
-- Name: _hyper_1_153_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_153_chunk (
    CONSTRAINT constraint_153 CHECK (((event_time >= '2024-07-25 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-08-01 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_153_chunk OWNER TO postgres;

--
-- TOC entry 406 (class 1259 OID 25092)
-- Name: _hyper_1_154_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_154_chunk (
    CONSTRAINT constraint_154 CHECK (((event_time >= '2024-09-26 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-10-03 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_154_chunk OWNER TO postgres;

--
-- TOC entry 407 (class 1259 OID 25121)
-- Name: _hyper_1_155_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_155_chunk (
    CONSTRAINT constraint_155 CHECK (((event_time >= '2024-07-18 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-07-25 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_155_chunk OWNER TO postgres;

--
-- TOC entry 408 (class 1259 OID 25150)
-- Name: _hyper_1_156_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_156_chunk (
    CONSTRAINT constraint_156 CHECK (((event_time >= '2024-05-30 00:00:00+00'::timestamp with time zone) AND (event_time < '2024-06-06 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_156_chunk OWNER TO postgres;

--
-- TOC entry 409 (class 1259 OID 25179)
-- Name: _hyper_1_157_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_157_chunk (
    CONSTRAINT constraint_157 CHECK (((event_time >= '2025-02-20 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-02-27 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_157_chunk OWNER TO postgres;

--
-- TOC entry 317 (class 1259 OID 19350)
-- Name: _hyper_1_15_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_15_chunk (
    CONSTRAINT constraint_15 CHECK (((event_time >= '2025-09-18 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-09-25 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_15_chunk OWNER TO postgres;

--
-- TOC entry 318 (class 1259 OID 19375)
-- Name: _hyper_1_16_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_16_chunk (
    CONSTRAINT constraint_16 CHECK (((event_time >= '2026-02-19 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-02-26 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_16_chunk OWNER TO postgres;

--
-- TOC entry 319 (class 1259 OID 19400)
-- Name: _hyper_1_17_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_17_chunk (
    CONSTRAINT constraint_17 CHECK (((event_time >= '2025-05-22 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-05-29 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_17_chunk OWNER TO postgres;

--
-- TOC entry 320 (class 1259 OID 19425)
-- Name: _hyper_1_18_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_18_chunk (
    CONSTRAINT constraint_18 CHECK (((event_time >= '2025-07-10 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-07-17 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_18_chunk OWNER TO postgres;

--
-- TOC entry 321 (class 1259 OID 19450)
-- Name: _hyper_1_19_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_19_chunk (
    CONSTRAINT constraint_19 CHECK (((event_time >= '2026-02-26 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-03-05 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_19_chunk OWNER TO postgres;

--
-- TOC entry 303 (class 1259 OID 19000)
-- Name: _hyper_1_1_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_1_chunk (
    CONSTRAINT constraint_1 CHECK (((event_time >= '2026-04-02 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-04-09 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_1_chunk OWNER TO postgres;

--
-- TOC entry 322 (class 1259 OID 19475)
-- Name: _hyper_1_20_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_20_chunk (
    CONSTRAINT constraint_20 CHECK (((event_time >= '2025-11-20 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-11-27 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_20_chunk OWNER TO postgres;

--
-- TOC entry 323 (class 1259 OID 19500)
-- Name: _hyper_1_21_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_21_chunk (
    CONSTRAINT constraint_21 CHECK (((event_time >= '2025-10-23 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-10-30 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_21_chunk OWNER TO postgres;

--
-- TOC entry 324 (class 1259 OID 19525)
-- Name: _hyper_1_22_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_22_chunk (
    CONSTRAINT constraint_22 CHECK (((event_time >= '2025-05-29 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-06-05 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_22_chunk OWNER TO postgres;

--
-- TOC entry 325 (class 1259 OID 19550)
-- Name: _hyper_1_23_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_23_chunk (
    CONSTRAINT constraint_23 CHECK (((event_time >= '2025-07-24 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-07-31 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_23_chunk OWNER TO postgres;

--
-- TOC entry 326 (class 1259 OID 19575)
-- Name: _hyper_1_24_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_24_chunk (
    CONSTRAINT constraint_24 CHECK (((event_time >= '2025-08-07 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-08-14 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_24_chunk OWNER TO postgres;

--
-- TOC entry 327 (class 1259 OID 19600)
-- Name: _hyper_1_25_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_25_chunk (
    CONSTRAINT constraint_25 CHECK (((event_time >= '2025-11-13 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-11-20 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_25_chunk OWNER TO postgres;

--
-- TOC entry 328 (class 1259 OID 19625)
-- Name: _hyper_1_26_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_26_chunk (
    CONSTRAINT constraint_26 CHECK (((event_time >= '2025-10-02 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-10-09 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_26_chunk OWNER TO postgres;

--
-- TOC entry 329 (class 1259 OID 19650)
-- Name: _hyper_1_27_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_27_chunk (
    CONSTRAINT constraint_27 CHECK (((event_time >= '2025-08-14 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-08-21 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_27_chunk OWNER TO postgres;

--
-- TOC entry 330 (class 1259 OID 19675)
-- Name: _hyper_1_28_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_28_chunk (
    CONSTRAINT constraint_28 CHECK (((event_time >= '2026-02-05 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-02-12 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_28_chunk OWNER TO postgres;

--
-- TOC entry 331 (class 1259 OID 19700)
-- Name: _hyper_1_29_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_29_chunk (
    CONSTRAINT constraint_29 CHECK (((event_time >= '2025-04-24 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-05-01 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_29_chunk OWNER TO postgres;

--
-- TOC entry 304 (class 1259 OID 19025)
-- Name: _hyper_1_2_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_2_chunk (
    CONSTRAINT constraint_2 CHECK (((event_time >= '2025-10-30 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-11-06 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_2_chunk OWNER TO postgres;

--
-- TOC entry 332 (class 1259 OID 19725)
-- Name: _hyper_1_30_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_30_chunk (
    CONSTRAINT constraint_30 CHECK (((event_time >= '2026-03-19 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-03-26 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_30_chunk OWNER TO postgres;

--
-- TOC entry 333 (class 1259 OID 19750)
-- Name: _hyper_1_31_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_31_chunk (
    CONSTRAINT constraint_31 CHECK (((event_time >= '2025-05-08 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-05-15 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_31_chunk OWNER TO postgres;

--
-- TOC entry 334 (class 1259 OID 19775)
-- Name: _hyper_1_32_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_32_chunk (
    CONSTRAINT constraint_32 CHECK (((event_time >= '2025-08-21 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-08-28 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_32_chunk OWNER TO postgres;

--
-- TOC entry 335 (class 1259 OID 19800)
-- Name: _hyper_1_33_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_33_chunk (
    CONSTRAINT constraint_33 CHECK (((event_time >= '2025-10-16 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-10-23 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_33_chunk OWNER TO postgres;

--
-- TOC entry 336 (class 1259 OID 19825)
-- Name: _hyper_1_34_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_34_chunk (
    CONSTRAINT constraint_34 CHECK (((event_time >= '2025-12-11 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-12-18 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_34_chunk OWNER TO postgres;

--
-- TOC entry 337 (class 1259 OID 19850)
-- Name: _hyper_1_35_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_35_chunk (
    CONSTRAINT constraint_35 CHECK (((event_time >= '2026-01-01 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-01-08 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_35_chunk OWNER TO postgres;

--
-- TOC entry 338 (class 1259 OID 19875)
-- Name: _hyper_1_36_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_36_chunk (
    CONSTRAINT constraint_36 CHECK (((event_time >= '2025-06-05 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-06-12 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_36_chunk OWNER TO postgres;

--
-- TOC entry 339 (class 1259 OID 19900)
-- Name: _hyper_1_37_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_37_chunk (
    CONSTRAINT constraint_37 CHECK (((event_time >= '2025-05-15 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-05-22 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_37_chunk OWNER TO postgres;

--
-- TOC entry 340 (class 1259 OID 19925)
-- Name: _hyper_1_38_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_38_chunk (
    CONSTRAINT constraint_38 CHECK (((event_time >= '2026-04-09 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-04-16 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_38_chunk OWNER TO postgres;

--
-- TOC entry 341 (class 1259 OID 19950)
-- Name: _hyper_1_39_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_39_chunk (
    CONSTRAINT constraint_39 CHECK (((event_time >= '2025-09-25 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-10-02 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_39_chunk OWNER TO postgres;

--
-- TOC entry 305 (class 1259 OID 19050)
-- Name: _hyper_1_3_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_3_chunk (
    CONSTRAINT constraint_3 CHECK (((event_time >= '2026-03-26 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-04-02 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_3_chunk OWNER TO postgres;

--
-- TOC entry 342 (class 1259 OID 19975)
-- Name: _hyper_1_40_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_40_chunk (
    CONSTRAINT constraint_40 CHECK (((event_time >= '2025-10-09 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-10-16 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_40_chunk OWNER TO postgres;

--
-- TOC entry 343 (class 1259 OID 20000)
-- Name: _hyper_1_41_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_41_chunk (
    CONSTRAINT constraint_41 CHECK (((event_time >= '2025-12-25 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-01-01 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_41_chunk OWNER TO postgres;

--
-- TOC entry 344 (class 1259 OID 20025)
-- Name: _hyper_1_42_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_42_chunk (
    CONSTRAINT constraint_42 CHECK (((event_time >= '2026-04-23 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-04-30 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_42_chunk OWNER TO postgres;

--
-- TOC entry 345 (class 1259 OID 20050)
-- Name: _hyper_1_43_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_43_chunk (
    CONSTRAINT constraint_43 CHECK (((event_time >= '2026-01-15 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-01-22 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_43_chunk OWNER TO postgres;

--
-- TOC entry 346 (class 1259 OID 20075)
-- Name: _hyper_1_44_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_44_chunk (
    CONSTRAINT constraint_44 CHECK (((event_time >= '2025-06-19 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-06-26 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_44_chunk OWNER TO postgres;

--
-- TOC entry 347 (class 1259 OID 20100)
-- Name: _hyper_1_45_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_45_chunk (
    CONSTRAINT constraint_45 CHECK (((event_time >= '2025-11-27 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-12-04 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_45_chunk OWNER TO postgres;

--
-- TOC entry 348 (class 1259 OID 20125)
-- Name: _hyper_1_46_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_46_chunk (
    CONSTRAINT constraint_46 CHECK (((event_time >= '2025-07-31 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-08-07 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_46_chunk OWNER TO postgres;

--
-- TOC entry 349 (class 1259 OID 20150)
-- Name: _hyper_1_47_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_47_chunk (
    CONSTRAINT constraint_47 CHECK (((event_time >= '2026-03-12 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-03-19 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_47_chunk OWNER TO postgres;

--
-- TOC entry 350 (class 1259 OID 20175)
-- Name: _hyper_1_48_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_48_chunk (
    CONSTRAINT constraint_48 CHECK (((event_time >= '2025-06-26 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-07-03 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_48_chunk OWNER TO postgres;

--
-- TOC entry 351 (class 1259 OID 20200)
-- Name: _hyper_1_49_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_49_chunk (
    CONSTRAINT constraint_49 CHECK (((event_time >= '2026-04-16 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-04-23 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_49_chunk OWNER TO postgres;

--
-- TOC entry 306 (class 1259 OID 19075)
-- Name: _hyper_1_4_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_4_chunk (
    CONSTRAINT constraint_4 CHECK (((event_time >= '2025-06-12 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-06-19 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_4_chunk OWNER TO postgres;

--
-- TOC entry 352 (class 1259 OID 20225)
-- Name: _hyper_1_50_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_50_chunk (
    CONSTRAINT constraint_50 CHECK (((event_time >= '2025-09-04 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-09-11 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_50_chunk OWNER TO postgres;

--
-- TOC entry 353 (class 1259 OID 20250)
-- Name: _hyper_1_51_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_51_chunk (
    CONSTRAINT constraint_51 CHECK (((event_time >= '2026-01-08 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-01-15 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_51_chunk OWNER TO postgres;

--
-- TOC entry 354 (class 1259 OID 20275)
-- Name: _hyper_1_52_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_52_chunk (
    CONSTRAINT constraint_52 CHECK (((event_time >= '2025-12-04 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-12-11 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_52_chunk OWNER TO postgres;

--
-- TOC entry 355 (class 1259 OID 20300)
-- Name: _hyper_1_53_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_53_chunk (
    CONSTRAINT constraint_53 CHECK (((event_time >= '2026-02-12 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-02-19 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_53_chunk OWNER TO postgres;

--
-- TOC entry 307 (class 1259 OID 19100)
-- Name: _hyper_1_5_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_5_chunk (
    CONSTRAINT constraint_5 CHECK (((event_time >= '2025-12-18 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-12-25 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_5_chunk OWNER TO postgres;

--
-- TOC entry 308 (class 1259 OID 19125)
-- Name: _hyper_1_6_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_6_chunk (
    CONSTRAINT constraint_6 CHECK (((event_time >= '2025-08-28 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-09-04 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_6_chunk OWNER TO postgres;

--
-- TOC entry 309 (class 1259 OID 19150)
-- Name: _hyper_1_7_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_7_chunk (
    CONSTRAINT constraint_7 CHECK (((event_time >= '2025-09-11 00:00:00+00'::timestamp with time zone) AND (event_time < '2025-09-18 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_7_chunk OWNER TO postgres;

--
-- TOC entry 310 (class 1259 OID 19175)
-- Name: _hyper_1_8_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_8_chunk (
    CONSTRAINT constraint_8 CHECK (((event_time >= '2026-03-05 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-03-12 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_8_chunk OWNER TO postgres;

--
-- TOC entry 311 (class 1259 OID 19200)
-- Name: _hyper_1_9_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_1_9_chunk (
    CONSTRAINT constraint_9 CHECK (((event_time >= '2026-01-22 00:00:00+00'::timestamp with time zone) AND (event_time < '2026-01-29 00:00:00+00'::timestamp with time zone)))
)
INHERITS (public.order_events);


ALTER TABLE _timescaledb_internal._hyper_1_9_chunk OWNER TO postgres;

--
-- TOC entry 511 (class 1259 OID 30558)
-- Name: _materialized_hypertable_3; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._materialized_hypertable_3 (
    bucket timestamp with time zone,
    region text,
    status text,
    order_count bigint,
    total_revenue numeric,
    avg_order_value numeric,
    max_order_value numeric
);


ALTER TABLE _timescaledb_internal._materialized_hypertable_3 OWNER TO postgres;

--
-- TOC entry 515 (class 1259 OID 30586)
-- Name: _hyper_3_258_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_258_chunk (
    CONSTRAINT constraint_158 CHECK (((bucket >= '2024-03-28 00:00:00+00'::timestamp with time zone) AND (bucket < '2024-06-06 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_258_chunk OWNER TO postgres;

--
-- TOC entry 516 (class 1259 OID 30595)
-- Name: _hyper_3_259_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_259_chunk (
    CONSTRAINT constraint_159 CHECK (((bucket >= '2024-06-06 00:00:00+00'::timestamp with time zone) AND (bucket < '2024-08-15 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_259_chunk OWNER TO postgres;

--
-- TOC entry 517 (class 1259 OID 30604)
-- Name: _hyper_3_260_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_260_chunk (
    CONSTRAINT constraint_160 CHECK (((bucket >= '2024-08-15 00:00:00+00'::timestamp with time zone) AND (bucket < '2024-10-24 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_260_chunk OWNER TO postgres;

--
-- TOC entry 518 (class 1259 OID 30613)
-- Name: _hyper_3_261_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_261_chunk (
    CONSTRAINT constraint_161 CHECK (((bucket >= '2024-10-24 00:00:00+00'::timestamp with time zone) AND (bucket < '2025-01-02 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_261_chunk OWNER TO postgres;

--
-- TOC entry 519 (class 1259 OID 30622)
-- Name: _hyper_3_262_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_262_chunk (
    CONSTRAINT constraint_162 CHECK (((bucket >= '2025-01-02 00:00:00+00'::timestamp with time zone) AND (bucket < '2025-03-13 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_262_chunk OWNER TO postgres;

--
-- TOC entry 520 (class 1259 OID 30631)
-- Name: _hyper_3_263_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_263_chunk (
    CONSTRAINT constraint_163 CHECK (((bucket >= '2025-03-13 00:00:00+00'::timestamp with time zone) AND (bucket < '2025-05-22 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_263_chunk OWNER TO postgres;

--
-- TOC entry 521 (class 1259 OID 30640)
-- Name: _hyper_3_264_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_264_chunk (
    CONSTRAINT constraint_164 CHECK (((bucket >= '2025-05-22 00:00:00+00'::timestamp with time zone) AND (bucket < '2025-07-31 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_264_chunk OWNER TO postgres;

--
-- TOC entry 522 (class 1259 OID 30649)
-- Name: _hyper_3_265_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_265_chunk (
    CONSTRAINT constraint_165 CHECK (((bucket >= '2025-07-31 00:00:00+00'::timestamp with time zone) AND (bucket < '2025-10-09 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_265_chunk OWNER TO postgres;

--
-- TOC entry 523 (class 1259 OID 30658)
-- Name: _hyper_3_266_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_266_chunk (
    CONSTRAINT constraint_166 CHECK (((bucket >= '2025-10-09 00:00:00+00'::timestamp with time zone) AND (bucket < '2025-12-18 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_266_chunk OWNER TO postgres;

--
-- TOC entry 524 (class 1259 OID 30667)
-- Name: _hyper_3_267_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_267_chunk (
    CONSTRAINT constraint_167 CHECK (((bucket >= '2025-12-18 00:00:00+00'::timestamp with time zone) AND (bucket < '2026-02-26 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_267_chunk OWNER TO postgres;

--
-- TOC entry 525 (class 1259 OID 30676)
-- Name: _hyper_3_268_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal._hyper_3_268_chunk (
    CONSTRAINT constraint_168 CHECK (((bucket >= '2026-02-26 00:00:00+00'::timestamp with time zone) AND (bucket < '2026-05-07 00:00:00+00'::timestamp with time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_3);


ALTER TABLE _timescaledb_internal._hyper_3_268_chunk OWNER TO postgres;

--
-- TOC entry 513 (class 1259 OID 30570)
-- Name: _partial_view_3; Type: VIEW; Schema: _timescaledb_internal; Owner: postgres
--

CREATE VIEW _timescaledb_internal._partial_view_3 AS
 SELECT public.time_bucket('01:00:00'::interval, event_time) AS bucket,
    region,
    status,
    count(*) AS order_count,
    sum(total_amount) AS total_revenue,
    avg(total_amount) AS avg_order_value,
    max(total_amount) AS max_order_value
   FROM public.order_events
  GROUP BY (public.time_bucket('01:00:00'::interval, event_time)), region, status;


ALTER VIEW _timescaledb_internal._partial_view_3 OWNER TO postgres;

--
-- TOC entry 411 (class 1259 OID 25213)
-- Name: compress_hyper_2_158_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_158_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_158_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_158_chunk OWNER TO postgres;

--
-- TOC entry 412 (class 1259 OID 25267)
-- Name: compress_hyper_2_159_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_159_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_159_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_159_chunk OWNER TO postgres;

--
-- TOC entry 413 (class 1259 OID 25321)
-- Name: compress_hyper_2_160_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_160_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_160_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_160_chunk OWNER TO postgres;

--
-- TOC entry 414 (class 1259 OID 25375)
-- Name: compress_hyper_2_161_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_161_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_161_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_161_chunk OWNER TO postgres;

--
-- TOC entry 415 (class 1259 OID 25429)
-- Name: compress_hyper_2_162_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_162_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_162_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_162_chunk OWNER TO postgres;

--
-- TOC entry 416 (class 1259 OID 25483)
-- Name: compress_hyper_2_163_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_163_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_163_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_163_chunk OWNER TO postgres;

--
-- TOC entry 417 (class 1259 OID 25537)
-- Name: compress_hyper_2_164_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_164_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_164_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_164_chunk OWNER TO postgres;

--
-- TOC entry 418 (class 1259 OID 25591)
-- Name: compress_hyper_2_165_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_165_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_165_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_165_chunk OWNER TO postgres;

--
-- TOC entry 419 (class 1259 OID 25645)
-- Name: compress_hyper_2_166_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_166_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_166_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_166_chunk OWNER TO postgres;

--
-- TOC entry 420 (class 1259 OID 25699)
-- Name: compress_hyper_2_167_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_167_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_167_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_167_chunk OWNER TO postgres;

--
-- TOC entry 421 (class 1259 OID 25753)
-- Name: compress_hyper_2_168_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_168_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_168_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_168_chunk OWNER TO postgres;

--
-- TOC entry 422 (class 1259 OID 25807)
-- Name: compress_hyper_2_169_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_169_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_169_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_169_chunk OWNER TO postgres;

--
-- TOC entry 423 (class 1259 OID 25861)
-- Name: compress_hyper_2_170_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_170_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_170_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_170_chunk OWNER TO postgres;

--
-- TOC entry 424 (class 1259 OID 25915)
-- Name: compress_hyper_2_171_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_171_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_171_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_171_chunk OWNER TO postgres;

--
-- TOC entry 425 (class 1259 OID 25969)
-- Name: compress_hyper_2_172_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_172_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_172_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_172_chunk OWNER TO postgres;

--
-- TOC entry 426 (class 1259 OID 26023)
-- Name: compress_hyper_2_173_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_173_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_173_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_173_chunk OWNER TO postgres;

--
-- TOC entry 427 (class 1259 OID 26077)
-- Name: compress_hyper_2_174_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_174_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_174_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_174_chunk OWNER TO postgres;

--
-- TOC entry 428 (class 1259 OID 26131)
-- Name: compress_hyper_2_175_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_175_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_175_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_175_chunk OWNER TO postgres;

--
-- TOC entry 429 (class 1259 OID 26185)
-- Name: compress_hyper_2_176_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_176_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_176_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_176_chunk OWNER TO postgres;

--
-- TOC entry 430 (class 1259 OID 26239)
-- Name: compress_hyper_2_177_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_177_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_177_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_177_chunk OWNER TO postgres;

--
-- TOC entry 431 (class 1259 OID 26293)
-- Name: compress_hyper_2_178_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_178_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_178_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_178_chunk OWNER TO postgres;

--
-- TOC entry 432 (class 1259 OID 26347)
-- Name: compress_hyper_2_179_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_179_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_179_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_179_chunk OWNER TO postgres;

--
-- TOC entry 433 (class 1259 OID 26401)
-- Name: compress_hyper_2_180_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_180_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_180_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_180_chunk OWNER TO postgres;

--
-- TOC entry 434 (class 1259 OID 26455)
-- Name: compress_hyper_2_181_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_181_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_181_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_181_chunk OWNER TO postgres;

--
-- TOC entry 435 (class 1259 OID 26509)
-- Name: compress_hyper_2_182_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_182_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_182_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_182_chunk OWNER TO postgres;

--
-- TOC entry 436 (class 1259 OID 26563)
-- Name: compress_hyper_2_183_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_183_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_183_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_183_chunk OWNER TO postgres;

--
-- TOC entry 437 (class 1259 OID 26617)
-- Name: compress_hyper_2_184_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_184_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_184_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_184_chunk OWNER TO postgres;

--
-- TOC entry 438 (class 1259 OID 26671)
-- Name: compress_hyper_2_185_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_185_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_185_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_185_chunk OWNER TO postgres;

--
-- TOC entry 439 (class 1259 OID 26725)
-- Name: compress_hyper_2_186_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_186_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_186_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_186_chunk OWNER TO postgres;

--
-- TOC entry 440 (class 1259 OID 26779)
-- Name: compress_hyper_2_187_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_187_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_187_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_187_chunk OWNER TO postgres;

--
-- TOC entry 441 (class 1259 OID 26833)
-- Name: compress_hyper_2_188_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_188_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_188_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_188_chunk OWNER TO postgres;

--
-- TOC entry 442 (class 1259 OID 26887)
-- Name: compress_hyper_2_189_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_189_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_189_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_189_chunk OWNER TO postgres;

--
-- TOC entry 443 (class 1259 OID 26941)
-- Name: compress_hyper_2_190_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_190_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_190_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_190_chunk OWNER TO postgres;

--
-- TOC entry 444 (class 1259 OID 26995)
-- Name: compress_hyper_2_191_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_191_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_191_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_191_chunk OWNER TO postgres;

--
-- TOC entry 445 (class 1259 OID 27049)
-- Name: compress_hyper_2_192_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_192_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_192_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_192_chunk OWNER TO postgres;

--
-- TOC entry 446 (class 1259 OID 27103)
-- Name: compress_hyper_2_193_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_193_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_193_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_193_chunk OWNER TO postgres;

--
-- TOC entry 447 (class 1259 OID 27157)
-- Name: compress_hyper_2_194_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_194_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_194_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_194_chunk OWNER TO postgres;

--
-- TOC entry 448 (class 1259 OID 27211)
-- Name: compress_hyper_2_195_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_195_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_195_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_195_chunk OWNER TO postgres;

--
-- TOC entry 449 (class 1259 OID 27265)
-- Name: compress_hyper_2_196_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_196_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_196_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_196_chunk OWNER TO postgres;

--
-- TOC entry 450 (class 1259 OID 27319)
-- Name: compress_hyper_2_197_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_197_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_197_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_197_chunk OWNER TO postgres;

--
-- TOC entry 451 (class 1259 OID 27373)
-- Name: compress_hyper_2_198_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_198_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_198_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_198_chunk OWNER TO postgres;

--
-- TOC entry 452 (class 1259 OID 27427)
-- Name: compress_hyper_2_199_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_199_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_199_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_199_chunk OWNER TO postgres;

--
-- TOC entry 453 (class 1259 OID 27481)
-- Name: compress_hyper_2_200_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_200_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_200_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_200_chunk OWNER TO postgres;

--
-- TOC entry 454 (class 1259 OID 27535)
-- Name: compress_hyper_2_201_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_201_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_201_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_201_chunk OWNER TO postgres;

--
-- TOC entry 455 (class 1259 OID 27589)
-- Name: compress_hyper_2_202_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_202_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_202_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_202_chunk OWNER TO postgres;

--
-- TOC entry 456 (class 1259 OID 27643)
-- Name: compress_hyper_2_203_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_203_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_203_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_203_chunk OWNER TO postgres;

--
-- TOC entry 457 (class 1259 OID 27697)
-- Name: compress_hyper_2_204_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_204_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_204_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_204_chunk OWNER TO postgres;

--
-- TOC entry 458 (class 1259 OID 27751)
-- Name: compress_hyper_2_205_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_205_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_205_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_205_chunk OWNER TO postgres;

--
-- TOC entry 459 (class 1259 OID 27805)
-- Name: compress_hyper_2_206_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_206_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_206_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_206_chunk OWNER TO postgres;

--
-- TOC entry 460 (class 1259 OID 27859)
-- Name: compress_hyper_2_207_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_207_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_207_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_207_chunk OWNER TO postgres;

--
-- TOC entry 461 (class 1259 OID 27913)
-- Name: compress_hyper_2_208_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_208_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_208_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_208_chunk OWNER TO postgres;

--
-- TOC entry 462 (class 1259 OID 27967)
-- Name: compress_hyper_2_209_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_209_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_209_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_209_chunk OWNER TO postgres;

--
-- TOC entry 463 (class 1259 OID 28021)
-- Name: compress_hyper_2_210_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_210_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_210_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_210_chunk OWNER TO postgres;

--
-- TOC entry 464 (class 1259 OID 28075)
-- Name: compress_hyper_2_211_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_211_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_211_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_211_chunk OWNER TO postgres;

--
-- TOC entry 465 (class 1259 OID 28129)
-- Name: compress_hyper_2_212_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_212_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_212_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_212_chunk OWNER TO postgres;

--
-- TOC entry 466 (class 1259 OID 28183)
-- Name: compress_hyper_2_213_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_213_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_213_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_213_chunk OWNER TO postgres;

--
-- TOC entry 467 (class 1259 OID 28237)
-- Name: compress_hyper_2_214_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_214_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_214_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_214_chunk OWNER TO postgres;

--
-- TOC entry 468 (class 1259 OID 28291)
-- Name: compress_hyper_2_215_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_215_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_215_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_215_chunk OWNER TO postgres;

--
-- TOC entry 469 (class 1259 OID 28345)
-- Name: compress_hyper_2_216_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_216_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_216_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_216_chunk OWNER TO postgres;

--
-- TOC entry 470 (class 1259 OID 28399)
-- Name: compress_hyper_2_217_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_217_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_217_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_217_chunk OWNER TO postgres;

--
-- TOC entry 471 (class 1259 OID 28453)
-- Name: compress_hyper_2_218_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_218_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_218_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_218_chunk OWNER TO postgres;

--
-- TOC entry 472 (class 1259 OID 28507)
-- Name: compress_hyper_2_219_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_219_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_219_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_219_chunk OWNER TO postgres;

--
-- TOC entry 473 (class 1259 OID 28561)
-- Name: compress_hyper_2_220_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_220_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_220_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_220_chunk OWNER TO postgres;

--
-- TOC entry 474 (class 1259 OID 28615)
-- Name: compress_hyper_2_221_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_221_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_221_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_221_chunk OWNER TO postgres;

--
-- TOC entry 475 (class 1259 OID 28669)
-- Name: compress_hyper_2_222_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_222_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_222_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_222_chunk OWNER TO postgres;

--
-- TOC entry 476 (class 1259 OID 28723)
-- Name: compress_hyper_2_223_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_223_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_223_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_223_chunk OWNER TO postgres;

--
-- TOC entry 477 (class 1259 OID 28777)
-- Name: compress_hyper_2_224_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_224_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_224_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_224_chunk OWNER TO postgres;

--
-- TOC entry 478 (class 1259 OID 28831)
-- Name: compress_hyper_2_225_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_225_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_225_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_225_chunk OWNER TO postgres;

--
-- TOC entry 479 (class 1259 OID 28885)
-- Name: compress_hyper_2_226_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_226_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_226_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_226_chunk OWNER TO postgres;

--
-- TOC entry 480 (class 1259 OID 28939)
-- Name: compress_hyper_2_227_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_227_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_227_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_227_chunk OWNER TO postgres;

--
-- TOC entry 481 (class 1259 OID 28993)
-- Name: compress_hyper_2_228_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_228_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_228_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_228_chunk OWNER TO postgres;

--
-- TOC entry 482 (class 1259 OID 29047)
-- Name: compress_hyper_2_229_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_229_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_229_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_229_chunk OWNER TO postgres;

--
-- TOC entry 483 (class 1259 OID 29093)
-- Name: compress_hyper_2_230_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_230_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_230_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_230_chunk OWNER TO postgres;

--
-- TOC entry 484 (class 1259 OID 29147)
-- Name: compress_hyper_2_231_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_231_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_231_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_231_chunk OWNER TO postgres;

--
-- TOC entry 485 (class 1259 OID 29201)
-- Name: compress_hyper_2_232_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_232_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_232_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_232_chunk OWNER TO postgres;

--
-- TOC entry 486 (class 1259 OID 29255)
-- Name: compress_hyper_2_233_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_233_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_233_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_233_chunk OWNER TO postgres;

--
-- TOC entry 487 (class 1259 OID 29309)
-- Name: compress_hyper_2_234_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_234_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_234_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_234_chunk OWNER TO postgres;

--
-- TOC entry 488 (class 1259 OID 29363)
-- Name: compress_hyper_2_235_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_235_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_235_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_235_chunk OWNER TO postgres;

--
-- TOC entry 489 (class 1259 OID 29417)
-- Name: compress_hyper_2_236_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_236_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_236_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_236_chunk OWNER TO postgres;

--
-- TOC entry 490 (class 1259 OID 29471)
-- Name: compress_hyper_2_237_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_237_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_237_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_237_chunk OWNER TO postgres;

--
-- TOC entry 491 (class 1259 OID 29525)
-- Name: compress_hyper_2_238_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_238_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_238_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_238_chunk OWNER TO postgres;

--
-- TOC entry 492 (class 1259 OID 29579)
-- Name: compress_hyper_2_239_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_239_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_239_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_239_chunk OWNER TO postgres;

--
-- TOC entry 493 (class 1259 OID 29633)
-- Name: compress_hyper_2_240_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_240_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_240_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_240_chunk OWNER TO postgres;

--
-- TOC entry 494 (class 1259 OID 29687)
-- Name: compress_hyper_2_241_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_241_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_241_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_241_chunk OWNER TO postgres;

--
-- TOC entry 495 (class 1259 OID 29741)
-- Name: compress_hyper_2_242_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_242_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_242_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_242_chunk OWNER TO postgres;

--
-- TOC entry 496 (class 1259 OID 29795)
-- Name: compress_hyper_2_243_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_243_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_243_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_243_chunk OWNER TO postgres;

--
-- TOC entry 497 (class 1259 OID 29849)
-- Name: compress_hyper_2_244_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_244_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_244_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_244_chunk OWNER TO postgres;

--
-- TOC entry 498 (class 1259 OID 29863)
-- Name: compress_hyper_2_245_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_245_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_245_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_245_chunk OWNER TO postgres;

--
-- TOC entry 499 (class 1259 OID 29917)
-- Name: compress_hyper_2_246_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_246_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_246_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_246_chunk OWNER TO postgres;

--
-- TOC entry 500 (class 1259 OID 29971)
-- Name: compress_hyper_2_247_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_247_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_247_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_247_chunk OWNER TO postgres;

--
-- TOC entry 501 (class 1259 OID 30025)
-- Name: compress_hyper_2_248_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_248_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_248_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_248_chunk OWNER TO postgres;

--
-- TOC entry 502 (class 1259 OID 30079)
-- Name: compress_hyper_2_249_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_249_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_249_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_249_chunk OWNER TO postgres;

--
-- TOC entry 503 (class 1259 OID 30133)
-- Name: compress_hyper_2_250_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_250_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_250_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_250_chunk OWNER TO postgres;

--
-- TOC entry 504 (class 1259 OID 30187)
-- Name: compress_hyper_2_251_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_251_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_251_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_251_chunk OWNER TO postgres;

--
-- TOC entry 505 (class 1259 OID 30241)
-- Name: compress_hyper_2_252_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_252_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_252_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_252_chunk OWNER TO postgres;

--
-- TOC entry 506 (class 1259 OID 30287)
-- Name: compress_hyper_2_253_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_253_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_253_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_253_chunk OWNER TO postgres;

--
-- TOC entry 507 (class 1259 OID 30341)
-- Name: compress_hyper_2_254_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_254_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_254_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_254_chunk OWNER TO postgres;

--
-- TOC entry 508 (class 1259 OID 30395)
-- Name: compress_hyper_2_255_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_255_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_255_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_255_chunk OWNER TO postgres;

--
-- TOC entry 509 (class 1259 OID 30449)
-- Name: compress_hyper_2_256_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_256_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_256_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_256_chunk OWNER TO postgres;

--
-- TOC entry 510 (class 1259 OID 30503)
-- Name: compress_hyper_2_257_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_257_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_257_chunk ALTER COLUMN status SET STORAGE EXTENDED;


ALTER TABLE _timescaledb_internal.compress_hyper_2_257_chunk OWNER TO postgres;

--
-- TOC entry 537 (class 1259 OID 31930)
-- Name: compress_hyper_2_279_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_2_279_chunk (
    _ts_meta_count integer,
    region text,
    event_id _timescaledb_internal.compressed_data,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    event_time _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_customer_id _timescaledb_internal.bloom1,
    customer_id _timescaledb_internal.compressed_data,
    product_id _timescaledb_internal.compressed_data,
    quantity _timescaledb_internal.compressed_data,
    total_amount _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_status _timescaledb_internal.bloom1,
    status _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_event_time_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN event_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN event_time SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN _ts_meta_v2_bloomh_customer_id SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN customer_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN product_id SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN quantity SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN total_amount SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN total_amount SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN _ts_meta_v2_bloomh_status SET STORAGE EXTERNAL;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN _ts_meta_v2_bloomh_event_time_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_2_279_chunk ALTER COLUMN _ts_meta_v2_bloomh_event_time_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_2_279_chunk OWNER TO postgres;

--
-- TOC entry 527 (class 1259 OID 30688)
-- Name: compress_hyper_4_269_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_4_269_chunk (
    _ts_meta_count integer,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    bucket _timescaledb_internal.compressed_data,
    _ts_meta_min_2 text,
    _ts_meta_max_2 text,
    region _timescaledb_internal.compressed_data,
    _ts_meta_min_3 text,
    _ts_meta_max_3 text,
    status _timescaledb_internal.compressed_data,
    order_count _timescaledb_internal.compressed_data,
    total_revenue _timescaledb_internal.compressed_data,
    avg_order_value _timescaledb_internal.compressed_data,
    max_order_value _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_bucket_region _timescaledb_internal.bloom1,
    _ts_meta_v2_bloomh_bucket_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN bucket SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_min_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_min_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_max_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_max_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN region SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN region SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_min_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_min_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_max_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_max_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN order_count SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN total_revenue SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN total_revenue SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN avg_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN avg_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN max_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN max_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STORAGE MAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_269_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_4_269_chunk OWNER TO postgres;

--
-- TOC entry 528 (class 1259 OID 30721)
-- Name: compress_hyper_4_270_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_4_270_chunk (
    _ts_meta_count integer,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    bucket _timescaledb_internal.compressed_data,
    _ts_meta_min_2 text,
    _ts_meta_max_2 text,
    region _timescaledb_internal.compressed_data,
    _ts_meta_min_3 text,
    _ts_meta_max_3 text,
    status _timescaledb_internal.compressed_data,
    order_count _timescaledb_internal.compressed_data,
    total_revenue _timescaledb_internal.compressed_data,
    avg_order_value _timescaledb_internal.compressed_data,
    max_order_value _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_bucket_region _timescaledb_internal.bloom1,
    _ts_meta_v2_bloomh_bucket_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN bucket SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_min_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_min_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_max_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_max_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN region SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN region SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_min_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_min_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_max_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_max_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN order_count SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN total_revenue SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN total_revenue SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN avg_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN avg_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN max_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN max_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STORAGE MAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_270_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_4_270_chunk OWNER TO postgres;

--
-- TOC entry 529 (class 1259 OID 30768)
-- Name: compress_hyper_4_271_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_4_271_chunk (
    _ts_meta_count integer,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    bucket _timescaledb_internal.compressed_data,
    _ts_meta_min_2 text,
    _ts_meta_max_2 text,
    region _timescaledb_internal.compressed_data,
    _ts_meta_min_3 text,
    _ts_meta_max_3 text,
    status _timescaledb_internal.compressed_data,
    order_count _timescaledb_internal.compressed_data,
    total_revenue _timescaledb_internal.compressed_data,
    avg_order_value _timescaledb_internal.compressed_data,
    max_order_value _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_bucket_region _timescaledb_internal.bloom1,
    _ts_meta_v2_bloomh_bucket_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN bucket SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_min_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_min_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_max_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_max_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN region SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN region SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_min_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_min_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_max_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_max_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN order_count SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN total_revenue SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN total_revenue SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN avg_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN avg_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN max_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN max_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STORAGE MAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_271_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_4_271_chunk OWNER TO postgres;

--
-- TOC entry 530 (class 1259 OID 30815)
-- Name: compress_hyper_4_272_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_4_272_chunk (
    _ts_meta_count integer,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    bucket _timescaledb_internal.compressed_data,
    _ts_meta_min_2 text,
    _ts_meta_max_2 text,
    region _timescaledb_internal.compressed_data,
    _ts_meta_min_3 text,
    _ts_meta_max_3 text,
    status _timescaledb_internal.compressed_data,
    order_count _timescaledb_internal.compressed_data,
    total_revenue _timescaledb_internal.compressed_data,
    avg_order_value _timescaledb_internal.compressed_data,
    max_order_value _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_bucket_region _timescaledb_internal.bloom1,
    _ts_meta_v2_bloomh_bucket_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN bucket SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_min_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_min_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_max_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_max_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN region SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN region SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_min_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_min_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_max_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_max_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN order_count SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN total_revenue SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN total_revenue SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN avg_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN avg_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN max_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN max_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STORAGE MAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_272_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_4_272_chunk OWNER TO postgres;

--
-- TOC entry 531 (class 1259 OID 30862)
-- Name: compress_hyper_4_273_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_4_273_chunk (
    _ts_meta_count integer,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    bucket _timescaledb_internal.compressed_data,
    _ts_meta_min_2 text,
    _ts_meta_max_2 text,
    region _timescaledb_internal.compressed_data,
    _ts_meta_min_3 text,
    _ts_meta_max_3 text,
    status _timescaledb_internal.compressed_data,
    order_count _timescaledb_internal.compressed_data,
    total_revenue _timescaledb_internal.compressed_data,
    avg_order_value _timescaledb_internal.compressed_data,
    max_order_value _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_bucket_region _timescaledb_internal.bloom1,
    _ts_meta_v2_bloomh_bucket_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN bucket SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_min_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_min_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_max_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_max_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN region SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN region SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_min_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_min_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_max_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_max_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN order_count SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN total_revenue SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN total_revenue SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN avg_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN avg_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN max_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN max_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STORAGE MAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_273_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_4_273_chunk OWNER TO postgres;

--
-- TOC entry 532 (class 1259 OID 30909)
-- Name: compress_hyper_4_274_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_4_274_chunk (
    _ts_meta_count integer,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    bucket _timescaledb_internal.compressed_data,
    _ts_meta_min_2 text,
    _ts_meta_max_2 text,
    region _timescaledb_internal.compressed_data,
    _ts_meta_min_3 text,
    _ts_meta_max_3 text,
    status _timescaledb_internal.compressed_data,
    order_count _timescaledb_internal.compressed_data,
    total_revenue _timescaledb_internal.compressed_data,
    avg_order_value _timescaledb_internal.compressed_data,
    max_order_value _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_bucket_region _timescaledb_internal.bloom1,
    _ts_meta_v2_bloomh_bucket_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN bucket SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_min_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_min_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_max_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_max_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN region SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN region SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_min_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_min_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_max_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_max_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN order_count SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN total_revenue SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN total_revenue SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN avg_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN avg_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN max_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN max_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STORAGE MAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_274_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_4_274_chunk OWNER TO postgres;

--
-- TOC entry 533 (class 1259 OID 30991)
-- Name: compress_hyper_4_275_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_4_275_chunk (
    _ts_meta_count integer,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    bucket _timescaledb_internal.compressed_data,
    _ts_meta_min_2 text,
    _ts_meta_max_2 text,
    region _timescaledb_internal.compressed_data,
    _ts_meta_min_3 text,
    _ts_meta_max_3 text,
    status _timescaledb_internal.compressed_data,
    order_count _timescaledb_internal.compressed_data,
    total_revenue _timescaledb_internal.compressed_data,
    avg_order_value _timescaledb_internal.compressed_data,
    max_order_value _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_bucket_region _timescaledb_internal.bloom1,
    _ts_meta_v2_bloomh_bucket_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN bucket SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_min_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_min_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_max_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_max_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN region SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN region SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_min_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_min_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_max_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_max_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN order_count SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN total_revenue SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN total_revenue SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN avg_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN avg_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN max_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN max_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STORAGE MAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_275_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_4_275_chunk OWNER TO postgres;

--
-- TOC entry 534 (class 1259 OID 31136)
-- Name: compress_hyper_4_276_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_4_276_chunk (
    _ts_meta_count integer,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    bucket _timescaledb_internal.compressed_data,
    _ts_meta_min_2 text,
    _ts_meta_max_2 text,
    region _timescaledb_internal.compressed_data,
    _ts_meta_min_3 text,
    _ts_meta_max_3 text,
    status _timescaledb_internal.compressed_data,
    order_count _timescaledb_internal.compressed_data,
    total_revenue _timescaledb_internal.compressed_data,
    avg_order_value _timescaledb_internal.compressed_data,
    max_order_value _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_bucket_region _timescaledb_internal.bloom1,
    _ts_meta_v2_bloomh_bucket_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN bucket SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_min_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_min_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_max_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_max_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN region SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN region SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_min_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_min_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_max_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_max_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN order_count SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN total_revenue SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN total_revenue SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN avg_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN avg_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN max_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN max_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STORAGE MAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_276_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_4_276_chunk OWNER TO postgres;

--
-- TOC entry 535 (class 1259 OID 31281)
-- Name: compress_hyper_4_277_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_4_277_chunk (
    _ts_meta_count integer,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    bucket _timescaledb_internal.compressed_data,
    _ts_meta_min_2 text,
    _ts_meta_max_2 text,
    region _timescaledb_internal.compressed_data,
    _ts_meta_min_3 text,
    _ts_meta_max_3 text,
    status _timescaledb_internal.compressed_data,
    order_count _timescaledb_internal.compressed_data,
    total_revenue _timescaledb_internal.compressed_data,
    avg_order_value _timescaledb_internal.compressed_data,
    max_order_value _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_bucket_region _timescaledb_internal.bloom1,
    _ts_meta_v2_bloomh_bucket_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN bucket SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_min_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_min_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_max_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_max_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN region SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN region SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_min_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_min_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_max_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_max_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN order_count SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN total_revenue SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN total_revenue SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN avg_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN avg_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN max_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN max_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STORAGE MAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_277_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_4_277_chunk OWNER TO postgres;

--
-- TOC entry 536 (class 1259 OID 31426)
-- Name: compress_hyper_4_278_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TABLE _timescaledb_internal.compress_hyper_4_278_chunk (
    _ts_meta_count integer,
    _ts_meta_min_1 timestamp with time zone,
    _ts_meta_max_1 timestamp with time zone,
    bucket _timescaledb_internal.compressed_data,
    _ts_meta_min_2 text,
    _ts_meta_max_2 text,
    region _timescaledb_internal.compressed_data,
    _ts_meta_min_3 text,
    _ts_meta_max_3 text,
    status _timescaledb_internal.compressed_data,
    order_count _timescaledb_internal.compressed_data,
    total_revenue _timescaledb_internal.compressed_data,
    avg_order_value _timescaledb_internal.compressed_data,
    max_order_value _timescaledb_internal.compressed_data,
    _ts_meta_v2_bloomh_bucket_region _timescaledb_internal.bloom1,
    _ts_meta_v2_bloomh_bucket_status _timescaledb_internal.bloom1
)
WITH (toast_tuple_target='128');
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_count SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_min_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_max_1 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN bucket SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_min_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_min_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_max_2 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_max_2 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN region SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN region SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_min_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_min_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_max_3 SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_max_3 SET STORAGE PLAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN status SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN status SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN order_count SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN total_revenue SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN total_revenue SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN avg_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN avg_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN max_order_value SET STATISTICS 0;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN max_order_value SET STORAGE EXTENDED;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_region SET STORAGE MAIN;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STATISTICS 1000;
ALTER TABLE ONLY _timescaledb_internal.compress_hyper_4_278_chunk ALTER COLUMN _ts_meta_v2_bloomh_bucket_status SET STORAGE MAIN;


ALTER TABLE _timescaledb_internal.compress_hyper_4_278_chunk OWNER TO postgres;

--
-- TOC entry 357 (class 1259 OID 22123)
-- Name: bloat_test; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bloat_test (
    id integer NOT NULL,
    customer_id integer,
    notes text,
    amount numeric(10,2),
    updated_at timestamp with time zone DEFAULT now()
)
WITH (autovacuum_enabled='false');


ALTER TABLE public.bloat_test OWNER TO postgres;

--
-- TOC entry 356 (class 1259 OID 22122)
-- Name: bloat_test_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.bloat_test_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.bloat_test_id_seq OWNER TO postgres;

--
-- TOC entry 6813 (class 0 OID 0)
-- Dependencies: 356
-- Name: bloat_test_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.bloat_test_id_seq OWNED BY public.bloat_test.id;


--
-- TOC entry 298 (class 1259 OID 18943)
-- Name: customers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customers (
    customer_id integer NOT NULL,
    name text NOT NULL,
    email text NOT NULL,
    country text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.customers OWNER TO postgres;

--
-- TOC entry 297 (class 1259 OID 18942)
-- Name: customers_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.customers_customer_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customers_customer_id_seq OWNER TO postgres;

--
-- TOC entry 6814 (class 0 OID 0)
-- Dependencies: 297
-- Name: customers_customer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.customers_customer_id_seq OWNED BY public.customers.customer_id;


--
-- TOC entry 301 (class 1259 OID 18972)
-- Name: order_events_event_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.order_events_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.order_events_event_id_seq OWNER TO postgres;

--
-- TOC entry 6815 (class 0 OID 0)
-- Dependencies: 301
-- Name: order_events_event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.order_events_event_id_seq OWNED BY public.order_events.event_id;


--
-- TOC entry 538 (class 1259 OID 31988)
-- Name: order_events_archive; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_events_archive (
    event_id bigint DEFAULT nextval('public.order_events_event_id_seq'::regclass) CONSTRAINT order_events_event_id_not_null NOT NULL,
    event_time timestamp with time zone DEFAULT now() CONSTRAINT order_events_event_time_not_null NOT NULL,
    customer_id integer,
    product_id integer,
    quantity integer CONSTRAINT order_events_quantity_not_null NOT NULL,
    total_amount numeric(10,2) CONSTRAINT order_events_total_amount_not_null NOT NULL,
    status text CONSTRAINT order_events_status_not_null NOT NULL,
    region text CONSTRAINT order_events_region_not_null NOT NULL
);


ALTER TABLE public.order_events_archive OWNER TO postgres;

--
-- TOC entry 540 (class 1259 OID 32010)
-- Name: order_events_audit; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_events_audit (
    audit_id bigint NOT NULL,
    operation text NOT NULL,
    deleted_at timestamp with time zone DEFAULT now(),
    deleted_by text DEFAULT CURRENT_USER,
    original_event_id bigint,
    original_event_time timestamp with time zone,
    original_customer_id integer,
    original_total_amount numeric,
    original_status text,
    original_region text
);


ALTER TABLE public.order_events_audit OWNER TO postgres;

--
-- TOC entry 539 (class 1259 OID 32009)
-- Name: order_events_audit_audit_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.order_events_audit_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.order_events_audit_audit_id_seq OWNER TO postgres;

--
-- TOC entry 6816 (class 0 OID 0)
-- Dependencies: 539
-- Name: order_events_audit_audit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.order_events_audit_audit_id_seq OWNED BY public.order_events_audit.audit_id;


--
-- TOC entry 512 (class 1259 OID 30566)
-- Name: order_summary_hourly; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.order_summary_hourly AS
 SELECT bucket,
    region,
    status,
    order_count,
    total_revenue,
    avg_order_value,
    max_order_value
   FROM _timescaledb_internal._materialized_hypertable_3;


ALTER VIEW public.order_summary_hourly OWNER TO postgres;

--
-- TOC entry 542 (class 1259 OID 32488)
-- Name: product_embeddings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.product_embeddings (
    embedding_id bigint NOT NULL,
    product_id integer,
    product_name text NOT NULL,
    category text NOT NULL,
    description text,
    embedding public.vector(128),
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.product_embeddings OWNER TO postgres;

--
-- TOC entry 541 (class 1259 OID 32487)
-- Name: product_embeddings_embedding_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.product_embeddings_embedding_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.product_embeddings_embedding_id_seq OWNER TO postgres;

--
-- TOC entry 6817 (class 0 OID 0)
-- Dependencies: 541
-- Name: product_embeddings_embedding_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.product_embeddings_embedding_id_seq OWNED BY public.product_embeddings.embedding_id;


--
-- TOC entry 300 (class 1259 OID 18959)
-- Name: products; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.products (
    product_id integer NOT NULL,
    name text NOT NULL,
    category text NOT NULL,
    price numeric(10,2) NOT NULL
);


ALTER TABLE public.products OWNER TO postgres;

--
-- TOC entry 299 (class 1259 OID 18958)
-- Name: products_product_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.products_product_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.products_product_id_seq OWNER TO postgres;

--
-- TOC entry 6818 (class 0 OID 0)
-- Dependencies: 299
-- Name: products_product_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.products_product_id_seq OWNED BY public.products.product_id;


--
-- TOC entry 5100 (class 2604 OID 23703)
-- Name: _hyper_1_106_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_106_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5101 (class 2604 OID 23704)
-- Name: _hyper_1_106_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_106_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5102 (class 2604 OID 23732)
-- Name: _hyper_1_107_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_107_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5103 (class 2604 OID 23733)
-- Name: _hyper_1_107_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_107_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5104 (class 2604 OID 23761)
-- Name: _hyper_1_108_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_108_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5105 (class 2604 OID 23762)
-- Name: _hyper_1_108_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_108_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5106 (class 2604 OID 23790)
-- Name: _hyper_1_109_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_109_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5107 (class 2604 OID 23791)
-- Name: _hyper_1_109_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_109_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5010 (class 2604 OID 19228)
-- Name: _hyper_1_10_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_10_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5011 (class 2604 OID 19229)
-- Name: _hyper_1_10_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_10_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5108 (class 2604 OID 23819)
-- Name: _hyper_1_110_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_110_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5109 (class 2604 OID 23820)
-- Name: _hyper_1_110_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_110_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5110 (class 2604 OID 23848)
-- Name: _hyper_1_111_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_111_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5111 (class 2604 OID 23849)
-- Name: _hyper_1_111_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_111_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5112 (class 2604 OID 23877)
-- Name: _hyper_1_112_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_112_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5113 (class 2604 OID 23878)
-- Name: _hyper_1_112_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_112_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5114 (class 2604 OID 23906)
-- Name: _hyper_1_113_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_113_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5115 (class 2604 OID 23907)
-- Name: _hyper_1_113_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_113_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5116 (class 2604 OID 23935)
-- Name: _hyper_1_114_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_114_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5117 (class 2604 OID 23936)
-- Name: _hyper_1_114_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_114_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5118 (class 2604 OID 23964)
-- Name: _hyper_1_115_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_115_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5119 (class 2604 OID 23965)
-- Name: _hyper_1_115_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_115_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5120 (class 2604 OID 23993)
-- Name: _hyper_1_116_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_116_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5121 (class 2604 OID 23994)
-- Name: _hyper_1_116_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_116_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5122 (class 2604 OID 24022)
-- Name: _hyper_1_117_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_117_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5123 (class 2604 OID 24023)
-- Name: _hyper_1_117_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_117_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5124 (class 2604 OID 24051)
-- Name: _hyper_1_118_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_118_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5125 (class 2604 OID 24052)
-- Name: _hyper_1_118_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_118_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5126 (class 2604 OID 24080)
-- Name: _hyper_1_119_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_119_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5127 (class 2604 OID 24081)
-- Name: _hyper_1_119_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_119_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5012 (class 2604 OID 19253)
-- Name: _hyper_1_11_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_11_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5013 (class 2604 OID 19254)
-- Name: _hyper_1_11_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_11_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5128 (class 2604 OID 24109)
-- Name: _hyper_1_120_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_120_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5129 (class 2604 OID 24110)
-- Name: _hyper_1_120_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_120_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5130 (class 2604 OID 24138)
-- Name: _hyper_1_121_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_121_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5131 (class 2604 OID 24139)
-- Name: _hyper_1_121_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_121_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5132 (class 2604 OID 24167)
-- Name: _hyper_1_122_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_122_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5133 (class 2604 OID 24168)
-- Name: _hyper_1_122_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_122_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5134 (class 2604 OID 24196)
-- Name: _hyper_1_123_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_123_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5135 (class 2604 OID 24197)
-- Name: _hyper_1_123_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_123_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5136 (class 2604 OID 24225)
-- Name: _hyper_1_124_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_124_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5137 (class 2604 OID 24226)
-- Name: _hyper_1_124_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_124_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5138 (class 2604 OID 24254)
-- Name: _hyper_1_125_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_125_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5139 (class 2604 OID 24255)
-- Name: _hyper_1_125_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_125_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5140 (class 2604 OID 24283)
-- Name: _hyper_1_126_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_126_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5141 (class 2604 OID 24284)
-- Name: _hyper_1_126_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_126_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5142 (class 2604 OID 24312)
-- Name: _hyper_1_127_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_127_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5143 (class 2604 OID 24313)
-- Name: _hyper_1_127_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_127_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5144 (class 2604 OID 24341)
-- Name: _hyper_1_128_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_128_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5145 (class 2604 OID 24342)
-- Name: _hyper_1_128_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_128_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5146 (class 2604 OID 24370)
-- Name: _hyper_1_129_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_129_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5147 (class 2604 OID 24371)
-- Name: _hyper_1_129_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_129_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5014 (class 2604 OID 19278)
-- Name: _hyper_1_12_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_12_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5015 (class 2604 OID 19279)
-- Name: _hyper_1_12_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_12_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5148 (class 2604 OID 24399)
-- Name: _hyper_1_130_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_130_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5149 (class 2604 OID 24400)
-- Name: _hyper_1_130_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_130_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5150 (class 2604 OID 24428)
-- Name: _hyper_1_131_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_131_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5151 (class 2604 OID 24429)
-- Name: _hyper_1_131_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_131_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5152 (class 2604 OID 24457)
-- Name: _hyper_1_132_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_132_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5153 (class 2604 OID 24458)
-- Name: _hyper_1_132_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_132_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5154 (class 2604 OID 24486)
-- Name: _hyper_1_133_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_133_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5155 (class 2604 OID 24487)
-- Name: _hyper_1_133_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_133_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5156 (class 2604 OID 24515)
-- Name: _hyper_1_134_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_134_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5157 (class 2604 OID 24516)
-- Name: _hyper_1_134_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_134_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5158 (class 2604 OID 24544)
-- Name: _hyper_1_135_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_135_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5159 (class 2604 OID 24545)
-- Name: _hyper_1_135_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_135_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5160 (class 2604 OID 24573)
-- Name: _hyper_1_136_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_136_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5161 (class 2604 OID 24574)
-- Name: _hyper_1_136_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_136_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5162 (class 2604 OID 24602)
-- Name: _hyper_1_137_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_137_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5163 (class 2604 OID 24603)
-- Name: _hyper_1_137_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_137_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5164 (class 2604 OID 24631)
-- Name: _hyper_1_138_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_138_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5165 (class 2604 OID 24632)
-- Name: _hyper_1_138_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_138_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5166 (class 2604 OID 24660)
-- Name: _hyper_1_139_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_139_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5167 (class 2604 OID 24661)
-- Name: _hyper_1_139_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_139_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5016 (class 2604 OID 19303)
-- Name: _hyper_1_13_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_13_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5017 (class 2604 OID 19304)
-- Name: _hyper_1_13_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_13_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5168 (class 2604 OID 24689)
-- Name: _hyper_1_140_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_140_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5169 (class 2604 OID 24690)
-- Name: _hyper_1_140_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_140_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5170 (class 2604 OID 24718)
-- Name: _hyper_1_141_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_141_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5171 (class 2604 OID 24719)
-- Name: _hyper_1_141_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_141_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5172 (class 2604 OID 24747)
-- Name: _hyper_1_142_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_142_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5173 (class 2604 OID 24748)
-- Name: _hyper_1_142_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_142_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5174 (class 2604 OID 24776)
-- Name: _hyper_1_143_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_143_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5175 (class 2604 OID 24777)
-- Name: _hyper_1_143_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_143_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5176 (class 2604 OID 24805)
-- Name: _hyper_1_144_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_144_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5177 (class 2604 OID 24806)
-- Name: _hyper_1_144_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_144_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5178 (class 2604 OID 24834)
-- Name: _hyper_1_145_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_145_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5179 (class 2604 OID 24835)
-- Name: _hyper_1_145_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_145_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5180 (class 2604 OID 24863)
-- Name: _hyper_1_146_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_146_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5181 (class 2604 OID 24864)
-- Name: _hyper_1_146_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_146_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5182 (class 2604 OID 24892)
-- Name: _hyper_1_147_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_147_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5183 (class 2604 OID 24893)
-- Name: _hyper_1_147_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_147_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5184 (class 2604 OID 24921)
-- Name: _hyper_1_148_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_148_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5185 (class 2604 OID 24922)
-- Name: _hyper_1_148_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_148_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5186 (class 2604 OID 24950)
-- Name: _hyper_1_149_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_149_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5187 (class 2604 OID 24951)
-- Name: _hyper_1_149_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_149_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5018 (class 2604 OID 19328)
-- Name: _hyper_1_14_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_14_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5019 (class 2604 OID 19329)
-- Name: _hyper_1_14_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_14_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5188 (class 2604 OID 24979)
-- Name: _hyper_1_150_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_150_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5189 (class 2604 OID 24980)
-- Name: _hyper_1_150_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_150_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5190 (class 2604 OID 25008)
-- Name: _hyper_1_151_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_151_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5191 (class 2604 OID 25009)
-- Name: _hyper_1_151_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_151_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5192 (class 2604 OID 25037)
-- Name: _hyper_1_152_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_152_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5193 (class 2604 OID 25038)
-- Name: _hyper_1_152_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_152_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5194 (class 2604 OID 25066)
-- Name: _hyper_1_153_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_153_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5195 (class 2604 OID 25067)
-- Name: _hyper_1_153_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_153_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5196 (class 2604 OID 25095)
-- Name: _hyper_1_154_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_154_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5197 (class 2604 OID 25096)
-- Name: _hyper_1_154_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_154_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5198 (class 2604 OID 25124)
-- Name: _hyper_1_155_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_155_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5199 (class 2604 OID 25125)
-- Name: _hyper_1_155_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_155_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5200 (class 2604 OID 25153)
-- Name: _hyper_1_156_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_156_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5201 (class 2604 OID 25154)
-- Name: _hyper_1_156_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_156_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5202 (class 2604 OID 25182)
-- Name: _hyper_1_157_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_157_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5203 (class 2604 OID 25183)
-- Name: _hyper_1_157_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_157_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5020 (class 2604 OID 19353)
-- Name: _hyper_1_15_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_15_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5021 (class 2604 OID 19354)
-- Name: _hyper_1_15_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_15_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5022 (class 2604 OID 19378)
-- Name: _hyper_1_16_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_16_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5023 (class 2604 OID 19379)
-- Name: _hyper_1_16_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_16_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5024 (class 2604 OID 19403)
-- Name: _hyper_1_17_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_17_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5025 (class 2604 OID 19404)
-- Name: _hyper_1_17_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_17_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5026 (class 2604 OID 19428)
-- Name: _hyper_1_18_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_18_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5027 (class 2604 OID 19429)
-- Name: _hyper_1_18_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_18_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5028 (class 2604 OID 19453)
-- Name: _hyper_1_19_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_19_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5029 (class 2604 OID 19454)
-- Name: _hyper_1_19_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_19_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 4992 (class 2604 OID 19003)
-- Name: _hyper_1_1_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_1_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 4993 (class 2604 OID 19004)
-- Name: _hyper_1_1_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_1_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5030 (class 2604 OID 19478)
-- Name: _hyper_1_20_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_20_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5031 (class 2604 OID 19479)
-- Name: _hyper_1_20_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_20_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5032 (class 2604 OID 19503)
-- Name: _hyper_1_21_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_21_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5033 (class 2604 OID 19504)
-- Name: _hyper_1_21_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_21_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5034 (class 2604 OID 19528)
-- Name: _hyper_1_22_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_22_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5035 (class 2604 OID 19529)
-- Name: _hyper_1_22_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_22_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5036 (class 2604 OID 19553)
-- Name: _hyper_1_23_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_23_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5037 (class 2604 OID 19554)
-- Name: _hyper_1_23_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_23_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5038 (class 2604 OID 19578)
-- Name: _hyper_1_24_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_24_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5039 (class 2604 OID 19579)
-- Name: _hyper_1_24_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_24_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5040 (class 2604 OID 19603)
-- Name: _hyper_1_25_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_25_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5041 (class 2604 OID 19604)
-- Name: _hyper_1_25_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_25_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5042 (class 2604 OID 19628)
-- Name: _hyper_1_26_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_26_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5043 (class 2604 OID 19629)
-- Name: _hyper_1_26_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_26_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5044 (class 2604 OID 19653)
-- Name: _hyper_1_27_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_27_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5045 (class 2604 OID 19654)
-- Name: _hyper_1_27_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_27_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5046 (class 2604 OID 19678)
-- Name: _hyper_1_28_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_28_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5047 (class 2604 OID 19679)
-- Name: _hyper_1_28_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_28_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5048 (class 2604 OID 19703)
-- Name: _hyper_1_29_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_29_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5049 (class 2604 OID 19704)
-- Name: _hyper_1_29_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_29_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 4994 (class 2604 OID 19028)
-- Name: _hyper_1_2_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_2_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 4995 (class 2604 OID 19029)
-- Name: _hyper_1_2_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_2_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5050 (class 2604 OID 19728)
-- Name: _hyper_1_30_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_30_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5051 (class 2604 OID 19729)
-- Name: _hyper_1_30_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_30_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5052 (class 2604 OID 19753)
-- Name: _hyper_1_31_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_31_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5053 (class 2604 OID 19754)
-- Name: _hyper_1_31_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_31_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5054 (class 2604 OID 19778)
-- Name: _hyper_1_32_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_32_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5055 (class 2604 OID 19779)
-- Name: _hyper_1_32_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_32_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5056 (class 2604 OID 19803)
-- Name: _hyper_1_33_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_33_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5057 (class 2604 OID 19804)
-- Name: _hyper_1_33_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_33_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5058 (class 2604 OID 19828)
-- Name: _hyper_1_34_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_34_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5059 (class 2604 OID 19829)
-- Name: _hyper_1_34_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_34_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5060 (class 2604 OID 19853)
-- Name: _hyper_1_35_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_35_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5061 (class 2604 OID 19854)
-- Name: _hyper_1_35_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_35_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5062 (class 2604 OID 19878)
-- Name: _hyper_1_36_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_36_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5063 (class 2604 OID 19879)
-- Name: _hyper_1_36_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_36_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5064 (class 2604 OID 19903)
-- Name: _hyper_1_37_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_37_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5065 (class 2604 OID 19904)
-- Name: _hyper_1_37_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_37_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5066 (class 2604 OID 19928)
-- Name: _hyper_1_38_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_38_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5067 (class 2604 OID 19929)
-- Name: _hyper_1_38_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_38_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5068 (class 2604 OID 19953)
-- Name: _hyper_1_39_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_39_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5069 (class 2604 OID 19954)
-- Name: _hyper_1_39_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_39_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 4996 (class 2604 OID 19053)
-- Name: _hyper_1_3_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_3_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 4997 (class 2604 OID 19054)
-- Name: _hyper_1_3_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_3_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5070 (class 2604 OID 19978)
-- Name: _hyper_1_40_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_40_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5071 (class 2604 OID 19979)
-- Name: _hyper_1_40_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_40_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5072 (class 2604 OID 20003)
-- Name: _hyper_1_41_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_41_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5073 (class 2604 OID 20004)
-- Name: _hyper_1_41_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_41_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5074 (class 2604 OID 20028)
-- Name: _hyper_1_42_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_42_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5075 (class 2604 OID 20029)
-- Name: _hyper_1_42_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_42_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5076 (class 2604 OID 20053)
-- Name: _hyper_1_43_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_43_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5077 (class 2604 OID 20054)
-- Name: _hyper_1_43_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_43_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5078 (class 2604 OID 20078)
-- Name: _hyper_1_44_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_44_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5079 (class 2604 OID 20079)
-- Name: _hyper_1_44_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_44_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5080 (class 2604 OID 20103)
-- Name: _hyper_1_45_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_45_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5081 (class 2604 OID 20104)
-- Name: _hyper_1_45_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_45_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5082 (class 2604 OID 20128)
-- Name: _hyper_1_46_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_46_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5083 (class 2604 OID 20129)
-- Name: _hyper_1_46_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_46_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5084 (class 2604 OID 20153)
-- Name: _hyper_1_47_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_47_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5085 (class 2604 OID 20154)
-- Name: _hyper_1_47_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_47_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5086 (class 2604 OID 20178)
-- Name: _hyper_1_48_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_48_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5087 (class 2604 OID 20179)
-- Name: _hyper_1_48_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_48_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5088 (class 2604 OID 20203)
-- Name: _hyper_1_49_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_49_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5089 (class 2604 OID 20204)
-- Name: _hyper_1_49_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_49_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 4998 (class 2604 OID 19078)
-- Name: _hyper_1_4_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_4_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 4999 (class 2604 OID 19079)
-- Name: _hyper_1_4_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_4_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5090 (class 2604 OID 20228)
-- Name: _hyper_1_50_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_50_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5091 (class 2604 OID 20229)
-- Name: _hyper_1_50_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_50_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5092 (class 2604 OID 20253)
-- Name: _hyper_1_51_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_51_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5093 (class 2604 OID 20254)
-- Name: _hyper_1_51_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_51_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5094 (class 2604 OID 20278)
-- Name: _hyper_1_52_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_52_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5095 (class 2604 OID 20279)
-- Name: _hyper_1_52_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_52_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5096 (class 2604 OID 20303)
-- Name: _hyper_1_53_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_53_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5097 (class 2604 OID 20304)
-- Name: _hyper_1_53_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_53_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5000 (class 2604 OID 19103)
-- Name: _hyper_1_5_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5001 (class 2604 OID 19104)
-- Name: _hyper_1_5_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5002 (class 2604 OID 19128)
-- Name: _hyper_1_6_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_6_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5003 (class 2604 OID 19129)
-- Name: _hyper_1_6_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_6_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5004 (class 2604 OID 19153)
-- Name: _hyper_1_7_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_7_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5005 (class 2604 OID 19154)
-- Name: _hyper_1_7_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_7_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5006 (class 2604 OID 19178)
-- Name: _hyper_1_8_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_8_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5007 (class 2604 OID 19179)
-- Name: _hyper_1_8_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_8_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5008 (class 2604 OID 19203)
-- Name: _hyper_1_9_chunk event_id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_9_chunk ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5009 (class 2604 OID 19204)
-- Name: _hyper_1_9_chunk event_time; Type: DEFAULT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_9_chunk ALTER COLUMN event_time SET DEFAULT now();


--
-- TOC entry 5098 (class 2604 OID 22126)
-- Name: bloat_test id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bloat_test ALTER COLUMN id SET DEFAULT nextval('public.bloat_test_id_seq'::regclass);


--
-- TOC entry 4987 (class 2604 OID 18946)
-- Name: customers customer_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers ALTER COLUMN customer_id SET DEFAULT nextval('public.customers_customer_id_seq'::regclass);


--
-- TOC entry 4990 (class 2604 OID 18976)
-- Name: order_events event_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_events ALTER COLUMN event_id SET DEFAULT nextval('public.order_events_event_id_seq'::regclass);


--
-- TOC entry 5206 (class 2604 OID 32013)
-- Name: order_events_audit audit_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_events_audit ALTER COLUMN audit_id SET DEFAULT nextval('public.order_events_audit_audit_id_seq'::regclass);


--
-- TOC entry 5209 (class 2604 OID 32491)
-- Name: product_embeddings embedding_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_embeddings ALTER COLUMN embedding_id SET DEFAULT nextval('public.product_embeddings_embedding_id_seq'::regclass);


--
-- TOC entry 4989 (class 2604 OID 18962)
-- Name: products product_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products ALTER COLUMN product_id SET DEFAULT nextval('public.products_product_id_seq'::regclass);


--
-- TOC entry 5792 (class 2606 OID 22132)
-- Name: bloat_test bloat_test_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bloat_test
    ADD CONSTRAINT bloat_test_pkey PRIMARY KEY (id);


--
-- TOC entry 5408 (class 2606 OID 18957)
-- Name: customers customers_email_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_email_key UNIQUE (email);


--
-- TOC entry 5410 (class 2606 OID 18955)
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (customer_id);


--
-- TOC entry 6312 (class 2606 OID 32021)
-- Name: order_events_audit order_events_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_events_audit
    ADD CONSTRAINT order_events_audit_pkey PRIMARY KEY (audit_id);


--
-- TOC entry 6316 (class 2606 OID 32499)
-- Name: product_embeddings product_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_embeddings
    ADD CONSTRAINT product_embeddings_pkey PRIMARY KEY (embedding_id);


--
-- TOC entry 5412 (class 2606 OID 18970)
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (product_id);


--
-- TOC entry 5793 (class 1259 OID 23728)
-- Name: _hyper_1_106_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_106_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_106_chunk USING btree (customer_id);


--
-- TOC entry 5794 (class 1259 OID 23727)
-- Name: _hyper_1_106_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_106_chunk_idx_order_region ON _timescaledb_internal._hyper_1_106_chunk USING btree (region);


--
-- TOC entry 5795 (class 1259 OID 23726)
-- Name: _hyper_1_106_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_106_chunk_idx_order_status ON _timescaledb_internal._hyper_1_106_chunk USING btree (status);


--
-- TOC entry 5796 (class 1259 OID 31746)
-- Name: _hyper_1_106_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_106_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_106_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5797 (class 1259 OID 23725)
-- Name: _hyper_1_106_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_106_chunk_idx_status_region ON _timescaledb_internal._hyper_1_106_chunk USING btree (status, region);


--
-- TOC entry 5798 (class 1259 OID 31852)
-- Name: _hyper_1_106_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_106_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_106_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5799 (class 1259 OID 23724)
-- Name: _hyper_1_106_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_106_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_106_chunk USING btree (event_time DESC);


--
-- TOC entry 5800 (class 1259 OID 23757)
-- Name: _hyper_1_107_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_107_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_107_chunk USING btree (customer_id);


--
-- TOC entry 5801 (class 1259 OID 23756)
-- Name: _hyper_1_107_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_107_chunk_idx_order_region ON _timescaledb_internal._hyper_1_107_chunk USING btree (region);


--
-- TOC entry 5802 (class 1259 OID 23755)
-- Name: _hyper_1_107_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_107_chunk_idx_order_status ON _timescaledb_internal._hyper_1_107_chunk USING btree (status);


--
-- TOC entry 5803 (class 1259 OID 31747)
-- Name: _hyper_1_107_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_107_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_107_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5804 (class 1259 OID 23754)
-- Name: _hyper_1_107_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_107_chunk_idx_status_region ON _timescaledb_internal._hyper_1_107_chunk USING btree (status, region);


--
-- TOC entry 5805 (class 1259 OID 31853)
-- Name: _hyper_1_107_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_107_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_107_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5806 (class 1259 OID 23753)
-- Name: _hyper_1_107_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_107_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_107_chunk USING btree (event_time DESC);


--
-- TOC entry 5807 (class 1259 OID 23786)
-- Name: _hyper_1_108_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_108_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_108_chunk USING btree (customer_id);


--
-- TOC entry 5808 (class 1259 OID 23785)
-- Name: _hyper_1_108_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_108_chunk_idx_order_region ON _timescaledb_internal._hyper_1_108_chunk USING btree (region);


--
-- TOC entry 5809 (class 1259 OID 23784)
-- Name: _hyper_1_108_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_108_chunk_idx_order_status ON _timescaledb_internal._hyper_1_108_chunk USING btree (status);


--
-- TOC entry 5810 (class 1259 OID 31748)
-- Name: _hyper_1_108_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_108_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_108_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5811 (class 1259 OID 23783)
-- Name: _hyper_1_108_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_108_chunk_idx_status_region ON _timescaledb_internal._hyper_1_108_chunk USING btree (status, region);


--
-- TOC entry 5812 (class 1259 OID 31854)
-- Name: _hyper_1_108_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_108_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_108_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5813 (class 1259 OID 23782)
-- Name: _hyper_1_108_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_108_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_108_chunk USING btree (event_time DESC);


--
-- TOC entry 5814 (class 1259 OID 23815)
-- Name: _hyper_1_109_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_109_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_109_chunk USING btree (customer_id);


--
-- TOC entry 5815 (class 1259 OID 23814)
-- Name: _hyper_1_109_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_109_chunk_idx_order_region ON _timescaledb_internal._hyper_1_109_chunk USING btree (region);


--
-- TOC entry 5816 (class 1259 OID 23813)
-- Name: _hyper_1_109_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_109_chunk_idx_order_status ON _timescaledb_internal._hyper_1_109_chunk USING btree (status);


--
-- TOC entry 5817 (class 1259 OID 31749)
-- Name: _hyper_1_109_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_109_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_109_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5818 (class 1259 OID 23812)
-- Name: _hyper_1_109_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_109_chunk_idx_status_region ON _timescaledb_internal._hyper_1_109_chunk USING btree (status, region);


--
-- TOC entry 5819 (class 1259 OID 31855)
-- Name: _hyper_1_109_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_109_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_109_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5820 (class 1259 OID 23811)
-- Name: _hyper_1_109_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_109_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_109_chunk USING btree (event_time DESC);


--
-- TOC entry 5483 (class 1259 OID 21007)
-- Name: _hyper_1_10_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_10_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_10_chunk USING btree (customer_id);


--
-- TOC entry 5484 (class 1259 OID 20952)
-- Name: _hyper_1_10_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_10_chunk_idx_order_region ON _timescaledb_internal._hyper_1_10_chunk USING btree (region);


--
-- TOC entry 5485 (class 1259 OID 20898)
-- Name: _hyper_1_10_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_10_chunk_idx_order_status ON _timescaledb_internal._hyper_1_10_chunk USING btree (status);


--
-- TOC entry 5486 (class 1259 OID 31702)
-- Name: _hyper_1_10_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_10_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_10_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5487 (class 1259 OID 20838)
-- Name: _hyper_1_10_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_10_chunk_idx_status_region ON _timescaledb_internal._hyper_1_10_chunk USING btree (status, region);


--
-- TOC entry 5488 (class 1259 OID 31808)
-- Name: _hyper_1_10_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_10_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_10_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5489 (class 1259 OID 19249)
-- Name: _hyper_1_10_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_10_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_10_chunk USING btree (event_time DESC);


--
-- TOC entry 5821 (class 1259 OID 23844)
-- Name: _hyper_1_110_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_110_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_110_chunk USING btree (customer_id);


--
-- TOC entry 5822 (class 1259 OID 23843)
-- Name: _hyper_1_110_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_110_chunk_idx_order_region ON _timescaledb_internal._hyper_1_110_chunk USING btree (region);


--
-- TOC entry 5823 (class 1259 OID 23842)
-- Name: _hyper_1_110_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_110_chunk_idx_order_status ON _timescaledb_internal._hyper_1_110_chunk USING btree (status);


--
-- TOC entry 5824 (class 1259 OID 31750)
-- Name: _hyper_1_110_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_110_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_110_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5825 (class 1259 OID 23841)
-- Name: _hyper_1_110_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_110_chunk_idx_status_region ON _timescaledb_internal._hyper_1_110_chunk USING btree (status, region);


--
-- TOC entry 5826 (class 1259 OID 31856)
-- Name: _hyper_1_110_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_110_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_110_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5827 (class 1259 OID 23840)
-- Name: _hyper_1_110_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_110_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_110_chunk USING btree (event_time DESC);


--
-- TOC entry 5828 (class 1259 OID 23873)
-- Name: _hyper_1_111_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_111_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_111_chunk USING btree (customer_id);


--
-- TOC entry 5829 (class 1259 OID 23872)
-- Name: _hyper_1_111_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_111_chunk_idx_order_region ON _timescaledb_internal._hyper_1_111_chunk USING btree (region);


--
-- TOC entry 5830 (class 1259 OID 23871)
-- Name: _hyper_1_111_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_111_chunk_idx_order_status ON _timescaledb_internal._hyper_1_111_chunk USING btree (status);


--
-- TOC entry 5831 (class 1259 OID 31751)
-- Name: _hyper_1_111_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_111_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_111_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5832 (class 1259 OID 23870)
-- Name: _hyper_1_111_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_111_chunk_idx_status_region ON _timescaledb_internal._hyper_1_111_chunk USING btree (status, region);


--
-- TOC entry 5833 (class 1259 OID 31857)
-- Name: _hyper_1_111_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_111_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_111_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5834 (class 1259 OID 23869)
-- Name: _hyper_1_111_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_111_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_111_chunk USING btree (event_time DESC);


--
-- TOC entry 5835 (class 1259 OID 23902)
-- Name: _hyper_1_112_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_112_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_112_chunk USING btree (customer_id);


--
-- TOC entry 5836 (class 1259 OID 23901)
-- Name: _hyper_1_112_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_112_chunk_idx_order_region ON _timescaledb_internal._hyper_1_112_chunk USING btree (region);


--
-- TOC entry 5837 (class 1259 OID 23900)
-- Name: _hyper_1_112_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_112_chunk_idx_order_status ON _timescaledb_internal._hyper_1_112_chunk USING btree (status);


--
-- TOC entry 5838 (class 1259 OID 31752)
-- Name: _hyper_1_112_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_112_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_112_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5839 (class 1259 OID 23899)
-- Name: _hyper_1_112_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_112_chunk_idx_status_region ON _timescaledb_internal._hyper_1_112_chunk USING btree (status, region);


--
-- TOC entry 5840 (class 1259 OID 31858)
-- Name: _hyper_1_112_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_112_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_112_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5841 (class 1259 OID 23898)
-- Name: _hyper_1_112_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_112_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_112_chunk USING btree (event_time DESC);


--
-- TOC entry 5842 (class 1259 OID 23931)
-- Name: _hyper_1_113_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_113_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_113_chunk USING btree (customer_id);


--
-- TOC entry 5843 (class 1259 OID 23930)
-- Name: _hyper_1_113_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_113_chunk_idx_order_region ON _timescaledb_internal._hyper_1_113_chunk USING btree (region);


--
-- TOC entry 5844 (class 1259 OID 23929)
-- Name: _hyper_1_113_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_113_chunk_idx_order_status ON _timescaledb_internal._hyper_1_113_chunk USING btree (status);


--
-- TOC entry 5845 (class 1259 OID 31753)
-- Name: _hyper_1_113_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_113_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_113_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5846 (class 1259 OID 23928)
-- Name: _hyper_1_113_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_113_chunk_idx_status_region ON _timescaledb_internal._hyper_1_113_chunk USING btree (status, region);


--
-- TOC entry 5847 (class 1259 OID 31859)
-- Name: _hyper_1_113_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_113_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_113_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5848 (class 1259 OID 23927)
-- Name: _hyper_1_113_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_113_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_113_chunk USING btree (event_time DESC);


--
-- TOC entry 5849 (class 1259 OID 23960)
-- Name: _hyper_1_114_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_114_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_114_chunk USING btree (customer_id);


--
-- TOC entry 5850 (class 1259 OID 23959)
-- Name: _hyper_1_114_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_114_chunk_idx_order_region ON _timescaledb_internal._hyper_1_114_chunk USING btree (region);


--
-- TOC entry 5851 (class 1259 OID 23958)
-- Name: _hyper_1_114_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_114_chunk_idx_order_status ON _timescaledb_internal._hyper_1_114_chunk USING btree (status);


--
-- TOC entry 5852 (class 1259 OID 31754)
-- Name: _hyper_1_114_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_114_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_114_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5853 (class 1259 OID 23957)
-- Name: _hyper_1_114_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_114_chunk_idx_status_region ON _timescaledb_internal._hyper_1_114_chunk USING btree (status, region);


--
-- TOC entry 5854 (class 1259 OID 31860)
-- Name: _hyper_1_114_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_114_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_114_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5855 (class 1259 OID 23956)
-- Name: _hyper_1_114_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_114_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_114_chunk USING btree (event_time DESC);


--
-- TOC entry 5856 (class 1259 OID 23989)
-- Name: _hyper_1_115_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_115_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_115_chunk USING btree (customer_id);


--
-- TOC entry 5857 (class 1259 OID 23988)
-- Name: _hyper_1_115_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_115_chunk_idx_order_region ON _timescaledb_internal._hyper_1_115_chunk USING btree (region);


--
-- TOC entry 5858 (class 1259 OID 23987)
-- Name: _hyper_1_115_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_115_chunk_idx_order_status ON _timescaledb_internal._hyper_1_115_chunk USING btree (status);


--
-- TOC entry 5859 (class 1259 OID 31755)
-- Name: _hyper_1_115_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_115_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_115_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5860 (class 1259 OID 23986)
-- Name: _hyper_1_115_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_115_chunk_idx_status_region ON _timescaledb_internal._hyper_1_115_chunk USING btree (status, region);


--
-- TOC entry 5861 (class 1259 OID 31861)
-- Name: _hyper_1_115_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_115_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_115_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5862 (class 1259 OID 23985)
-- Name: _hyper_1_115_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_115_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_115_chunk USING btree (event_time DESC);


--
-- TOC entry 5863 (class 1259 OID 24018)
-- Name: _hyper_1_116_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_116_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_116_chunk USING btree (customer_id);


--
-- TOC entry 5864 (class 1259 OID 24017)
-- Name: _hyper_1_116_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_116_chunk_idx_order_region ON _timescaledb_internal._hyper_1_116_chunk USING btree (region);


--
-- TOC entry 5865 (class 1259 OID 24016)
-- Name: _hyper_1_116_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_116_chunk_idx_order_status ON _timescaledb_internal._hyper_1_116_chunk USING btree (status);


--
-- TOC entry 5866 (class 1259 OID 31756)
-- Name: _hyper_1_116_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_116_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_116_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5867 (class 1259 OID 24015)
-- Name: _hyper_1_116_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_116_chunk_idx_status_region ON _timescaledb_internal._hyper_1_116_chunk USING btree (status, region);


--
-- TOC entry 5868 (class 1259 OID 31862)
-- Name: _hyper_1_116_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_116_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_116_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5869 (class 1259 OID 24014)
-- Name: _hyper_1_116_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_116_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_116_chunk USING btree (event_time DESC);


--
-- TOC entry 5870 (class 1259 OID 24047)
-- Name: _hyper_1_117_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_117_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_117_chunk USING btree (customer_id);


--
-- TOC entry 5871 (class 1259 OID 24046)
-- Name: _hyper_1_117_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_117_chunk_idx_order_region ON _timescaledb_internal._hyper_1_117_chunk USING btree (region);


--
-- TOC entry 5872 (class 1259 OID 24045)
-- Name: _hyper_1_117_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_117_chunk_idx_order_status ON _timescaledb_internal._hyper_1_117_chunk USING btree (status);


--
-- TOC entry 5873 (class 1259 OID 31757)
-- Name: _hyper_1_117_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_117_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_117_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5874 (class 1259 OID 24044)
-- Name: _hyper_1_117_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_117_chunk_idx_status_region ON _timescaledb_internal._hyper_1_117_chunk USING btree (status, region);


--
-- TOC entry 5875 (class 1259 OID 31863)
-- Name: _hyper_1_117_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_117_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_117_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5876 (class 1259 OID 24043)
-- Name: _hyper_1_117_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_117_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_117_chunk USING btree (event_time DESC);


--
-- TOC entry 5877 (class 1259 OID 24076)
-- Name: _hyper_1_118_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_118_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_118_chunk USING btree (customer_id);


--
-- TOC entry 5878 (class 1259 OID 24075)
-- Name: _hyper_1_118_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_118_chunk_idx_order_region ON _timescaledb_internal._hyper_1_118_chunk USING btree (region);


--
-- TOC entry 5879 (class 1259 OID 24074)
-- Name: _hyper_1_118_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_118_chunk_idx_order_status ON _timescaledb_internal._hyper_1_118_chunk USING btree (status);


--
-- TOC entry 5880 (class 1259 OID 31758)
-- Name: _hyper_1_118_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_118_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_118_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5881 (class 1259 OID 24073)
-- Name: _hyper_1_118_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_118_chunk_idx_status_region ON _timescaledb_internal._hyper_1_118_chunk USING btree (status, region);


--
-- TOC entry 5882 (class 1259 OID 31864)
-- Name: _hyper_1_118_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_118_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_118_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5883 (class 1259 OID 24072)
-- Name: _hyper_1_118_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_118_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_118_chunk USING btree (event_time DESC);


--
-- TOC entry 5884 (class 1259 OID 24105)
-- Name: _hyper_1_119_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_119_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_119_chunk USING btree (customer_id);


--
-- TOC entry 5885 (class 1259 OID 24104)
-- Name: _hyper_1_119_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_119_chunk_idx_order_region ON _timescaledb_internal._hyper_1_119_chunk USING btree (region);


--
-- TOC entry 5886 (class 1259 OID 24103)
-- Name: _hyper_1_119_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_119_chunk_idx_order_status ON _timescaledb_internal._hyper_1_119_chunk USING btree (status);


--
-- TOC entry 5887 (class 1259 OID 31759)
-- Name: _hyper_1_119_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_119_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_119_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5888 (class 1259 OID 24102)
-- Name: _hyper_1_119_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_119_chunk_idx_status_region ON _timescaledb_internal._hyper_1_119_chunk USING btree (status, region);


--
-- TOC entry 5889 (class 1259 OID 31865)
-- Name: _hyper_1_119_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_119_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_119_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5890 (class 1259 OID 24101)
-- Name: _hyper_1_119_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_119_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_119_chunk USING btree (event_time DESC);


--
-- TOC entry 5490 (class 1259 OID 21008)
-- Name: _hyper_1_11_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_11_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_11_chunk USING btree (customer_id);


--
-- TOC entry 5491 (class 1259 OID 20953)
-- Name: _hyper_1_11_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_11_chunk_idx_order_region ON _timescaledb_internal._hyper_1_11_chunk USING btree (region);


--
-- TOC entry 5492 (class 1259 OID 20899)
-- Name: _hyper_1_11_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_11_chunk_idx_order_status ON _timescaledb_internal._hyper_1_11_chunk USING btree (status);


--
-- TOC entry 5493 (class 1259 OID 31703)
-- Name: _hyper_1_11_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_11_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_11_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5494 (class 1259 OID 20839)
-- Name: _hyper_1_11_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_11_chunk_idx_status_region ON _timescaledb_internal._hyper_1_11_chunk USING btree (status, region);


--
-- TOC entry 5495 (class 1259 OID 31809)
-- Name: _hyper_1_11_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_11_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_11_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5496 (class 1259 OID 19274)
-- Name: _hyper_1_11_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_11_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_11_chunk USING btree (event_time DESC);


--
-- TOC entry 5891 (class 1259 OID 24134)
-- Name: _hyper_1_120_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_120_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_120_chunk USING btree (customer_id);


--
-- TOC entry 5892 (class 1259 OID 24133)
-- Name: _hyper_1_120_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_120_chunk_idx_order_region ON _timescaledb_internal._hyper_1_120_chunk USING btree (region);


--
-- TOC entry 5893 (class 1259 OID 24132)
-- Name: _hyper_1_120_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_120_chunk_idx_order_status ON _timescaledb_internal._hyper_1_120_chunk USING btree (status);


--
-- TOC entry 5894 (class 1259 OID 31760)
-- Name: _hyper_1_120_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_120_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_120_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5895 (class 1259 OID 24131)
-- Name: _hyper_1_120_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_120_chunk_idx_status_region ON _timescaledb_internal._hyper_1_120_chunk USING btree (status, region);


--
-- TOC entry 5896 (class 1259 OID 31866)
-- Name: _hyper_1_120_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_120_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_120_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5897 (class 1259 OID 24130)
-- Name: _hyper_1_120_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_120_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_120_chunk USING btree (event_time DESC);


--
-- TOC entry 5898 (class 1259 OID 24163)
-- Name: _hyper_1_121_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_121_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_121_chunk USING btree (customer_id);


--
-- TOC entry 5899 (class 1259 OID 24162)
-- Name: _hyper_1_121_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_121_chunk_idx_order_region ON _timescaledb_internal._hyper_1_121_chunk USING btree (region);


--
-- TOC entry 5900 (class 1259 OID 24161)
-- Name: _hyper_1_121_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_121_chunk_idx_order_status ON _timescaledb_internal._hyper_1_121_chunk USING btree (status);


--
-- TOC entry 5901 (class 1259 OID 31761)
-- Name: _hyper_1_121_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_121_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_121_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5902 (class 1259 OID 24160)
-- Name: _hyper_1_121_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_121_chunk_idx_status_region ON _timescaledb_internal._hyper_1_121_chunk USING btree (status, region);


--
-- TOC entry 5903 (class 1259 OID 31867)
-- Name: _hyper_1_121_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_121_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_121_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5904 (class 1259 OID 24159)
-- Name: _hyper_1_121_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_121_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_121_chunk USING btree (event_time DESC);


--
-- TOC entry 5905 (class 1259 OID 24192)
-- Name: _hyper_1_122_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_122_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_122_chunk USING btree (customer_id);


--
-- TOC entry 5906 (class 1259 OID 24191)
-- Name: _hyper_1_122_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_122_chunk_idx_order_region ON _timescaledb_internal._hyper_1_122_chunk USING btree (region);


--
-- TOC entry 5907 (class 1259 OID 24190)
-- Name: _hyper_1_122_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_122_chunk_idx_order_status ON _timescaledb_internal._hyper_1_122_chunk USING btree (status);


--
-- TOC entry 5908 (class 1259 OID 31762)
-- Name: _hyper_1_122_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_122_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_122_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5909 (class 1259 OID 24189)
-- Name: _hyper_1_122_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_122_chunk_idx_status_region ON _timescaledb_internal._hyper_1_122_chunk USING btree (status, region);


--
-- TOC entry 5910 (class 1259 OID 31868)
-- Name: _hyper_1_122_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_122_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_122_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5911 (class 1259 OID 24188)
-- Name: _hyper_1_122_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_122_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_122_chunk USING btree (event_time DESC);


--
-- TOC entry 5912 (class 1259 OID 24221)
-- Name: _hyper_1_123_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_123_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_123_chunk USING btree (customer_id);


--
-- TOC entry 5913 (class 1259 OID 24220)
-- Name: _hyper_1_123_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_123_chunk_idx_order_region ON _timescaledb_internal._hyper_1_123_chunk USING btree (region);


--
-- TOC entry 5914 (class 1259 OID 24219)
-- Name: _hyper_1_123_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_123_chunk_idx_order_status ON _timescaledb_internal._hyper_1_123_chunk USING btree (status);


--
-- TOC entry 5915 (class 1259 OID 31763)
-- Name: _hyper_1_123_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_123_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_123_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5916 (class 1259 OID 24218)
-- Name: _hyper_1_123_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_123_chunk_idx_status_region ON _timescaledb_internal._hyper_1_123_chunk USING btree (status, region);


--
-- TOC entry 5917 (class 1259 OID 31869)
-- Name: _hyper_1_123_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_123_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_123_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5918 (class 1259 OID 24217)
-- Name: _hyper_1_123_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_123_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_123_chunk USING btree (event_time DESC);


--
-- TOC entry 5919 (class 1259 OID 24250)
-- Name: _hyper_1_124_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_124_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_124_chunk USING btree (customer_id);


--
-- TOC entry 5920 (class 1259 OID 24249)
-- Name: _hyper_1_124_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_124_chunk_idx_order_region ON _timescaledb_internal._hyper_1_124_chunk USING btree (region);


--
-- TOC entry 5921 (class 1259 OID 24248)
-- Name: _hyper_1_124_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_124_chunk_idx_order_status ON _timescaledb_internal._hyper_1_124_chunk USING btree (status);


--
-- TOC entry 5922 (class 1259 OID 31764)
-- Name: _hyper_1_124_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_124_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_124_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5923 (class 1259 OID 24247)
-- Name: _hyper_1_124_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_124_chunk_idx_status_region ON _timescaledb_internal._hyper_1_124_chunk USING btree (status, region);


--
-- TOC entry 5924 (class 1259 OID 31870)
-- Name: _hyper_1_124_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_124_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_124_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5925 (class 1259 OID 24246)
-- Name: _hyper_1_124_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_124_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_124_chunk USING btree (event_time DESC);


--
-- TOC entry 5926 (class 1259 OID 24279)
-- Name: _hyper_1_125_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_125_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_125_chunk USING btree (customer_id);


--
-- TOC entry 5927 (class 1259 OID 24278)
-- Name: _hyper_1_125_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_125_chunk_idx_order_region ON _timescaledb_internal._hyper_1_125_chunk USING btree (region);


--
-- TOC entry 5928 (class 1259 OID 24277)
-- Name: _hyper_1_125_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_125_chunk_idx_order_status ON _timescaledb_internal._hyper_1_125_chunk USING btree (status);


--
-- TOC entry 5929 (class 1259 OID 31765)
-- Name: _hyper_1_125_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_125_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_125_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5930 (class 1259 OID 24276)
-- Name: _hyper_1_125_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_125_chunk_idx_status_region ON _timescaledb_internal._hyper_1_125_chunk USING btree (status, region);


--
-- TOC entry 5931 (class 1259 OID 31871)
-- Name: _hyper_1_125_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_125_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_125_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5932 (class 1259 OID 24275)
-- Name: _hyper_1_125_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_125_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_125_chunk USING btree (event_time DESC);


--
-- TOC entry 5933 (class 1259 OID 24308)
-- Name: _hyper_1_126_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_126_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_126_chunk USING btree (customer_id);


--
-- TOC entry 5934 (class 1259 OID 24307)
-- Name: _hyper_1_126_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_126_chunk_idx_order_region ON _timescaledb_internal._hyper_1_126_chunk USING btree (region);


--
-- TOC entry 5935 (class 1259 OID 24306)
-- Name: _hyper_1_126_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_126_chunk_idx_order_status ON _timescaledb_internal._hyper_1_126_chunk USING btree (status);


--
-- TOC entry 5936 (class 1259 OID 31766)
-- Name: _hyper_1_126_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_126_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_126_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5937 (class 1259 OID 24305)
-- Name: _hyper_1_126_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_126_chunk_idx_status_region ON _timescaledb_internal._hyper_1_126_chunk USING btree (status, region);


--
-- TOC entry 5938 (class 1259 OID 31872)
-- Name: _hyper_1_126_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_126_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_126_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5939 (class 1259 OID 24304)
-- Name: _hyper_1_126_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_126_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_126_chunk USING btree (event_time DESC);


--
-- TOC entry 5940 (class 1259 OID 24337)
-- Name: _hyper_1_127_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_127_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_127_chunk USING btree (customer_id);


--
-- TOC entry 5941 (class 1259 OID 24336)
-- Name: _hyper_1_127_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_127_chunk_idx_order_region ON _timescaledb_internal._hyper_1_127_chunk USING btree (region);


--
-- TOC entry 5942 (class 1259 OID 24335)
-- Name: _hyper_1_127_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_127_chunk_idx_order_status ON _timescaledb_internal._hyper_1_127_chunk USING btree (status);


--
-- TOC entry 5943 (class 1259 OID 31767)
-- Name: _hyper_1_127_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_127_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_127_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5944 (class 1259 OID 24334)
-- Name: _hyper_1_127_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_127_chunk_idx_status_region ON _timescaledb_internal._hyper_1_127_chunk USING btree (status, region);


--
-- TOC entry 5945 (class 1259 OID 31873)
-- Name: _hyper_1_127_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_127_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_127_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5946 (class 1259 OID 24333)
-- Name: _hyper_1_127_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_127_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_127_chunk USING btree (event_time DESC);


--
-- TOC entry 5947 (class 1259 OID 24366)
-- Name: _hyper_1_128_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_128_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_128_chunk USING btree (customer_id);


--
-- TOC entry 5948 (class 1259 OID 24365)
-- Name: _hyper_1_128_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_128_chunk_idx_order_region ON _timescaledb_internal._hyper_1_128_chunk USING btree (region);


--
-- TOC entry 5949 (class 1259 OID 24364)
-- Name: _hyper_1_128_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_128_chunk_idx_order_status ON _timescaledb_internal._hyper_1_128_chunk USING btree (status);


--
-- TOC entry 5950 (class 1259 OID 31768)
-- Name: _hyper_1_128_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_128_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_128_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5951 (class 1259 OID 24363)
-- Name: _hyper_1_128_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_128_chunk_idx_status_region ON _timescaledb_internal._hyper_1_128_chunk USING btree (status, region);


--
-- TOC entry 5952 (class 1259 OID 31874)
-- Name: _hyper_1_128_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_128_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_128_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5953 (class 1259 OID 24362)
-- Name: _hyper_1_128_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_128_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_128_chunk USING btree (event_time DESC);


--
-- TOC entry 5954 (class 1259 OID 24395)
-- Name: _hyper_1_129_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_129_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_129_chunk USING btree (customer_id);


--
-- TOC entry 5955 (class 1259 OID 24394)
-- Name: _hyper_1_129_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_129_chunk_idx_order_region ON _timescaledb_internal._hyper_1_129_chunk USING btree (region);


--
-- TOC entry 5956 (class 1259 OID 24393)
-- Name: _hyper_1_129_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_129_chunk_idx_order_status ON _timescaledb_internal._hyper_1_129_chunk USING btree (status);


--
-- TOC entry 5957 (class 1259 OID 31769)
-- Name: _hyper_1_129_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_129_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_129_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5958 (class 1259 OID 24392)
-- Name: _hyper_1_129_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_129_chunk_idx_status_region ON _timescaledb_internal._hyper_1_129_chunk USING btree (status, region);


--
-- TOC entry 5959 (class 1259 OID 31875)
-- Name: _hyper_1_129_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_129_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_129_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5960 (class 1259 OID 24391)
-- Name: _hyper_1_129_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_129_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_129_chunk USING btree (event_time DESC);


--
-- TOC entry 5497 (class 1259 OID 21009)
-- Name: _hyper_1_12_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_12_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_12_chunk USING btree (customer_id);


--
-- TOC entry 5498 (class 1259 OID 20954)
-- Name: _hyper_1_12_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_12_chunk_idx_order_region ON _timescaledb_internal._hyper_1_12_chunk USING btree (region);


--
-- TOC entry 5499 (class 1259 OID 20900)
-- Name: _hyper_1_12_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_12_chunk_idx_order_status ON _timescaledb_internal._hyper_1_12_chunk USING btree (status);


--
-- TOC entry 5500 (class 1259 OID 31704)
-- Name: _hyper_1_12_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_12_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_12_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5501 (class 1259 OID 20840)
-- Name: _hyper_1_12_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_12_chunk_idx_status_region ON _timescaledb_internal._hyper_1_12_chunk USING btree (status, region);


--
-- TOC entry 5502 (class 1259 OID 31810)
-- Name: _hyper_1_12_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_12_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_12_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5503 (class 1259 OID 19299)
-- Name: _hyper_1_12_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_12_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_12_chunk USING btree (event_time DESC);


--
-- TOC entry 5961 (class 1259 OID 24424)
-- Name: _hyper_1_130_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_130_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_130_chunk USING btree (customer_id);


--
-- TOC entry 5962 (class 1259 OID 24423)
-- Name: _hyper_1_130_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_130_chunk_idx_order_region ON _timescaledb_internal._hyper_1_130_chunk USING btree (region);


--
-- TOC entry 5963 (class 1259 OID 24422)
-- Name: _hyper_1_130_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_130_chunk_idx_order_status ON _timescaledb_internal._hyper_1_130_chunk USING btree (status);


--
-- TOC entry 5964 (class 1259 OID 31770)
-- Name: _hyper_1_130_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_130_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_130_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5965 (class 1259 OID 24421)
-- Name: _hyper_1_130_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_130_chunk_idx_status_region ON _timescaledb_internal._hyper_1_130_chunk USING btree (status, region);


--
-- TOC entry 5966 (class 1259 OID 31876)
-- Name: _hyper_1_130_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_130_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_130_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5967 (class 1259 OID 24420)
-- Name: _hyper_1_130_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_130_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_130_chunk USING btree (event_time DESC);


--
-- TOC entry 5968 (class 1259 OID 24453)
-- Name: _hyper_1_131_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_131_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_131_chunk USING btree (customer_id);


--
-- TOC entry 5969 (class 1259 OID 24452)
-- Name: _hyper_1_131_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_131_chunk_idx_order_region ON _timescaledb_internal._hyper_1_131_chunk USING btree (region);


--
-- TOC entry 5970 (class 1259 OID 24451)
-- Name: _hyper_1_131_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_131_chunk_idx_order_status ON _timescaledb_internal._hyper_1_131_chunk USING btree (status);


--
-- TOC entry 5971 (class 1259 OID 31771)
-- Name: _hyper_1_131_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_131_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_131_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5972 (class 1259 OID 24450)
-- Name: _hyper_1_131_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_131_chunk_idx_status_region ON _timescaledb_internal._hyper_1_131_chunk USING btree (status, region);


--
-- TOC entry 5973 (class 1259 OID 31877)
-- Name: _hyper_1_131_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_131_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_131_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5974 (class 1259 OID 24449)
-- Name: _hyper_1_131_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_131_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_131_chunk USING btree (event_time DESC);


--
-- TOC entry 5975 (class 1259 OID 24482)
-- Name: _hyper_1_132_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_132_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_132_chunk USING btree (customer_id);


--
-- TOC entry 5976 (class 1259 OID 24481)
-- Name: _hyper_1_132_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_132_chunk_idx_order_region ON _timescaledb_internal._hyper_1_132_chunk USING btree (region);


--
-- TOC entry 5977 (class 1259 OID 24480)
-- Name: _hyper_1_132_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_132_chunk_idx_order_status ON _timescaledb_internal._hyper_1_132_chunk USING btree (status);


--
-- TOC entry 5978 (class 1259 OID 31772)
-- Name: _hyper_1_132_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_132_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_132_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5979 (class 1259 OID 24479)
-- Name: _hyper_1_132_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_132_chunk_idx_status_region ON _timescaledb_internal._hyper_1_132_chunk USING btree (status, region);


--
-- TOC entry 5980 (class 1259 OID 31878)
-- Name: _hyper_1_132_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_132_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_132_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5981 (class 1259 OID 24478)
-- Name: _hyper_1_132_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_132_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_132_chunk USING btree (event_time DESC);


--
-- TOC entry 5982 (class 1259 OID 24511)
-- Name: _hyper_1_133_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_133_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_133_chunk USING btree (customer_id);


--
-- TOC entry 5983 (class 1259 OID 24510)
-- Name: _hyper_1_133_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_133_chunk_idx_order_region ON _timescaledb_internal._hyper_1_133_chunk USING btree (region);


--
-- TOC entry 5984 (class 1259 OID 24509)
-- Name: _hyper_1_133_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_133_chunk_idx_order_status ON _timescaledb_internal._hyper_1_133_chunk USING btree (status);


--
-- TOC entry 5985 (class 1259 OID 31773)
-- Name: _hyper_1_133_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_133_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_133_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5986 (class 1259 OID 24508)
-- Name: _hyper_1_133_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_133_chunk_idx_status_region ON _timescaledb_internal._hyper_1_133_chunk USING btree (status, region);


--
-- TOC entry 5987 (class 1259 OID 31879)
-- Name: _hyper_1_133_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_133_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_133_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5988 (class 1259 OID 24507)
-- Name: _hyper_1_133_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_133_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_133_chunk USING btree (event_time DESC);


--
-- TOC entry 5989 (class 1259 OID 24540)
-- Name: _hyper_1_134_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_134_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_134_chunk USING btree (customer_id);


--
-- TOC entry 5990 (class 1259 OID 24539)
-- Name: _hyper_1_134_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_134_chunk_idx_order_region ON _timescaledb_internal._hyper_1_134_chunk USING btree (region);


--
-- TOC entry 5991 (class 1259 OID 24538)
-- Name: _hyper_1_134_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_134_chunk_idx_order_status ON _timescaledb_internal._hyper_1_134_chunk USING btree (status);


--
-- TOC entry 5992 (class 1259 OID 31774)
-- Name: _hyper_1_134_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_134_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_134_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5993 (class 1259 OID 24537)
-- Name: _hyper_1_134_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_134_chunk_idx_status_region ON _timescaledb_internal._hyper_1_134_chunk USING btree (status, region);


--
-- TOC entry 5994 (class 1259 OID 31880)
-- Name: _hyper_1_134_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_134_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_134_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5995 (class 1259 OID 24536)
-- Name: _hyper_1_134_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_134_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_134_chunk USING btree (event_time DESC);


--
-- TOC entry 5996 (class 1259 OID 24569)
-- Name: _hyper_1_135_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_135_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_135_chunk USING btree (customer_id);


--
-- TOC entry 5997 (class 1259 OID 24568)
-- Name: _hyper_1_135_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_135_chunk_idx_order_region ON _timescaledb_internal._hyper_1_135_chunk USING btree (region);


--
-- TOC entry 5998 (class 1259 OID 24567)
-- Name: _hyper_1_135_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_135_chunk_idx_order_status ON _timescaledb_internal._hyper_1_135_chunk USING btree (status);


--
-- TOC entry 5999 (class 1259 OID 31775)
-- Name: _hyper_1_135_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_135_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_135_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6000 (class 1259 OID 24566)
-- Name: _hyper_1_135_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_135_chunk_idx_status_region ON _timescaledb_internal._hyper_1_135_chunk USING btree (status, region);


--
-- TOC entry 6001 (class 1259 OID 31881)
-- Name: _hyper_1_135_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_135_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_135_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6002 (class 1259 OID 24565)
-- Name: _hyper_1_135_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_135_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_135_chunk USING btree (event_time DESC);


--
-- TOC entry 6003 (class 1259 OID 24598)
-- Name: _hyper_1_136_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_136_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_136_chunk USING btree (customer_id);


--
-- TOC entry 6004 (class 1259 OID 24597)
-- Name: _hyper_1_136_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_136_chunk_idx_order_region ON _timescaledb_internal._hyper_1_136_chunk USING btree (region);


--
-- TOC entry 6005 (class 1259 OID 24596)
-- Name: _hyper_1_136_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_136_chunk_idx_order_status ON _timescaledb_internal._hyper_1_136_chunk USING btree (status);


--
-- TOC entry 6006 (class 1259 OID 31776)
-- Name: _hyper_1_136_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_136_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_136_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6007 (class 1259 OID 24595)
-- Name: _hyper_1_136_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_136_chunk_idx_status_region ON _timescaledb_internal._hyper_1_136_chunk USING btree (status, region);


--
-- TOC entry 6008 (class 1259 OID 31882)
-- Name: _hyper_1_136_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_136_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_136_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6009 (class 1259 OID 24594)
-- Name: _hyper_1_136_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_136_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_136_chunk USING btree (event_time DESC);


--
-- TOC entry 6010 (class 1259 OID 24627)
-- Name: _hyper_1_137_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_137_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_137_chunk USING btree (customer_id);


--
-- TOC entry 6011 (class 1259 OID 24626)
-- Name: _hyper_1_137_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_137_chunk_idx_order_region ON _timescaledb_internal._hyper_1_137_chunk USING btree (region);


--
-- TOC entry 6012 (class 1259 OID 24625)
-- Name: _hyper_1_137_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_137_chunk_idx_order_status ON _timescaledb_internal._hyper_1_137_chunk USING btree (status);


--
-- TOC entry 6013 (class 1259 OID 31777)
-- Name: _hyper_1_137_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_137_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_137_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6014 (class 1259 OID 24624)
-- Name: _hyper_1_137_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_137_chunk_idx_status_region ON _timescaledb_internal._hyper_1_137_chunk USING btree (status, region);


--
-- TOC entry 6015 (class 1259 OID 31883)
-- Name: _hyper_1_137_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_137_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_137_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6016 (class 1259 OID 24623)
-- Name: _hyper_1_137_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_137_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_137_chunk USING btree (event_time DESC);


--
-- TOC entry 6017 (class 1259 OID 24656)
-- Name: _hyper_1_138_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_138_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_138_chunk USING btree (customer_id);


--
-- TOC entry 6018 (class 1259 OID 24655)
-- Name: _hyper_1_138_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_138_chunk_idx_order_region ON _timescaledb_internal._hyper_1_138_chunk USING btree (region);


--
-- TOC entry 6019 (class 1259 OID 24654)
-- Name: _hyper_1_138_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_138_chunk_idx_order_status ON _timescaledb_internal._hyper_1_138_chunk USING btree (status);


--
-- TOC entry 6020 (class 1259 OID 31778)
-- Name: _hyper_1_138_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_138_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_138_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6021 (class 1259 OID 24653)
-- Name: _hyper_1_138_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_138_chunk_idx_status_region ON _timescaledb_internal._hyper_1_138_chunk USING btree (status, region);


--
-- TOC entry 6022 (class 1259 OID 31884)
-- Name: _hyper_1_138_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_138_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_138_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6023 (class 1259 OID 24652)
-- Name: _hyper_1_138_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_138_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_138_chunk USING btree (event_time DESC);


--
-- TOC entry 6024 (class 1259 OID 24685)
-- Name: _hyper_1_139_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_139_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_139_chunk USING btree (customer_id);


--
-- TOC entry 6025 (class 1259 OID 24684)
-- Name: _hyper_1_139_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_139_chunk_idx_order_region ON _timescaledb_internal._hyper_1_139_chunk USING btree (region);


--
-- TOC entry 6026 (class 1259 OID 24683)
-- Name: _hyper_1_139_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_139_chunk_idx_order_status ON _timescaledb_internal._hyper_1_139_chunk USING btree (status);


--
-- TOC entry 6027 (class 1259 OID 31779)
-- Name: _hyper_1_139_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_139_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_139_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6028 (class 1259 OID 24682)
-- Name: _hyper_1_139_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_139_chunk_idx_status_region ON _timescaledb_internal._hyper_1_139_chunk USING btree (status, region);


--
-- TOC entry 6029 (class 1259 OID 31885)
-- Name: _hyper_1_139_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_139_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_139_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6030 (class 1259 OID 24681)
-- Name: _hyper_1_139_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_139_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_139_chunk USING btree (event_time DESC);


--
-- TOC entry 5504 (class 1259 OID 21010)
-- Name: _hyper_1_13_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_13_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_13_chunk USING btree (customer_id);


--
-- TOC entry 5505 (class 1259 OID 20955)
-- Name: _hyper_1_13_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_13_chunk_idx_order_region ON _timescaledb_internal._hyper_1_13_chunk USING btree (region);


--
-- TOC entry 5506 (class 1259 OID 20901)
-- Name: _hyper_1_13_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_13_chunk_idx_order_status ON _timescaledb_internal._hyper_1_13_chunk USING btree (status);


--
-- TOC entry 5507 (class 1259 OID 31705)
-- Name: _hyper_1_13_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_13_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_13_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5508 (class 1259 OID 20841)
-- Name: _hyper_1_13_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_13_chunk_idx_status_region ON _timescaledb_internal._hyper_1_13_chunk USING btree (status, region);


--
-- TOC entry 5509 (class 1259 OID 31811)
-- Name: _hyper_1_13_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_13_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_13_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5510 (class 1259 OID 19324)
-- Name: _hyper_1_13_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_13_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_13_chunk USING btree (event_time DESC);


--
-- TOC entry 6031 (class 1259 OID 24714)
-- Name: _hyper_1_140_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_140_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_140_chunk USING btree (customer_id);


--
-- TOC entry 6032 (class 1259 OID 24713)
-- Name: _hyper_1_140_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_140_chunk_idx_order_region ON _timescaledb_internal._hyper_1_140_chunk USING btree (region);


--
-- TOC entry 6033 (class 1259 OID 24712)
-- Name: _hyper_1_140_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_140_chunk_idx_order_status ON _timescaledb_internal._hyper_1_140_chunk USING btree (status);


--
-- TOC entry 6034 (class 1259 OID 31780)
-- Name: _hyper_1_140_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_140_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_140_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6035 (class 1259 OID 24711)
-- Name: _hyper_1_140_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_140_chunk_idx_status_region ON _timescaledb_internal._hyper_1_140_chunk USING btree (status, region);


--
-- TOC entry 6036 (class 1259 OID 31886)
-- Name: _hyper_1_140_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_140_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_140_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6037 (class 1259 OID 24710)
-- Name: _hyper_1_140_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_140_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_140_chunk USING btree (event_time DESC);


--
-- TOC entry 6038 (class 1259 OID 24743)
-- Name: _hyper_1_141_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_141_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_141_chunk USING btree (customer_id);


--
-- TOC entry 6039 (class 1259 OID 24742)
-- Name: _hyper_1_141_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_141_chunk_idx_order_region ON _timescaledb_internal._hyper_1_141_chunk USING btree (region);


--
-- TOC entry 6040 (class 1259 OID 24741)
-- Name: _hyper_1_141_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_141_chunk_idx_order_status ON _timescaledb_internal._hyper_1_141_chunk USING btree (status);


--
-- TOC entry 6041 (class 1259 OID 31781)
-- Name: _hyper_1_141_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_141_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_141_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6042 (class 1259 OID 24740)
-- Name: _hyper_1_141_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_141_chunk_idx_status_region ON _timescaledb_internal._hyper_1_141_chunk USING btree (status, region);


--
-- TOC entry 6043 (class 1259 OID 31887)
-- Name: _hyper_1_141_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_141_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_141_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6044 (class 1259 OID 24739)
-- Name: _hyper_1_141_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_141_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_141_chunk USING btree (event_time DESC);


--
-- TOC entry 6045 (class 1259 OID 24772)
-- Name: _hyper_1_142_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_142_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_142_chunk USING btree (customer_id);


--
-- TOC entry 6046 (class 1259 OID 24771)
-- Name: _hyper_1_142_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_142_chunk_idx_order_region ON _timescaledb_internal._hyper_1_142_chunk USING btree (region);


--
-- TOC entry 6047 (class 1259 OID 24770)
-- Name: _hyper_1_142_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_142_chunk_idx_order_status ON _timescaledb_internal._hyper_1_142_chunk USING btree (status);


--
-- TOC entry 6048 (class 1259 OID 31782)
-- Name: _hyper_1_142_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_142_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_142_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6049 (class 1259 OID 24769)
-- Name: _hyper_1_142_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_142_chunk_idx_status_region ON _timescaledb_internal._hyper_1_142_chunk USING btree (status, region);


--
-- TOC entry 6050 (class 1259 OID 31888)
-- Name: _hyper_1_142_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_142_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_142_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6051 (class 1259 OID 24768)
-- Name: _hyper_1_142_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_142_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_142_chunk USING btree (event_time DESC);


--
-- TOC entry 6052 (class 1259 OID 24801)
-- Name: _hyper_1_143_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_143_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_143_chunk USING btree (customer_id);


--
-- TOC entry 6053 (class 1259 OID 24800)
-- Name: _hyper_1_143_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_143_chunk_idx_order_region ON _timescaledb_internal._hyper_1_143_chunk USING btree (region);


--
-- TOC entry 6054 (class 1259 OID 24799)
-- Name: _hyper_1_143_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_143_chunk_idx_order_status ON _timescaledb_internal._hyper_1_143_chunk USING btree (status);


--
-- TOC entry 6055 (class 1259 OID 31783)
-- Name: _hyper_1_143_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_143_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_143_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6056 (class 1259 OID 24798)
-- Name: _hyper_1_143_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_143_chunk_idx_status_region ON _timescaledb_internal._hyper_1_143_chunk USING btree (status, region);


--
-- TOC entry 6057 (class 1259 OID 31889)
-- Name: _hyper_1_143_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_143_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_143_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6058 (class 1259 OID 24797)
-- Name: _hyper_1_143_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_143_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_143_chunk USING btree (event_time DESC);


--
-- TOC entry 6059 (class 1259 OID 24830)
-- Name: _hyper_1_144_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_144_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_144_chunk USING btree (customer_id);


--
-- TOC entry 6060 (class 1259 OID 24829)
-- Name: _hyper_1_144_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_144_chunk_idx_order_region ON _timescaledb_internal._hyper_1_144_chunk USING btree (region);


--
-- TOC entry 6061 (class 1259 OID 24828)
-- Name: _hyper_1_144_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_144_chunk_idx_order_status ON _timescaledb_internal._hyper_1_144_chunk USING btree (status);


--
-- TOC entry 6062 (class 1259 OID 31784)
-- Name: _hyper_1_144_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_144_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_144_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6063 (class 1259 OID 24827)
-- Name: _hyper_1_144_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_144_chunk_idx_status_region ON _timescaledb_internal._hyper_1_144_chunk USING btree (status, region);


--
-- TOC entry 6064 (class 1259 OID 31890)
-- Name: _hyper_1_144_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_144_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_144_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6065 (class 1259 OID 24826)
-- Name: _hyper_1_144_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_144_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_144_chunk USING btree (event_time DESC);


--
-- TOC entry 6066 (class 1259 OID 24859)
-- Name: _hyper_1_145_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_145_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_145_chunk USING btree (customer_id);


--
-- TOC entry 6067 (class 1259 OID 24858)
-- Name: _hyper_1_145_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_145_chunk_idx_order_region ON _timescaledb_internal._hyper_1_145_chunk USING btree (region);


--
-- TOC entry 6068 (class 1259 OID 24857)
-- Name: _hyper_1_145_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_145_chunk_idx_order_status ON _timescaledb_internal._hyper_1_145_chunk USING btree (status);


--
-- TOC entry 6069 (class 1259 OID 31785)
-- Name: _hyper_1_145_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_145_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_145_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6070 (class 1259 OID 24856)
-- Name: _hyper_1_145_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_145_chunk_idx_status_region ON _timescaledb_internal._hyper_1_145_chunk USING btree (status, region);


--
-- TOC entry 6071 (class 1259 OID 31891)
-- Name: _hyper_1_145_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_145_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_145_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6072 (class 1259 OID 24855)
-- Name: _hyper_1_145_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_145_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_145_chunk USING btree (event_time DESC);


--
-- TOC entry 6073 (class 1259 OID 24888)
-- Name: _hyper_1_146_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_146_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_146_chunk USING btree (customer_id);


--
-- TOC entry 6074 (class 1259 OID 24887)
-- Name: _hyper_1_146_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_146_chunk_idx_order_region ON _timescaledb_internal._hyper_1_146_chunk USING btree (region);


--
-- TOC entry 6075 (class 1259 OID 24886)
-- Name: _hyper_1_146_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_146_chunk_idx_order_status ON _timescaledb_internal._hyper_1_146_chunk USING btree (status);


--
-- TOC entry 6076 (class 1259 OID 31786)
-- Name: _hyper_1_146_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_146_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_146_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6077 (class 1259 OID 24885)
-- Name: _hyper_1_146_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_146_chunk_idx_status_region ON _timescaledb_internal._hyper_1_146_chunk USING btree (status, region);


--
-- TOC entry 6078 (class 1259 OID 31892)
-- Name: _hyper_1_146_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_146_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_146_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6079 (class 1259 OID 24884)
-- Name: _hyper_1_146_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_146_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_146_chunk USING btree (event_time DESC);


--
-- TOC entry 6080 (class 1259 OID 24917)
-- Name: _hyper_1_147_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_147_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_147_chunk USING btree (customer_id);


--
-- TOC entry 6081 (class 1259 OID 24916)
-- Name: _hyper_1_147_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_147_chunk_idx_order_region ON _timescaledb_internal._hyper_1_147_chunk USING btree (region);


--
-- TOC entry 6082 (class 1259 OID 24915)
-- Name: _hyper_1_147_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_147_chunk_idx_order_status ON _timescaledb_internal._hyper_1_147_chunk USING btree (status);


--
-- TOC entry 6083 (class 1259 OID 31787)
-- Name: _hyper_1_147_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_147_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_147_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6084 (class 1259 OID 24914)
-- Name: _hyper_1_147_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_147_chunk_idx_status_region ON _timescaledb_internal._hyper_1_147_chunk USING btree (status, region);


--
-- TOC entry 6085 (class 1259 OID 31893)
-- Name: _hyper_1_147_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_147_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_147_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6086 (class 1259 OID 24913)
-- Name: _hyper_1_147_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_147_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_147_chunk USING btree (event_time DESC);


--
-- TOC entry 6087 (class 1259 OID 24946)
-- Name: _hyper_1_148_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_148_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_148_chunk USING btree (customer_id);


--
-- TOC entry 6088 (class 1259 OID 24945)
-- Name: _hyper_1_148_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_148_chunk_idx_order_region ON _timescaledb_internal._hyper_1_148_chunk USING btree (region);


--
-- TOC entry 6089 (class 1259 OID 24944)
-- Name: _hyper_1_148_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_148_chunk_idx_order_status ON _timescaledb_internal._hyper_1_148_chunk USING btree (status);


--
-- TOC entry 6090 (class 1259 OID 31788)
-- Name: _hyper_1_148_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_148_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_148_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6091 (class 1259 OID 24943)
-- Name: _hyper_1_148_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_148_chunk_idx_status_region ON _timescaledb_internal._hyper_1_148_chunk USING btree (status, region);


--
-- TOC entry 6092 (class 1259 OID 31894)
-- Name: _hyper_1_148_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_148_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_148_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6093 (class 1259 OID 24942)
-- Name: _hyper_1_148_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_148_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_148_chunk USING btree (event_time DESC);


--
-- TOC entry 6094 (class 1259 OID 24975)
-- Name: _hyper_1_149_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_149_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_149_chunk USING btree (customer_id);


--
-- TOC entry 6095 (class 1259 OID 24974)
-- Name: _hyper_1_149_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_149_chunk_idx_order_region ON _timescaledb_internal._hyper_1_149_chunk USING btree (region);


--
-- TOC entry 6096 (class 1259 OID 24973)
-- Name: _hyper_1_149_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_149_chunk_idx_order_status ON _timescaledb_internal._hyper_1_149_chunk USING btree (status);


--
-- TOC entry 6097 (class 1259 OID 31789)
-- Name: _hyper_1_149_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_149_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_149_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6098 (class 1259 OID 24972)
-- Name: _hyper_1_149_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_149_chunk_idx_status_region ON _timescaledb_internal._hyper_1_149_chunk USING btree (status, region);


--
-- TOC entry 6099 (class 1259 OID 31895)
-- Name: _hyper_1_149_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_149_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_149_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6100 (class 1259 OID 24971)
-- Name: _hyper_1_149_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_149_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_149_chunk USING btree (event_time DESC);


--
-- TOC entry 5511 (class 1259 OID 21011)
-- Name: _hyper_1_14_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_14_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_14_chunk USING btree (customer_id);


--
-- TOC entry 5512 (class 1259 OID 20956)
-- Name: _hyper_1_14_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_14_chunk_idx_order_region ON _timescaledb_internal._hyper_1_14_chunk USING btree (region);


--
-- TOC entry 5513 (class 1259 OID 20902)
-- Name: _hyper_1_14_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_14_chunk_idx_order_status ON _timescaledb_internal._hyper_1_14_chunk USING btree (status);


--
-- TOC entry 5514 (class 1259 OID 31706)
-- Name: _hyper_1_14_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_14_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_14_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5515 (class 1259 OID 20842)
-- Name: _hyper_1_14_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_14_chunk_idx_status_region ON _timescaledb_internal._hyper_1_14_chunk USING btree (status, region);


--
-- TOC entry 5516 (class 1259 OID 31812)
-- Name: _hyper_1_14_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_14_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_14_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5517 (class 1259 OID 19349)
-- Name: _hyper_1_14_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_14_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_14_chunk USING btree (event_time DESC);


--
-- TOC entry 6101 (class 1259 OID 25004)
-- Name: _hyper_1_150_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_150_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_150_chunk USING btree (customer_id);


--
-- TOC entry 6102 (class 1259 OID 25003)
-- Name: _hyper_1_150_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_150_chunk_idx_order_region ON _timescaledb_internal._hyper_1_150_chunk USING btree (region);


--
-- TOC entry 6103 (class 1259 OID 25002)
-- Name: _hyper_1_150_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_150_chunk_idx_order_status ON _timescaledb_internal._hyper_1_150_chunk USING btree (status);


--
-- TOC entry 6104 (class 1259 OID 31790)
-- Name: _hyper_1_150_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_150_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_150_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6105 (class 1259 OID 25001)
-- Name: _hyper_1_150_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_150_chunk_idx_status_region ON _timescaledb_internal._hyper_1_150_chunk USING btree (status, region);


--
-- TOC entry 6106 (class 1259 OID 31896)
-- Name: _hyper_1_150_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_150_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_150_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6107 (class 1259 OID 25000)
-- Name: _hyper_1_150_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_150_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_150_chunk USING btree (event_time DESC);


--
-- TOC entry 6108 (class 1259 OID 25033)
-- Name: _hyper_1_151_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_151_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_151_chunk USING btree (customer_id);


--
-- TOC entry 6109 (class 1259 OID 25032)
-- Name: _hyper_1_151_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_151_chunk_idx_order_region ON _timescaledb_internal._hyper_1_151_chunk USING btree (region);


--
-- TOC entry 6110 (class 1259 OID 25031)
-- Name: _hyper_1_151_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_151_chunk_idx_order_status ON _timescaledb_internal._hyper_1_151_chunk USING btree (status);


--
-- TOC entry 6111 (class 1259 OID 31791)
-- Name: _hyper_1_151_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_151_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_151_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6112 (class 1259 OID 25030)
-- Name: _hyper_1_151_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_151_chunk_idx_status_region ON _timescaledb_internal._hyper_1_151_chunk USING btree (status, region);


--
-- TOC entry 6113 (class 1259 OID 31897)
-- Name: _hyper_1_151_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_151_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_151_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6114 (class 1259 OID 25029)
-- Name: _hyper_1_151_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_151_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_151_chunk USING btree (event_time DESC);


--
-- TOC entry 6115 (class 1259 OID 25062)
-- Name: _hyper_1_152_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_152_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_152_chunk USING btree (customer_id);


--
-- TOC entry 6116 (class 1259 OID 25061)
-- Name: _hyper_1_152_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_152_chunk_idx_order_region ON _timescaledb_internal._hyper_1_152_chunk USING btree (region);


--
-- TOC entry 6117 (class 1259 OID 25060)
-- Name: _hyper_1_152_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_152_chunk_idx_order_status ON _timescaledb_internal._hyper_1_152_chunk USING btree (status);


--
-- TOC entry 6118 (class 1259 OID 31792)
-- Name: _hyper_1_152_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_152_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_152_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6119 (class 1259 OID 25059)
-- Name: _hyper_1_152_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_152_chunk_idx_status_region ON _timescaledb_internal._hyper_1_152_chunk USING btree (status, region);


--
-- TOC entry 6120 (class 1259 OID 31898)
-- Name: _hyper_1_152_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_152_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_152_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6121 (class 1259 OID 25058)
-- Name: _hyper_1_152_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_152_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_152_chunk USING btree (event_time DESC);


--
-- TOC entry 6122 (class 1259 OID 25091)
-- Name: _hyper_1_153_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_153_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_153_chunk USING btree (customer_id);


--
-- TOC entry 6123 (class 1259 OID 25090)
-- Name: _hyper_1_153_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_153_chunk_idx_order_region ON _timescaledb_internal._hyper_1_153_chunk USING btree (region);


--
-- TOC entry 6124 (class 1259 OID 25089)
-- Name: _hyper_1_153_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_153_chunk_idx_order_status ON _timescaledb_internal._hyper_1_153_chunk USING btree (status);


--
-- TOC entry 6125 (class 1259 OID 31793)
-- Name: _hyper_1_153_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_153_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_153_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6126 (class 1259 OID 25088)
-- Name: _hyper_1_153_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_153_chunk_idx_status_region ON _timescaledb_internal._hyper_1_153_chunk USING btree (status, region);


--
-- TOC entry 6127 (class 1259 OID 31899)
-- Name: _hyper_1_153_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_153_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_153_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6128 (class 1259 OID 25087)
-- Name: _hyper_1_153_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_153_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_153_chunk USING btree (event_time DESC);


--
-- TOC entry 6129 (class 1259 OID 25120)
-- Name: _hyper_1_154_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_154_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_154_chunk USING btree (customer_id);


--
-- TOC entry 6130 (class 1259 OID 25119)
-- Name: _hyper_1_154_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_154_chunk_idx_order_region ON _timescaledb_internal._hyper_1_154_chunk USING btree (region);


--
-- TOC entry 6131 (class 1259 OID 25118)
-- Name: _hyper_1_154_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_154_chunk_idx_order_status ON _timescaledb_internal._hyper_1_154_chunk USING btree (status);


--
-- TOC entry 6132 (class 1259 OID 31794)
-- Name: _hyper_1_154_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_154_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_154_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6133 (class 1259 OID 25117)
-- Name: _hyper_1_154_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_154_chunk_idx_status_region ON _timescaledb_internal._hyper_1_154_chunk USING btree (status, region);


--
-- TOC entry 6134 (class 1259 OID 31900)
-- Name: _hyper_1_154_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_154_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_154_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6135 (class 1259 OID 25116)
-- Name: _hyper_1_154_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_154_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_154_chunk USING btree (event_time DESC);


--
-- TOC entry 6136 (class 1259 OID 25149)
-- Name: _hyper_1_155_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_155_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_155_chunk USING btree (customer_id);


--
-- TOC entry 6137 (class 1259 OID 25148)
-- Name: _hyper_1_155_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_155_chunk_idx_order_region ON _timescaledb_internal._hyper_1_155_chunk USING btree (region);


--
-- TOC entry 6138 (class 1259 OID 25147)
-- Name: _hyper_1_155_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_155_chunk_idx_order_status ON _timescaledb_internal._hyper_1_155_chunk USING btree (status);


--
-- TOC entry 6139 (class 1259 OID 31795)
-- Name: _hyper_1_155_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_155_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_155_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6140 (class 1259 OID 25146)
-- Name: _hyper_1_155_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_155_chunk_idx_status_region ON _timescaledb_internal._hyper_1_155_chunk USING btree (status, region);


--
-- TOC entry 6141 (class 1259 OID 31901)
-- Name: _hyper_1_155_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_155_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_155_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6142 (class 1259 OID 25145)
-- Name: _hyper_1_155_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_155_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_155_chunk USING btree (event_time DESC);


--
-- TOC entry 6143 (class 1259 OID 25178)
-- Name: _hyper_1_156_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_156_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_156_chunk USING btree (customer_id);


--
-- TOC entry 6144 (class 1259 OID 25177)
-- Name: _hyper_1_156_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_156_chunk_idx_order_region ON _timescaledb_internal._hyper_1_156_chunk USING btree (region);


--
-- TOC entry 6145 (class 1259 OID 25176)
-- Name: _hyper_1_156_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_156_chunk_idx_order_status ON _timescaledb_internal._hyper_1_156_chunk USING btree (status);


--
-- TOC entry 6146 (class 1259 OID 31796)
-- Name: _hyper_1_156_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_156_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_156_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6147 (class 1259 OID 25175)
-- Name: _hyper_1_156_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_156_chunk_idx_status_region ON _timescaledb_internal._hyper_1_156_chunk USING btree (status, region);


--
-- TOC entry 6148 (class 1259 OID 31902)
-- Name: _hyper_1_156_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_156_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_156_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6149 (class 1259 OID 25174)
-- Name: _hyper_1_156_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_156_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_156_chunk USING btree (event_time DESC);


--
-- TOC entry 6150 (class 1259 OID 25207)
-- Name: _hyper_1_157_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_157_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_157_chunk USING btree (customer_id);


--
-- TOC entry 6151 (class 1259 OID 25206)
-- Name: _hyper_1_157_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_157_chunk_idx_order_region ON _timescaledb_internal._hyper_1_157_chunk USING btree (region);


--
-- TOC entry 6152 (class 1259 OID 25205)
-- Name: _hyper_1_157_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_157_chunk_idx_order_status ON _timescaledb_internal._hyper_1_157_chunk USING btree (status);


--
-- TOC entry 6153 (class 1259 OID 31797)
-- Name: _hyper_1_157_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_157_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_157_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6154 (class 1259 OID 25204)
-- Name: _hyper_1_157_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_157_chunk_idx_status_region ON _timescaledb_internal._hyper_1_157_chunk USING btree (status, region);


--
-- TOC entry 6155 (class 1259 OID 31903)
-- Name: _hyper_1_157_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_157_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_157_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6156 (class 1259 OID 25203)
-- Name: _hyper_1_157_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_157_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_157_chunk USING btree (event_time DESC);


--
-- TOC entry 5518 (class 1259 OID 21012)
-- Name: _hyper_1_15_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_15_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_15_chunk USING btree (customer_id);


--
-- TOC entry 5519 (class 1259 OID 20957)
-- Name: _hyper_1_15_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_15_chunk_idx_order_region ON _timescaledb_internal._hyper_1_15_chunk USING btree (region);


--
-- TOC entry 5520 (class 1259 OID 20903)
-- Name: _hyper_1_15_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_15_chunk_idx_order_status ON _timescaledb_internal._hyper_1_15_chunk USING btree (status);


--
-- TOC entry 5521 (class 1259 OID 31707)
-- Name: _hyper_1_15_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_15_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_15_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5522 (class 1259 OID 20843)
-- Name: _hyper_1_15_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_15_chunk_idx_status_region ON _timescaledb_internal._hyper_1_15_chunk USING btree (status, region);


--
-- TOC entry 5523 (class 1259 OID 31813)
-- Name: _hyper_1_15_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_15_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_15_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5524 (class 1259 OID 19374)
-- Name: _hyper_1_15_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_15_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_15_chunk USING btree (event_time DESC);


--
-- TOC entry 5525 (class 1259 OID 21013)
-- Name: _hyper_1_16_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_16_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_16_chunk USING btree (customer_id);


--
-- TOC entry 5526 (class 1259 OID 20958)
-- Name: _hyper_1_16_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_16_chunk_idx_order_region ON _timescaledb_internal._hyper_1_16_chunk USING btree (region);


--
-- TOC entry 5527 (class 1259 OID 20904)
-- Name: _hyper_1_16_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_16_chunk_idx_order_status ON _timescaledb_internal._hyper_1_16_chunk USING btree (status);


--
-- TOC entry 5528 (class 1259 OID 31708)
-- Name: _hyper_1_16_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_16_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_16_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5529 (class 1259 OID 20844)
-- Name: _hyper_1_16_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_16_chunk_idx_status_region ON _timescaledb_internal._hyper_1_16_chunk USING btree (status, region);


--
-- TOC entry 5530 (class 1259 OID 31814)
-- Name: _hyper_1_16_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_16_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_16_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5531 (class 1259 OID 19399)
-- Name: _hyper_1_16_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_16_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_16_chunk USING btree (event_time DESC);


--
-- TOC entry 5532 (class 1259 OID 21014)
-- Name: _hyper_1_17_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_17_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_17_chunk USING btree (customer_id);


--
-- TOC entry 5533 (class 1259 OID 20959)
-- Name: _hyper_1_17_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_17_chunk_idx_order_region ON _timescaledb_internal._hyper_1_17_chunk USING btree (region);


--
-- TOC entry 5534 (class 1259 OID 20905)
-- Name: _hyper_1_17_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_17_chunk_idx_order_status ON _timescaledb_internal._hyper_1_17_chunk USING btree (status);


--
-- TOC entry 5535 (class 1259 OID 31709)
-- Name: _hyper_1_17_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_17_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_17_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5536 (class 1259 OID 20845)
-- Name: _hyper_1_17_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_17_chunk_idx_status_region ON _timescaledb_internal._hyper_1_17_chunk USING btree (status, region);


--
-- TOC entry 5537 (class 1259 OID 31815)
-- Name: _hyper_1_17_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_17_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_17_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5538 (class 1259 OID 19424)
-- Name: _hyper_1_17_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_17_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_17_chunk USING btree (event_time DESC);


--
-- TOC entry 5539 (class 1259 OID 21015)
-- Name: _hyper_1_18_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_18_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_18_chunk USING btree (customer_id);


--
-- TOC entry 5540 (class 1259 OID 20960)
-- Name: _hyper_1_18_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_18_chunk_idx_order_region ON _timescaledb_internal._hyper_1_18_chunk USING btree (region);


--
-- TOC entry 5541 (class 1259 OID 20906)
-- Name: _hyper_1_18_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_18_chunk_idx_order_status ON _timescaledb_internal._hyper_1_18_chunk USING btree (status);


--
-- TOC entry 5542 (class 1259 OID 31710)
-- Name: _hyper_1_18_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_18_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_18_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5543 (class 1259 OID 20846)
-- Name: _hyper_1_18_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_18_chunk_idx_status_region ON _timescaledb_internal._hyper_1_18_chunk USING btree (status, region);


--
-- TOC entry 5544 (class 1259 OID 31816)
-- Name: _hyper_1_18_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_18_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_18_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5545 (class 1259 OID 19449)
-- Name: _hyper_1_18_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_18_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_18_chunk USING btree (event_time DESC);


--
-- TOC entry 5546 (class 1259 OID 21016)
-- Name: _hyper_1_19_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_19_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_19_chunk USING btree (customer_id);


--
-- TOC entry 5547 (class 1259 OID 20961)
-- Name: _hyper_1_19_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_19_chunk_idx_order_region ON _timescaledb_internal._hyper_1_19_chunk USING btree (region);


--
-- TOC entry 5548 (class 1259 OID 20907)
-- Name: _hyper_1_19_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_19_chunk_idx_order_status ON _timescaledb_internal._hyper_1_19_chunk USING btree (status);


--
-- TOC entry 5549 (class 1259 OID 31711)
-- Name: _hyper_1_19_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_19_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_19_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5550 (class 1259 OID 20847)
-- Name: _hyper_1_19_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_19_chunk_idx_status_region ON _timescaledb_internal._hyper_1_19_chunk USING btree (status, region);


--
-- TOC entry 5551 (class 1259 OID 31817)
-- Name: _hyper_1_19_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_19_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_19_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5552 (class 1259 OID 19474)
-- Name: _hyper_1_19_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_19_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_19_chunk USING btree (event_time DESC);


--
-- TOC entry 5420 (class 1259 OID 20998)
-- Name: _hyper_1_1_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_1_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_1_chunk USING btree (customer_id);


--
-- TOC entry 5421 (class 1259 OID 20943)
-- Name: _hyper_1_1_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_1_chunk_idx_order_region ON _timescaledb_internal._hyper_1_1_chunk USING btree (region);


--
-- TOC entry 5422 (class 1259 OID 20889)
-- Name: _hyper_1_1_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_1_chunk_idx_order_status ON _timescaledb_internal._hyper_1_1_chunk USING btree (status);


--
-- TOC entry 5423 (class 1259 OID 31693)
-- Name: _hyper_1_1_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_1_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_1_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5424 (class 1259 OID 20829)
-- Name: _hyper_1_1_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_1_chunk_idx_status_region ON _timescaledb_internal._hyper_1_1_chunk USING btree (status, region);


--
-- TOC entry 5425 (class 1259 OID 31799)
-- Name: _hyper_1_1_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_1_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_1_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5426 (class 1259 OID 19024)
-- Name: _hyper_1_1_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_1_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_1_chunk USING btree (event_time DESC);


--
-- TOC entry 5553 (class 1259 OID 21017)
-- Name: _hyper_1_20_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_20_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_20_chunk USING btree (customer_id);


--
-- TOC entry 5554 (class 1259 OID 20962)
-- Name: _hyper_1_20_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_20_chunk_idx_order_region ON _timescaledb_internal._hyper_1_20_chunk USING btree (region);


--
-- TOC entry 5555 (class 1259 OID 20908)
-- Name: _hyper_1_20_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_20_chunk_idx_order_status ON _timescaledb_internal._hyper_1_20_chunk USING btree (status);


--
-- TOC entry 5556 (class 1259 OID 31712)
-- Name: _hyper_1_20_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_20_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_20_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5557 (class 1259 OID 20848)
-- Name: _hyper_1_20_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_20_chunk_idx_status_region ON _timescaledb_internal._hyper_1_20_chunk USING btree (status, region);


--
-- TOC entry 5558 (class 1259 OID 31818)
-- Name: _hyper_1_20_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_20_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_20_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5559 (class 1259 OID 19499)
-- Name: _hyper_1_20_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_20_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_20_chunk USING btree (event_time DESC);


--
-- TOC entry 5560 (class 1259 OID 21018)
-- Name: _hyper_1_21_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_21_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_21_chunk USING btree (customer_id);


--
-- TOC entry 5561 (class 1259 OID 20963)
-- Name: _hyper_1_21_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_21_chunk_idx_order_region ON _timescaledb_internal._hyper_1_21_chunk USING btree (region);


--
-- TOC entry 5562 (class 1259 OID 20909)
-- Name: _hyper_1_21_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_21_chunk_idx_order_status ON _timescaledb_internal._hyper_1_21_chunk USING btree (status);


--
-- TOC entry 5563 (class 1259 OID 31713)
-- Name: _hyper_1_21_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_21_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_21_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5564 (class 1259 OID 20849)
-- Name: _hyper_1_21_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_21_chunk_idx_status_region ON _timescaledb_internal._hyper_1_21_chunk USING btree (status, region);


--
-- TOC entry 5565 (class 1259 OID 31819)
-- Name: _hyper_1_21_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_21_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_21_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5566 (class 1259 OID 19524)
-- Name: _hyper_1_21_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_21_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_21_chunk USING btree (event_time DESC);


--
-- TOC entry 5567 (class 1259 OID 21019)
-- Name: _hyper_1_22_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_22_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_22_chunk USING btree (customer_id);


--
-- TOC entry 5568 (class 1259 OID 20964)
-- Name: _hyper_1_22_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_22_chunk_idx_order_region ON _timescaledb_internal._hyper_1_22_chunk USING btree (region);


--
-- TOC entry 5569 (class 1259 OID 20910)
-- Name: _hyper_1_22_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_22_chunk_idx_order_status ON _timescaledb_internal._hyper_1_22_chunk USING btree (status);


--
-- TOC entry 5570 (class 1259 OID 31714)
-- Name: _hyper_1_22_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_22_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_22_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5571 (class 1259 OID 20850)
-- Name: _hyper_1_22_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_22_chunk_idx_status_region ON _timescaledb_internal._hyper_1_22_chunk USING btree (status, region);


--
-- TOC entry 5572 (class 1259 OID 31820)
-- Name: _hyper_1_22_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_22_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_22_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5573 (class 1259 OID 19549)
-- Name: _hyper_1_22_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_22_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_22_chunk USING btree (event_time DESC);


--
-- TOC entry 5574 (class 1259 OID 21020)
-- Name: _hyper_1_23_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_23_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_23_chunk USING btree (customer_id);


--
-- TOC entry 5575 (class 1259 OID 20965)
-- Name: _hyper_1_23_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_23_chunk_idx_order_region ON _timescaledb_internal._hyper_1_23_chunk USING btree (region);


--
-- TOC entry 5576 (class 1259 OID 20911)
-- Name: _hyper_1_23_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_23_chunk_idx_order_status ON _timescaledb_internal._hyper_1_23_chunk USING btree (status);


--
-- TOC entry 5577 (class 1259 OID 31715)
-- Name: _hyper_1_23_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_23_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_23_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5578 (class 1259 OID 20851)
-- Name: _hyper_1_23_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_23_chunk_idx_status_region ON _timescaledb_internal._hyper_1_23_chunk USING btree (status, region);


--
-- TOC entry 5579 (class 1259 OID 31821)
-- Name: _hyper_1_23_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_23_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_23_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5580 (class 1259 OID 19574)
-- Name: _hyper_1_23_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_23_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_23_chunk USING btree (event_time DESC);


--
-- TOC entry 5581 (class 1259 OID 21021)
-- Name: _hyper_1_24_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_24_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_24_chunk USING btree (customer_id);


--
-- TOC entry 5582 (class 1259 OID 20966)
-- Name: _hyper_1_24_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_24_chunk_idx_order_region ON _timescaledb_internal._hyper_1_24_chunk USING btree (region);


--
-- TOC entry 5583 (class 1259 OID 20912)
-- Name: _hyper_1_24_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_24_chunk_idx_order_status ON _timescaledb_internal._hyper_1_24_chunk USING btree (status);


--
-- TOC entry 5584 (class 1259 OID 31716)
-- Name: _hyper_1_24_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_24_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_24_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5585 (class 1259 OID 20852)
-- Name: _hyper_1_24_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_24_chunk_idx_status_region ON _timescaledb_internal._hyper_1_24_chunk USING btree (status, region);


--
-- TOC entry 5586 (class 1259 OID 31822)
-- Name: _hyper_1_24_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_24_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_24_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5587 (class 1259 OID 19599)
-- Name: _hyper_1_24_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_24_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_24_chunk USING btree (event_time DESC);


--
-- TOC entry 5588 (class 1259 OID 21022)
-- Name: _hyper_1_25_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_25_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_25_chunk USING btree (customer_id);


--
-- TOC entry 5589 (class 1259 OID 20967)
-- Name: _hyper_1_25_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_25_chunk_idx_order_region ON _timescaledb_internal._hyper_1_25_chunk USING btree (region);


--
-- TOC entry 5590 (class 1259 OID 20913)
-- Name: _hyper_1_25_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_25_chunk_idx_order_status ON _timescaledb_internal._hyper_1_25_chunk USING btree (status);


--
-- TOC entry 5591 (class 1259 OID 31717)
-- Name: _hyper_1_25_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_25_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_25_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5592 (class 1259 OID 20853)
-- Name: _hyper_1_25_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_25_chunk_idx_status_region ON _timescaledb_internal._hyper_1_25_chunk USING btree (status, region);


--
-- TOC entry 5593 (class 1259 OID 31823)
-- Name: _hyper_1_25_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_25_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_25_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5594 (class 1259 OID 19624)
-- Name: _hyper_1_25_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_25_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_25_chunk USING btree (event_time DESC);


--
-- TOC entry 5595 (class 1259 OID 21023)
-- Name: _hyper_1_26_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_26_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_26_chunk USING btree (customer_id);


--
-- TOC entry 5596 (class 1259 OID 20968)
-- Name: _hyper_1_26_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_26_chunk_idx_order_region ON _timescaledb_internal._hyper_1_26_chunk USING btree (region);


--
-- TOC entry 5597 (class 1259 OID 20914)
-- Name: _hyper_1_26_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_26_chunk_idx_order_status ON _timescaledb_internal._hyper_1_26_chunk USING btree (status);


--
-- TOC entry 5598 (class 1259 OID 31718)
-- Name: _hyper_1_26_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_26_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_26_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5599 (class 1259 OID 20854)
-- Name: _hyper_1_26_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_26_chunk_idx_status_region ON _timescaledb_internal._hyper_1_26_chunk USING btree (status, region);


--
-- TOC entry 5600 (class 1259 OID 31824)
-- Name: _hyper_1_26_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_26_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_26_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5601 (class 1259 OID 19649)
-- Name: _hyper_1_26_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_26_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_26_chunk USING btree (event_time DESC);


--
-- TOC entry 5602 (class 1259 OID 21024)
-- Name: _hyper_1_27_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_27_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_27_chunk USING btree (customer_id);


--
-- TOC entry 5603 (class 1259 OID 20969)
-- Name: _hyper_1_27_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_27_chunk_idx_order_region ON _timescaledb_internal._hyper_1_27_chunk USING btree (region);


--
-- TOC entry 5604 (class 1259 OID 20915)
-- Name: _hyper_1_27_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_27_chunk_idx_order_status ON _timescaledb_internal._hyper_1_27_chunk USING btree (status);


--
-- TOC entry 5605 (class 1259 OID 31719)
-- Name: _hyper_1_27_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_27_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_27_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5606 (class 1259 OID 20855)
-- Name: _hyper_1_27_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_27_chunk_idx_status_region ON _timescaledb_internal._hyper_1_27_chunk USING btree (status, region);


--
-- TOC entry 5607 (class 1259 OID 31825)
-- Name: _hyper_1_27_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_27_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_27_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5608 (class 1259 OID 19674)
-- Name: _hyper_1_27_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_27_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_27_chunk USING btree (event_time DESC);


--
-- TOC entry 5609 (class 1259 OID 21025)
-- Name: _hyper_1_28_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_28_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_28_chunk USING btree (customer_id);


--
-- TOC entry 5610 (class 1259 OID 20970)
-- Name: _hyper_1_28_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_28_chunk_idx_order_region ON _timescaledb_internal._hyper_1_28_chunk USING btree (region);


--
-- TOC entry 5611 (class 1259 OID 20916)
-- Name: _hyper_1_28_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_28_chunk_idx_order_status ON _timescaledb_internal._hyper_1_28_chunk USING btree (status);


--
-- TOC entry 5612 (class 1259 OID 31720)
-- Name: _hyper_1_28_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_28_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_28_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5613 (class 1259 OID 20856)
-- Name: _hyper_1_28_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_28_chunk_idx_status_region ON _timescaledb_internal._hyper_1_28_chunk USING btree (status, region);


--
-- TOC entry 5614 (class 1259 OID 31826)
-- Name: _hyper_1_28_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_28_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_28_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5615 (class 1259 OID 19699)
-- Name: _hyper_1_28_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_28_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_28_chunk USING btree (event_time DESC);


--
-- TOC entry 5616 (class 1259 OID 21026)
-- Name: _hyper_1_29_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_29_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_29_chunk USING btree (customer_id);


--
-- TOC entry 5617 (class 1259 OID 20971)
-- Name: _hyper_1_29_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_29_chunk_idx_order_region ON _timescaledb_internal._hyper_1_29_chunk USING btree (region);


--
-- TOC entry 5618 (class 1259 OID 20917)
-- Name: _hyper_1_29_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_29_chunk_idx_order_status ON _timescaledb_internal._hyper_1_29_chunk USING btree (status);


--
-- TOC entry 5619 (class 1259 OID 31721)
-- Name: _hyper_1_29_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_29_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_29_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5620 (class 1259 OID 20857)
-- Name: _hyper_1_29_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_29_chunk_idx_status_region ON _timescaledb_internal._hyper_1_29_chunk USING btree (status, region);


--
-- TOC entry 5621 (class 1259 OID 31827)
-- Name: _hyper_1_29_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_29_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_29_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5622 (class 1259 OID 19724)
-- Name: _hyper_1_29_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_29_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_29_chunk USING btree (event_time DESC);


--
-- TOC entry 5427 (class 1259 OID 20999)
-- Name: _hyper_1_2_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_2_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_2_chunk USING btree (customer_id);


--
-- TOC entry 5428 (class 1259 OID 20944)
-- Name: _hyper_1_2_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_2_chunk_idx_order_region ON _timescaledb_internal._hyper_1_2_chunk USING btree (region);


--
-- TOC entry 5429 (class 1259 OID 20890)
-- Name: _hyper_1_2_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_2_chunk_idx_order_status ON _timescaledb_internal._hyper_1_2_chunk USING btree (status);


--
-- TOC entry 5430 (class 1259 OID 31694)
-- Name: _hyper_1_2_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_2_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_2_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5431 (class 1259 OID 20830)
-- Name: _hyper_1_2_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_2_chunk_idx_status_region ON _timescaledb_internal._hyper_1_2_chunk USING btree (status, region);


--
-- TOC entry 5432 (class 1259 OID 31800)
-- Name: _hyper_1_2_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_2_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_2_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5433 (class 1259 OID 19049)
-- Name: _hyper_1_2_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_2_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_2_chunk USING btree (event_time DESC);


--
-- TOC entry 5623 (class 1259 OID 21027)
-- Name: _hyper_1_30_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_30_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_30_chunk USING btree (customer_id);


--
-- TOC entry 5624 (class 1259 OID 20972)
-- Name: _hyper_1_30_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_30_chunk_idx_order_region ON _timescaledb_internal._hyper_1_30_chunk USING btree (region);


--
-- TOC entry 5625 (class 1259 OID 20918)
-- Name: _hyper_1_30_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_30_chunk_idx_order_status ON _timescaledb_internal._hyper_1_30_chunk USING btree (status);


--
-- TOC entry 5626 (class 1259 OID 31722)
-- Name: _hyper_1_30_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_30_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_30_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5627 (class 1259 OID 20858)
-- Name: _hyper_1_30_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_30_chunk_idx_status_region ON _timescaledb_internal._hyper_1_30_chunk USING btree (status, region);


--
-- TOC entry 5628 (class 1259 OID 31828)
-- Name: _hyper_1_30_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_30_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_30_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5629 (class 1259 OID 19749)
-- Name: _hyper_1_30_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_30_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_30_chunk USING btree (event_time DESC);


--
-- TOC entry 5630 (class 1259 OID 21028)
-- Name: _hyper_1_31_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_31_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_31_chunk USING btree (customer_id);


--
-- TOC entry 5631 (class 1259 OID 20973)
-- Name: _hyper_1_31_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_31_chunk_idx_order_region ON _timescaledb_internal._hyper_1_31_chunk USING btree (region);


--
-- TOC entry 5632 (class 1259 OID 20919)
-- Name: _hyper_1_31_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_31_chunk_idx_order_status ON _timescaledb_internal._hyper_1_31_chunk USING btree (status);


--
-- TOC entry 5633 (class 1259 OID 31723)
-- Name: _hyper_1_31_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_31_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_31_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5634 (class 1259 OID 20859)
-- Name: _hyper_1_31_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_31_chunk_idx_status_region ON _timescaledb_internal._hyper_1_31_chunk USING btree (status, region);


--
-- TOC entry 5635 (class 1259 OID 31829)
-- Name: _hyper_1_31_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_31_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_31_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5636 (class 1259 OID 19774)
-- Name: _hyper_1_31_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_31_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_31_chunk USING btree (event_time DESC);


--
-- TOC entry 5637 (class 1259 OID 21029)
-- Name: _hyper_1_32_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_32_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_32_chunk USING btree (customer_id);


--
-- TOC entry 5638 (class 1259 OID 20974)
-- Name: _hyper_1_32_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_32_chunk_idx_order_region ON _timescaledb_internal._hyper_1_32_chunk USING btree (region);


--
-- TOC entry 5639 (class 1259 OID 20920)
-- Name: _hyper_1_32_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_32_chunk_idx_order_status ON _timescaledb_internal._hyper_1_32_chunk USING btree (status);


--
-- TOC entry 5640 (class 1259 OID 31724)
-- Name: _hyper_1_32_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_32_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_32_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5641 (class 1259 OID 20860)
-- Name: _hyper_1_32_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_32_chunk_idx_status_region ON _timescaledb_internal._hyper_1_32_chunk USING btree (status, region);


--
-- TOC entry 5642 (class 1259 OID 31830)
-- Name: _hyper_1_32_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_32_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_32_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5643 (class 1259 OID 19799)
-- Name: _hyper_1_32_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_32_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_32_chunk USING btree (event_time DESC);


--
-- TOC entry 5644 (class 1259 OID 21030)
-- Name: _hyper_1_33_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_33_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_33_chunk USING btree (customer_id);


--
-- TOC entry 5645 (class 1259 OID 20975)
-- Name: _hyper_1_33_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_33_chunk_idx_order_region ON _timescaledb_internal._hyper_1_33_chunk USING btree (region);


--
-- TOC entry 5646 (class 1259 OID 20921)
-- Name: _hyper_1_33_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_33_chunk_idx_order_status ON _timescaledb_internal._hyper_1_33_chunk USING btree (status);


--
-- TOC entry 5647 (class 1259 OID 31725)
-- Name: _hyper_1_33_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_33_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_33_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5648 (class 1259 OID 20861)
-- Name: _hyper_1_33_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_33_chunk_idx_status_region ON _timescaledb_internal._hyper_1_33_chunk USING btree (status, region);


--
-- TOC entry 5649 (class 1259 OID 31831)
-- Name: _hyper_1_33_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_33_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_33_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5650 (class 1259 OID 19824)
-- Name: _hyper_1_33_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_33_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_33_chunk USING btree (event_time DESC);


--
-- TOC entry 5651 (class 1259 OID 21031)
-- Name: _hyper_1_34_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_34_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_34_chunk USING btree (customer_id);


--
-- TOC entry 5652 (class 1259 OID 20976)
-- Name: _hyper_1_34_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_34_chunk_idx_order_region ON _timescaledb_internal._hyper_1_34_chunk USING btree (region);


--
-- TOC entry 5653 (class 1259 OID 20922)
-- Name: _hyper_1_34_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_34_chunk_idx_order_status ON _timescaledb_internal._hyper_1_34_chunk USING btree (status);


--
-- TOC entry 5654 (class 1259 OID 31726)
-- Name: _hyper_1_34_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_34_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_34_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5655 (class 1259 OID 20862)
-- Name: _hyper_1_34_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_34_chunk_idx_status_region ON _timescaledb_internal._hyper_1_34_chunk USING btree (status, region);


--
-- TOC entry 5656 (class 1259 OID 31832)
-- Name: _hyper_1_34_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_34_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_34_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5657 (class 1259 OID 19849)
-- Name: _hyper_1_34_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_34_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_34_chunk USING btree (event_time DESC);


--
-- TOC entry 5658 (class 1259 OID 21032)
-- Name: _hyper_1_35_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_35_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_35_chunk USING btree (customer_id);


--
-- TOC entry 5659 (class 1259 OID 20977)
-- Name: _hyper_1_35_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_35_chunk_idx_order_region ON _timescaledb_internal._hyper_1_35_chunk USING btree (region);


--
-- TOC entry 5660 (class 1259 OID 20923)
-- Name: _hyper_1_35_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_35_chunk_idx_order_status ON _timescaledb_internal._hyper_1_35_chunk USING btree (status);


--
-- TOC entry 5661 (class 1259 OID 31727)
-- Name: _hyper_1_35_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_35_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_35_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5662 (class 1259 OID 20863)
-- Name: _hyper_1_35_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_35_chunk_idx_status_region ON _timescaledb_internal._hyper_1_35_chunk USING btree (status, region);


--
-- TOC entry 5663 (class 1259 OID 31833)
-- Name: _hyper_1_35_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_35_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_35_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5664 (class 1259 OID 19874)
-- Name: _hyper_1_35_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_35_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_35_chunk USING btree (event_time DESC);


--
-- TOC entry 5665 (class 1259 OID 21033)
-- Name: _hyper_1_36_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_36_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_36_chunk USING btree (customer_id);


--
-- TOC entry 5666 (class 1259 OID 20978)
-- Name: _hyper_1_36_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_36_chunk_idx_order_region ON _timescaledb_internal._hyper_1_36_chunk USING btree (region);


--
-- TOC entry 5667 (class 1259 OID 20924)
-- Name: _hyper_1_36_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_36_chunk_idx_order_status ON _timescaledb_internal._hyper_1_36_chunk USING btree (status);


--
-- TOC entry 5668 (class 1259 OID 31728)
-- Name: _hyper_1_36_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_36_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_36_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5669 (class 1259 OID 20864)
-- Name: _hyper_1_36_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_36_chunk_idx_status_region ON _timescaledb_internal._hyper_1_36_chunk USING btree (status, region);


--
-- TOC entry 5670 (class 1259 OID 31834)
-- Name: _hyper_1_36_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_36_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_36_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5671 (class 1259 OID 19899)
-- Name: _hyper_1_36_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_36_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_36_chunk USING btree (event_time DESC);


--
-- TOC entry 5672 (class 1259 OID 21034)
-- Name: _hyper_1_37_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_37_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_37_chunk USING btree (customer_id);


--
-- TOC entry 5673 (class 1259 OID 20979)
-- Name: _hyper_1_37_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_37_chunk_idx_order_region ON _timescaledb_internal._hyper_1_37_chunk USING btree (region);


--
-- TOC entry 5674 (class 1259 OID 20925)
-- Name: _hyper_1_37_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_37_chunk_idx_order_status ON _timescaledb_internal._hyper_1_37_chunk USING btree (status);


--
-- TOC entry 5675 (class 1259 OID 31729)
-- Name: _hyper_1_37_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_37_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_37_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5676 (class 1259 OID 20865)
-- Name: _hyper_1_37_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_37_chunk_idx_status_region ON _timescaledb_internal._hyper_1_37_chunk USING btree (status, region);


--
-- TOC entry 5677 (class 1259 OID 31835)
-- Name: _hyper_1_37_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_37_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_37_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5678 (class 1259 OID 19924)
-- Name: _hyper_1_37_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_37_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_37_chunk USING btree (event_time DESC);


--
-- TOC entry 5679 (class 1259 OID 21035)
-- Name: _hyper_1_38_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_38_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_38_chunk USING btree (customer_id);


--
-- TOC entry 5680 (class 1259 OID 20980)
-- Name: _hyper_1_38_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_38_chunk_idx_order_region ON _timescaledb_internal._hyper_1_38_chunk USING btree (region);


--
-- TOC entry 5681 (class 1259 OID 20926)
-- Name: _hyper_1_38_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_38_chunk_idx_order_status ON _timescaledb_internal._hyper_1_38_chunk USING btree (status);


--
-- TOC entry 5682 (class 1259 OID 31730)
-- Name: _hyper_1_38_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_38_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_38_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5683 (class 1259 OID 20866)
-- Name: _hyper_1_38_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_38_chunk_idx_status_region ON _timescaledb_internal._hyper_1_38_chunk USING btree (status, region);


--
-- TOC entry 5684 (class 1259 OID 31836)
-- Name: _hyper_1_38_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_38_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_38_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5685 (class 1259 OID 19949)
-- Name: _hyper_1_38_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_38_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_38_chunk USING btree (event_time DESC);


--
-- TOC entry 5686 (class 1259 OID 21036)
-- Name: _hyper_1_39_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_39_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_39_chunk USING btree (customer_id);


--
-- TOC entry 5687 (class 1259 OID 20981)
-- Name: _hyper_1_39_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_39_chunk_idx_order_region ON _timescaledb_internal._hyper_1_39_chunk USING btree (region);


--
-- TOC entry 5688 (class 1259 OID 20927)
-- Name: _hyper_1_39_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_39_chunk_idx_order_status ON _timescaledb_internal._hyper_1_39_chunk USING btree (status);


--
-- TOC entry 5689 (class 1259 OID 31731)
-- Name: _hyper_1_39_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_39_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_39_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5690 (class 1259 OID 20867)
-- Name: _hyper_1_39_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_39_chunk_idx_status_region ON _timescaledb_internal._hyper_1_39_chunk USING btree (status, region);


--
-- TOC entry 5691 (class 1259 OID 31837)
-- Name: _hyper_1_39_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_39_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_39_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5692 (class 1259 OID 19974)
-- Name: _hyper_1_39_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_39_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_39_chunk USING btree (event_time DESC);


--
-- TOC entry 5434 (class 1259 OID 21000)
-- Name: _hyper_1_3_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_3_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_3_chunk USING btree (customer_id);


--
-- TOC entry 5435 (class 1259 OID 20945)
-- Name: _hyper_1_3_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_3_chunk_idx_order_region ON _timescaledb_internal._hyper_1_3_chunk USING btree (region);


--
-- TOC entry 5436 (class 1259 OID 20891)
-- Name: _hyper_1_3_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_3_chunk_idx_order_status ON _timescaledb_internal._hyper_1_3_chunk USING btree (status);


--
-- TOC entry 5437 (class 1259 OID 31695)
-- Name: _hyper_1_3_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_3_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_3_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5438 (class 1259 OID 20831)
-- Name: _hyper_1_3_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_3_chunk_idx_status_region ON _timescaledb_internal._hyper_1_3_chunk USING btree (status, region);


--
-- TOC entry 5439 (class 1259 OID 31801)
-- Name: _hyper_1_3_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_3_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_3_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5440 (class 1259 OID 19074)
-- Name: _hyper_1_3_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_3_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_3_chunk USING btree (event_time DESC);


--
-- TOC entry 5693 (class 1259 OID 21037)
-- Name: _hyper_1_40_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_40_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_40_chunk USING btree (customer_id);


--
-- TOC entry 5694 (class 1259 OID 20982)
-- Name: _hyper_1_40_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_40_chunk_idx_order_region ON _timescaledb_internal._hyper_1_40_chunk USING btree (region);


--
-- TOC entry 5695 (class 1259 OID 20928)
-- Name: _hyper_1_40_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_40_chunk_idx_order_status ON _timescaledb_internal._hyper_1_40_chunk USING btree (status);


--
-- TOC entry 5696 (class 1259 OID 31732)
-- Name: _hyper_1_40_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_40_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_40_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5697 (class 1259 OID 20868)
-- Name: _hyper_1_40_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_40_chunk_idx_status_region ON _timescaledb_internal._hyper_1_40_chunk USING btree (status, region);


--
-- TOC entry 5698 (class 1259 OID 31838)
-- Name: _hyper_1_40_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_40_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_40_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5699 (class 1259 OID 19999)
-- Name: _hyper_1_40_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_40_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_40_chunk USING btree (event_time DESC);


--
-- TOC entry 5700 (class 1259 OID 21038)
-- Name: _hyper_1_41_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_41_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_41_chunk USING btree (customer_id);


--
-- TOC entry 5701 (class 1259 OID 20983)
-- Name: _hyper_1_41_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_41_chunk_idx_order_region ON _timescaledb_internal._hyper_1_41_chunk USING btree (region);


--
-- TOC entry 5702 (class 1259 OID 20929)
-- Name: _hyper_1_41_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_41_chunk_idx_order_status ON _timescaledb_internal._hyper_1_41_chunk USING btree (status);


--
-- TOC entry 5703 (class 1259 OID 31733)
-- Name: _hyper_1_41_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_41_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_41_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5704 (class 1259 OID 20869)
-- Name: _hyper_1_41_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_41_chunk_idx_status_region ON _timescaledb_internal._hyper_1_41_chunk USING btree (status, region);


--
-- TOC entry 5705 (class 1259 OID 31839)
-- Name: _hyper_1_41_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_41_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_41_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5706 (class 1259 OID 20024)
-- Name: _hyper_1_41_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_41_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_41_chunk USING btree (event_time DESC);


--
-- TOC entry 5707 (class 1259 OID 21039)
-- Name: _hyper_1_42_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_42_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_42_chunk USING btree (customer_id);


--
-- TOC entry 5708 (class 1259 OID 20984)
-- Name: _hyper_1_42_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_42_chunk_idx_order_region ON _timescaledb_internal._hyper_1_42_chunk USING btree (region);


--
-- TOC entry 5709 (class 1259 OID 20930)
-- Name: _hyper_1_42_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_42_chunk_idx_order_status ON _timescaledb_internal._hyper_1_42_chunk USING btree (status);


--
-- TOC entry 5710 (class 1259 OID 31734)
-- Name: _hyper_1_42_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_42_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_42_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5711 (class 1259 OID 20870)
-- Name: _hyper_1_42_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_42_chunk_idx_status_region ON _timescaledb_internal._hyper_1_42_chunk USING btree (status, region);


--
-- TOC entry 5712 (class 1259 OID 31840)
-- Name: _hyper_1_42_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_42_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_42_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5713 (class 1259 OID 20049)
-- Name: _hyper_1_42_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_42_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_42_chunk USING btree (event_time DESC);


--
-- TOC entry 5714 (class 1259 OID 21040)
-- Name: _hyper_1_43_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_43_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_43_chunk USING btree (customer_id);


--
-- TOC entry 5715 (class 1259 OID 20985)
-- Name: _hyper_1_43_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_43_chunk_idx_order_region ON _timescaledb_internal._hyper_1_43_chunk USING btree (region);


--
-- TOC entry 5716 (class 1259 OID 20931)
-- Name: _hyper_1_43_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_43_chunk_idx_order_status ON _timescaledb_internal._hyper_1_43_chunk USING btree (status);


--
-- TOC entry 5717 (class 1259 OID 31735)
-- Name: _hyper_1_43_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_43_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_43_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5718 (class 1259 OID 20871)
-- Name: _hyper_1_43_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_43_chunk_idx_status_region ON _timescaledb_internal._hyper_1_43_chunk USING btree (status, region);


--
-- TOC entry 5719 (class 1259 OID 31841)
-- Name: _hyper_1_43_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_43_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_43_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5720 (class 1259 OID 20074)
-- Name: _hyper_1_43_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_43_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_43_chunk USING btree (event_time DESC);


--
-- TOC entry 5721 (class 1259 OID 21041)
-- Name: _hyper_1_44_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_44_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_44_chunk USING btree (customer_id);


--
-- TOC entry 5722 (class 1259 OID 20986)
-- Name: _hyper_1_44_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_44_chunk_idx_order_region ON _timescaledb_internal._hyper_1_44_chunk USING btree (region);


--
-- TOC entry 5723 (class 1259 OID 20932)
-- Name: _hyper_1_44_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_44_chunk_idx_order_status ON _timescaledb_internal._hyper_1_44_chunk USING btree (status);


--
-- TOC entry 5724 (class 1259 OID 31736)
-- Name: _hyper_1_44_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_44_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_44_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5725 (class 1259 OID 20872)
-- Name: _hyper_1_44_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_44_chunk_idx_status_region ON _timescaledb_internal._hyper_1_44_chunk USING btree (status, region);


--
-- TOC entry 5726 (class 1259 OID 31842)
-- Name: _hyper_1_44_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_44_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_44_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5727 (class 1259 OID 20099)
-- Name: _hyper_1_44_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_44_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_44_chunk USING btree (event_time DESC);


--
-- TOC entry 5728 (class 1259 OID 21042)
-- Name: _hyper_1_45_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_45_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_45_chunk USING btree (customer_id);


--
-- TOC entry 5729 (class 1259 OID 20987)
-- Name: _hyper_1_45_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_45_chunk_idx_order_region ON _timescaledb_internal._hyper_1_45_chunk USING btree (region);


--
-- TOC entry 5730 (class 1259 OID 20933)
-- Name: _hyper_1_45_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_45_chunk_idx_order_status ON _timescaledb_internal._hyper_1_45_chunk USING btree (status);


--
-- TOC entry 5731 (class 1259 OID 31737)
-- Name: _hyper_1_45_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_45_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_45_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5732 (class 1259 OID 20873)
-- Name: _hyper_1_45_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_45_chunk_idx_status_region ON _timescaledb_internal._hyper_1_45_chunk USING btree (status, region);


--
-- TOC entry 5733 (class 1259 OID 31843)
-- Name: _hyper_1_45_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_45_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_45_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5734 (class 1259 OID 20124)
-- Name: _hyper_1_45_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_45_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_45_chunk USING btree (event_time DESC);


--
-- TOC entry 5735 (class 1259 OID 21043)
-- Name: _hyper_1_46_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_46_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_46_chunk USING btree (customer_id);


--
-- TOC entry 5736 (class 1259 OID 20988)
-- Name: _hyper_1_46_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_46_chunk_idx_order_region ON _timescaledb_internal._hyper_1_46_chunk USING btree (region);


--
-- TOC entry 5737 (class 1259 OID 20934)
-- Name: _hyper_1_46_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_46_chunk_idx_order_status ON _timescaledb_internal._hyper_1_46_chunk USING btree (status);


--
-- TOC entry 5738 (class 1259 OID 31738)
-- Name: _hyper_1_46_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_46_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_46_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5739 (class 1259 OID 20874)
-- Name: _hyper_1_46_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_46_chunk_idx_status_region ON _timescaledb_internal._hyper_1_46_chunk USING btree (status, region);


--
-- TOC entry 5740 (class 1259 OID 31844)
-- Name: _hyper_1_46_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_46_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_46_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5741 (class 1259 OID 20149)
-- Name: _hyper_1_46_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_46_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_46_chunk USING btree (event_time DESC);


--
-- TOC entry 5742 (class 1259 OID 21044)
-- Name: _hyper_1_47_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_47_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_47_chunk USING btree (customer_id);


--
-- TOC entry 5743 (class 1259 OID 20989)
-- Name: _hyper_1_47_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_47_chunk_idx_order_region ON _timescaledb_internal._hyper_1_47_chunk USING btree (region);


--
-- TOC entry 5744 (class 1259 OID 20935)
-- Name: _hyper_1_47_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_47_chunk_idx_order_status ON _timescaledb_internal._hyper_1_47_chunk USING btree (status);


--
-- TOC entry 5745 (class 1259 OID 31739)
-- Name: _hyper_1_47_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_47_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_47_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5746 (class 1259 OID 20875)
-- Name: _hyper_1_47_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_47_chunk_idx_status_region ON _timescaledb_internal._hyper_1_47_chunk USING btree (status, region);


--
-- TOC entry 5747 (class 1259 OID 31845)
-- Name: _hyper_1_47_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_47_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_47_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5748 (class 1259 OID 20174)
-- Name: _hyper_1_47_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_47_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_47_chunk USING btree (event_time DESC);


--
-- TOC entry 5749 (class 1259 OID 21045)
-- Name: _hyper_1_48_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_48_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_48_chunk USING btree (customer_id);


--
-- TOC entry 5750 (class 1259 OID 20990)
-- Name: _hyper_1_48_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_48_chunk_idx_order_region ON _timescaledb_internal._hyper_1_48_chunk USING btree (region);


--
-- TOC entry 5751 (class 1259 OID 20936)
-- Name: _hyper_1_48_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_48_chunk_idx_order_status ON _timescaledb_internal._hyper_1_48_chunk USING btree (status);


--
-- TOC entry 5752 (class 1259 OID 31740)
-- Name: _hyper_1_48_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_48_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_48_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5753 (class 1259 OID 20876)
-- Name: _hyper_1_48_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_48_chunk_idx_status_region ON _timescaledb_internal._hyper_1_48_chunk USING btree (status, region);


--
-- TOC entry 5754 (class 1259 OID 31846)
-- Name: _hyper_1_48_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_48_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_48_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5755 (class 1259 OID 20199)
-- Name: _hyper_1_48_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_48_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_48_chunk USING btree (event_time DESC);


--
-- TOC entry 5756 (class 1259 OID 21046)
-- Name: _hyper_1_49_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_49_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_49_chunk USING btree (customer_id);


--
-- TOC entry 5757 (class 1259 OID 20991)
-- Name: _hyper_1_49_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_49_chunk_idx_order_region ON _timescaledb_internal._hyper_1_49_chunk USING btree (region);


--
-- TOC entry 5758 (class 1259 OID 20937)
-- Name: _hyper_1_49_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_49_chunk_idx_order_status ON _timescaledb_internal._hyper_1_49_chunk USING btree (status);


--
-- TOC entry 5759 (class 1259 OID 31741)
-- Name: _hyper_1_49_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_49_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_49_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5760 (class 1259 OID 20877)
-- Name: _hyper_1_49_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_49_chunk_idx_status_region ON _timescaledb_internal._hyper_1_49_chunk USING btree (status, region);


--
-- TOC entry 5761 (class 1259 OID 31847)
-- Name: _hyper_1_49_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_49_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_49_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5762 (class 1259 OID 20224)
-- Name: _hyper_1_49_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_49_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_49_chunk USING btree (event_time DESC);


--
-- TOC entry 5441 (class 1259 OID 21001)
-- Name: _hyper_1_4_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_4_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_4_chunk USING btree (customer_id);


--
-- TOC entry 5442 (class 1259 OID 20946)
-- Name: _hyper_1_4_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_4_chunk_idx_order_region ON _timescaledb_internal._hyper_1_4_chunk USING btree (region);


--
-- TOC entry 5443 (class 1259 OID 20892)
-- Name: _hyper_1_4_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_4_chunk_idx_order_status ON _timescaledb_internal._hyper_1_4_chunk USING btree (status);


--
-- TOC entry 5444 (class 1259 OID 31696)
-- Name: _hyper_1_4_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_4_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_4_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5445 (class 1259 OID 20832)
-- Name: _hyper_1_4_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_4_chunk_idx_status_region ON _timescaledb_internal._hyper_1_4_chunk USING btree (status, region);


--
-- TOC entry 5446 (class 1259 OID 31802)
-- Name: _hyper_1_4_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_4_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_4_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5447 (class 1259 OID 19099)
-- Name: _hyper_1_4_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_4_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_4_chunk USING btree (event_time DESC);


--
-- TOC entry 5763 (class 1259 OID 21047)
-- Name: _hyper_1_50_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_50_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_50_chunk USING btree (customer_id);


--
-- TOC entry 5764 (class 1259 OID 20992)
-- Name: _hyper_1_50_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_50_chunk_idx_order_region ON _timescaledb_internal._hyper_1_50_chunk USING btree (region);


--
-- TOC entry 5765 (class 1259 OID 20938)
-- Name: _hyper_1_50_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_50_chunk_idx_order_status ON _timescaledb_internal._hyper_1_50_chunk USING btree (status);


--
-- TOC entry 5766 (class 1259 OID 31742)
-- Name: _hyper_1_50_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_50_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_50_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5767 (class 1259 OID 20878)
-- Name: _hyper_1_50_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_50_chunk_idx_status_region ON _timescaledb_internal._hyper_1_50_chunk USING btree (status, region);


--
-- TOC entry 5768 (class 1259 OID 31848)
-- Name: _hyper_1_50_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_50_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_50_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5769 (class 1259 OID 20249)
-- Name: _hyper_1_50_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_50_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_50_chunk USING btree (event_time DESC);


--
-- TOC entry 5770 (class 1259 OID 21048)
-- Name: _hyper_1_51_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_51_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_51_chunk USING btree (customer_id);


--
-- TOC entry 5771 (class 1259 OID 20993)
-- Name: _hyper_1_51_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_51_chunk_idx_order_region ON _timescaledb_internal._hyper_1_51_chunk USING btree (region);


--
-- TOC entry 5772 (class 1259 OID 20939)
-- Name: _hyper_1_51_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_51_chunk_idx_order_status ON _timescaledb_internal._hyper_1_51_chunk USING btree (status);


--
-- TOC entry 5773 (class 1259 OID 31743)
-- Name: _hyper_1_51_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_51_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_51_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5774 (class 1259 OID 20879)
-- Name: _hyper_1_51_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_51_chunk_idx_status_region ON _timescaledb_internal._hyper_1_51_chunk USING btree (status, region);


--
-- TOC entry 5775 (class 1259 OID 31849)
-- Name: _hyper_1_51_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_51_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_51_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5776 (class 1259 OID 20274)
-- Name: _hyper_1_51_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_51_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_51_chunk USING btree (event_time DESC);


--
-- TOC entry 5777 (class 1259 OID 21049)
-- Name: _hyper_1_52_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_52_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_52_chunk USING btree (customer_id);


--
-- TOC entry 5778 (class 1259 OID 20994)
-- Name: _hyper_1_52_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_52_chunk_idx_order_region ON _timescaledb_internal._hyper_1_52_chunk USING btree (region);


--
-- TOC entry 5779 (class 1259 OID 20940)
-- Name: _hyper_1_52_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_52_chunk_idx_order_status ON _timescaledb_internal._hyper_1_52_chunk USING btree (status);


--
-- TOC entry 5780 (class 1259 OID 31744)
-- Name: _hyper_1_52_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_52_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_52_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5781 (class 1259 OID 20880)
-- Name: _hyper_1_52_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_52_chunk_idx_status_region ON _timescaledb_internal._hyper_1_52_chunk USING btree (status, region);


--
-- TOC entry 5782 (class 1259 OID 31850)
-- Name: _hyper_1_52_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_52_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_52_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5783 (class 1259 OID 20299)
-- Name: _hyper_1_52_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_52_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_52_chunk USING btree (event_time DESC);


--
-- TOC entry 5784 (class 1259 OID 21050)
-- Name: _hyper_1_53_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_53_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_53_chunk USING btree (customer_id);


--
-- TOC entry 5785 (class 1259 OID 20995)
-- Name: _hyper_1_53_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_53_chunk_idx_order_region ON _timescaledb_internal._hyper_1_53_chunk USING btree (region);


--
-- TOC entry 5786 (class 1259 OID 20941)
-- Name: _hyper_1_53_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_53_chunk_idx_order_status ON _timescaledb_internal._hyper_1_53_chunk USING btree (status);


--
-- TOC entry 5787 (class 1259 OID 31745)
-- Name: _hyper_1_53_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_53_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_53_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5788 (class 1259 OID 20881)
-- Name: _hyper_1_53_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_53_chunk_idx_status_region ON _timescaledb_internal._hyper_1_53_chunk USING btree (status, region);


--
-- TOC entry 5789 (class 1259 OID 31851)
-- Name: _hyper_1_53_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_53_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_53_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5790 (class 1259 OID 20324)
-- Name: _hyper_1_53_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_53_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_53_chunk USING btree (event_time DESC);


--
-- TOC entry 5448 (class 1259 OID 21002)
-- Name: _hyper_1_5_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_5_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_5_chunk USING btree (customer_id);


--
-- TOC entry 5449 (class 1259 OID 20947)
-- Name: _hyper_1_5_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_5_chunk_idx_order_region ON _timescaledb_internal._hyper_1_5_chunk USING btree (region);


--
-- TOC entry 5450 (class 1259 OID 20893)
-- Name: _hyper_1_5_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_5_chunk_idx_order_status ON _timescaledb_internal._hyper_1_5_chunk USING btree (status);


--
-- TOC entry 5451 (class 1259 OID 31697)
-- Name: _hyper_1_5_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_5_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_5_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5452 (class 1259 OID 20833)
-- Name: _hyper_1_5_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_5_chunk_idx_status_region ON _timescaledb_internal._hyper_1_5_chunk USING btree (status, region);


--
-- TOC entry 5453 (class 1259 OID 31803)
-- Name: _hyper_1_5_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_5_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_5_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5454 (class 1259 OID 19124)
-- Name: _hyper_1_5_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_5_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_5_chunk USING btree (event_time DESC);


--
-- TOC entry 5455 (class 1259 OID 21003)
-- Name: _hyper_1_6_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_6_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_6_chunk USING btree (customer_id);


--
-- TOC entry 5456 (class 1259 OID 20948)
-- Name: _hyper_1_6_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_6_chunk_idx_order_region ON _timescaledb_internal._hyper_1_6_chunk USING btree (region);


--
-- TOC entry 5457 (class 1259 OID 20894)
-- Name: _hyper_1_6_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_6_chunk_idx_order_status ON _timescaledb_internal._hyper_1_6_chunk USING btree (status);


--
-- TOC entry 5458 (class 1259 OID 31698)
-- Name: _hyper_1_6_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_6_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_6_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5459 (class 1259 OID 20834)
-- Name: _hyper_1_6_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_6_chunk_idx_status_region ON _timescaledb_internal._hyper_1_6_chunk USING btree (status, region);


--
-- TOC entry 5460 (class 1259 OID 31804)
-- Name: _hyper_1_6_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_6_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_6_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5461 (class 1259 OID 19149)
-- Name: _hyper_1_6_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_6_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_6_chunk USING btree (event_time DESC);


--
-- TOC entry 5462 (class 1259 OID 21004)
-- Name: _hyper_1_7_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_7_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_7_chunk USING btree (customer_id);


--
-- TOC entry 5463 (class 1259 OID 20949)
-- Name: _hyper_1_7_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_7_chunk_idx_order_region ON _timescaledb_internal._hyper_1_7_chunk USING btree (region);


--
-- TOC entry 5464 (class 1259 OID 20895)
-- Name: _hyper_1_7_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_7_chunk_idx_order_status ON _timescaledb_internal._hyper_1_7_chunk USING btree (status);


--
-- TOC entry 5465 (class 1259 OID 31699)
-- Name: _hyper_1_7_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_7_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_7_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5466 (class 1259 OID 20835)
-- Name: _hyper_1_7_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_7_chunk_idx_status_region ON _timescaledb_internal._hyper_1_7_chunk USING btree (status, region);


--
-- TOC entry 5467 (class 1259 OID 31805)
-- Name: _hyper_1_7_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_7_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_7_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5468 (class 1259 OID 19174)
-- Name: _hyper_1_7_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_7_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_7_chunk USING btree (event_time DESC);


--
-- TOC entry 5469 (class 1259 OID 21005)
-- Name: _hyper_1_8_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_8_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_8_chunk USING btree (customer_id);


--
-- TOC entry 5470 (class 1259 OID 20950)
-- Name: _hyper_1_8_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_8_chunk_idx_order_region ON _timescaledb_internal._hyper_1_8_chunk USING btree (region);


--
-- TOC entry 5471 (class 1259 OID 20896)
-- Name: _hyper_1_8_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_8_chunk_idx_order_status ON _timescaledb_internal._hyper_1_8_chunk USING btree (status);


--
-- TOC entry 5472 (class 1259 OID 31700)
-- Name: _hyper_1_8_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_8_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_8_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5473 (class 1259 OID 20836)
-- Name: _hyper_1_8_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_8_chunk_idx_status_region ON _timescaledb_internal._hyper_1_8_chunk USING btree (status, region);


--
-- TOC entry 5474 (class 1259 OID 31806)
-- Name: _hyper_1_8_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_8_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_8_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5475 (class 1259 OID 19199)
-- Name: _hyper_1_8_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_8_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_8_chunk USING btree (event_time DESC);


--
-- TOC entry 5476 (class 1259 OID 21006)
-- Name: _hyper_1_9_chunk_idx_order_customer; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_9_chunk_idx_order_customer ON _timescaledb_internal._hyper_1_9_chunk USING btree (customer_id);


--
-- TOC entry 5477 (class 1259 OID 20951)
-- Name: _hyper_1_9_chunk_idx_order_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_9_chunk_idx_order_region ON _timescaledb_internal._hyper_1_9_chunk USING btree (region);


--
-- TOC entry 5478 (class 1259 OID 20897)
-- Name: _hyper_1_9_chunk_idx_order_status; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_9_chunk_idx_order_status ON _timescaledb_internal._hyper_1_9_chunk USING btree (status);


--
-- TOC entry 5479 (class 1259 OID 31701)
-- Name: _hyper_1_9_chunk_idx_status_completed; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_9_chunk_idx_status_completed ON _timescaledb_internal._hyper_1_9_chunk USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5480 (class 1259 OID 20837)
-- Name: _hyper_1_9_chunk_idx_status_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_9_chunk_idx_status_region ON _timescaledb_internal._hyper_1_9_chunk USING btree (status, region);


--
-- TOC entry 5481 (class 1259 OID 31807)
-- Name: _hyper_1_9_chunk_idx_status_time_region; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_9_chunk_idx_status_time_region ON _timescaledb_internal._hyper_1_9_chunk USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 5482 (class 1259 OID 19224)
-- Name: _hyper_1_9_chunk_order_events_event_time_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_1_9_chunk_order_events_event_time_idx ON _timescaledb_internal._hyper_1_9_chunk USING btree (event_time DESC);


--
-- TOC entry 6260 (class 1259 OID 30592)
-- Name: _hyper_3_258_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_258_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_258_chunk USING btree (bucket DESC);


--
-- TOC entry 6261 (class 1259 OID 30593)
-- Name: _hyper_3_258_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_258_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_258_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6262 (class 1259 OID 30594)
-- Name: _hyper_3_258_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_258_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_258_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6263 (class 1259 OID 30601)
-- Name: _hyper_3_259_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_259_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_259_chunk USING btree (bucket DESC);


--
-- TOC entry 6264 (class 1259 OID 30602)
-- Name: _hyper_3_259_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_259_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_259_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6265 (class 1259 OID 30603)
-- Name: _hyper_3_259_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_259_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_259_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6266 (class 1259 OID 30610)
-- Name: _hyper_3_260_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_260_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_260_chunk USING btree (bucket DESC);


--
-- TOC entry 6267 (class 1259 OID 30611)
-- Name: _hyper_3_260_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_260_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_260_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6268 (class 1259 OID 30612)
-- Name: _hyper_3_260_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_260_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_260_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6269 (class 1259 OID 30619)
-- Name: _hyper_3_261_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_261_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_261_chunk USING btree (bucket DESC);


--
-- TOC entry 6270 (class 1259 OID 30620)
-- Name: _hyper_3_261_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_261_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_261_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6271 (class 1259 OID 30621)
-- Name: _hyper_3_261_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_261_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_261_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6272 (class 1259 OID 30628)
-- Name: _hyper_3_262_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_262_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_262_chunk USING btree (bucket DESC);


--
-- TOC entry 6273 (class 1259 OID 30629)
-- Name: _hyper_3_262_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_262_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_262_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6274 (class 1259 OID 30630)
-- Name: _hyper_3_262_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_262_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_262_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6275 (class 1259 OID 30637)
-- Name: _hyper_3_263_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_263_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_263_chunk USING btree (bucket DESC);


--
-- TOC entry 6276 (class 1259 OID 30638)
-- Name: _hyper_3_263_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_263_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_263_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6277 (class 1259 OID 30639)
-- Name: _hyper_3_263_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_263_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_263_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6278 (class 1259 OID 30646)
-- Name: _hyper_3_264_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_264_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_264_chunk USING btree (bucket DESC);


--
-- TOC entry 6279 (class 1259 OID 30647)
-- Name: _hyper_3_264_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_264_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_264_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6280 (class 1259 OID 30648)
-- Name: _hyper_3_264_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_264_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_264_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6281 (class 1259 OID 30655)
-- Name: _hyper_3_265_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_265_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_265_chunk USING btree (bucket DESC);


--
-- TOC entry 6282 (class 1259 OID 30656)
-- Name: _hyper_3_265_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_265_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_265_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6283 (class 1259 OID 30657)
-- Name: _hyper_3_265_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_265_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_265_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6284 (class 1259 OID 30664)
-- Name: _hyper_3_266_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_266_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_266_chunk USING btree (bucket DESC);


--
-- TOC entry 6285 (class 1259 OID 30665)
-- Name: _hyper_3_266_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_266_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_266_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6286 (class 1259 OID 30666)
-- Name: _hyper_3_266_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_266_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_266_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6287 (class 1259 OID 30673)
-- Name: _hyper_3_267_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_267_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_267_chunk USING btree (bucket DESC);


--
-- TOC entry 6288 (class 1259 OID 30674)
-- Name: _hyper_3_267_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_267_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_267_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6289 (class 1259 OID 30675)
-- Name: _hyper_3_267_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_267_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_267_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6290 (class 1259 OID 30682)
-- Name: _hyper_3_268_chunk__materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_268_chunk__materialized_hypertable_3_bucket_idx ON _timescaledb_internal._hyper_3_268_chunk USING btree (bucket DESC);


--
-- TOC entry 6291 (class 1259 OID 30683)
-- Name: _hyper_3_268_chunk__materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_268_chunk__materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._hyper_3_268_chunk USING btree (region, bucket DESC);


--
-- TOC entry 6292 (class 1259 OID 30684)
-- Name: _hyper_3_268_chunk__materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _hyper_3_268_chunk__materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._hyper_3_268_chunk USING btree (status, bucket DESC);


--
-- TOC entry 6257 (class 1259 OID 30563)
-- Name: _materialized_hypertable_3_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _materialized_hypertable_3_bucket_idx ON _timescaledb_internal._materialized_hypertable_3 USING btree (bucket DESC);


--
-- TOC entry 6258 (class 1259 OID 30564)
-- Name: _materialized_hypertable_3_region_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _materialized_hypertable_3_region_bucket_idx ON _timescaledb_internal._materialized_hypertable_3 USING btree (region, bucket DESC);


--
-- TOC entry 6259 (class 1259 OID 30565)
-- Name: _materialized_hypertable_3_status_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX _materialized_hypertable_3_status_bucket_idx ON _timescaledb_internal._materialized_hypertable_3 USING btree (status, bucket DESC);


--
-- TOC entry 6157 (class 1259 OID 25218)
-- Name: compress_hyper_2_158_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_158_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_158_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6158 (class 1259 OID 25272)
-- Name: compress_hyper_2_159_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_159_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_159_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6159 (class 1259 OID 25326)
-- Name: compress_hyper_2_160_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_160_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_160_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6160 (class 1259 OID 25380)
-- Name: compress_hyper_2_161_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_161_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_161_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6161 (class 1259 OID 25434)
-- Name: compress_hyper_2_162_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_162_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_162_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6162 (class 1259 OID 25488)
-- Name: compress_hyper_2_163_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_163_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_163_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6163 (class 1259 OID 25542)
-- Name: compress_hyper_2_164_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_164_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_164_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6164 (class 1259 OID 25596)
-- Name: compress_hyper_2_165_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_165_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_165_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6165 (class 1259 OID 25650)
-- Name: compress_hyper_2_166_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_166_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_166_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6166 (class 1259 OID 25704)
-- Name: compress_hyper_2_167_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_167_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_167_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6167 (class 1259 OID 25758)
-- Name: compress_hyper_2_168_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_168_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_168_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6168 (class 1259 OID 25812)
-- Name: compress_hyper_2_169_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_169_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_169_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6169 (class 1259 OID 25866)
-- Name: compress_hyper_2_170_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_170_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_170_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6170 (class 1259 OID 25920)
-- Name: compress_hyper_2_171_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_171_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_171_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6171 (class 1259 OID 25974)
-- Name: compress_hyper_2_172_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_172_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_172_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6172 (class 1259 OID 26028)
-- Name: compress_hyper_2_173_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_173_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_173_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6173 (class 1259 OID 26082)
-- Name: compress_hyper_2_174_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_174_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_174_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6174 (class 1259 OID 26136)
-- Name: compress_hyper_2_175_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_175_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_175_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6175 (class 1259 OID 26190)
-- Name: compress_hyper_2_176_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_176_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_176_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6176 (class 1259 OID 26244)
-- Name: compress_hyper_2_177_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_177_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_177_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6177 (class 1259 OID 26298)
-- Name: compress_hyper_2_178_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_178_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_178_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6178 (class 1259 OID 26352)
-- Name: compress_hyper_2_179_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_179_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_179_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6179 (class 1259 OID 26406)
-- Name: compress_hyper_2_180_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_180_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_180_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6180 (class 1259 OID 26460)
-- Name: compress_hyper_2_181_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_181_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_181_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6181 (class 1259 OID 26514)
-- Name: compress_hyper_2_182_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_182_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_182_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6182 (class 1259 OID 26568)
-- Name: compress_hyper_2_183_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_183_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_183_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6183 (class 1259 OID 26622)
-- Name: compress_hyper_2_184_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_184_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_184_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6184 (class 1259 OID 26676)
-- Name: compress_hyper_2_185_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_185_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_185_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6185 (class 1259 OID 26730)
-- Name: compress_hyper_2_186_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_186_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_186_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6186 (class 1259 OID 26784)
-- Name: compress_hyper_2_187_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_187_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_187_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6187 (class 1259 OID 26838)
-- Name: compress_hyper_2_188_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_188_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_188_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6188 (class 1259 OID 26892)
-- Name: compress_hyper_2_189_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_189_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_189_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6189 (class 1259 OID 26946)
-- Name: compress_hyper_2_190_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_190_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_190_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6190 (class 1259 OID 27000)
-- Name: compress_hyper_2_191_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_191_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_191_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6191 (class 1259 OID 27054)
-- Name: compress_hyper_2_192_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_192_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_192_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6192 (class 1259 OID 27108)
-- Name: compress_hyper_2_193_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_193_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_193_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6193 (class 1259 OID 27162)
-- Name: compress_hyper_2_194_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_194_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_194_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6194 (class 1259 OID 27216)
-- Name: compress_hyper_2_195_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_195_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_195_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6195 (class 1259 OID 27270)
-- Name: compress_hyper_2_196_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_196_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_196_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6196 (class 1259 OID 27324)
-- Name: compress_hyper_2_197_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_197_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_197_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6197 (class 1259 OID 27378)
-- Name: compress_hyper_2_198_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_198_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_198_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6198 (class 1259 OID 27432)
-- Name: compress_hyper_2_199_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_199_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_199_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6199 (class 1259 OID 27486)
-- Name: compress_hyper_2_200_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_200_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_200_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6200 (class 1259 OID 27540)
-- Name: compress_hyper_2_201_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_201_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_201_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6201 (class 1259 OID 27594)
-- Name: compress_hyper_2_202_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_202_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_202_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6202 (class 1259 OID 27648)
-- Name: compress_hyper_2_203_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_203_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_203_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6203 (class 1259 OID 27702)
-- Name: compress_hyper_2_204_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_204_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_204_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6204 (class 1259 OID 27756)
-- Name: compress_hyper_2_205_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_205_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_205_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6205 (class 1259 OID 27810)
-- Name: compress_hyper_2_206_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_206_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_206_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6206 (class 1259 OID 27864)
-- Name: compress_hyper_2_207_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_207_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_207_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6207 (class 1259 OID 27918)
-- Name: compress_hyper_2_208_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_208_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_208_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6208 (class 1259 OID 27972)
-- Name: compress_hyper_2_209_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_209_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_209_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6209 (class 1259 OID 28026)
-- Name: compress_hyper_2_210_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_210_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_210_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6210 (class 1259 OID 28080)
-- Name: compress_hyper_2_211_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_211_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_211_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6211 (class 1259 OID 28134)
-- Name: compress_hyper_2_212_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_212_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_212_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6212 (class 1259 OID 28188)
-- Name: compress_hyper_2_213_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_213_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_213_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6213 (class 1259 OID 28242)
-- Name: compress_hyper_2_214_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_214_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_214_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6214 (class 1259 OID 28296)
-- Name: compress_hyper_2_215_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_215_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_215_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6215 (class 1259 OID 28350)
-- Name: compress_hyper_2_216_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_216_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_216_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6216 (class 1259 OID 28404)
-- Name: compress_hyper_2_217_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_217_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_217_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6217 (class 1259 OID 28458)
-- Name: compress_hyper_2_218_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_218_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_218_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6218 (class 1259 OID 28512)
-- Name: compress_hyper_2_219_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_219_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_219_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6219 (class 1259 OID 28566)
-- Name: compress_hyper_2_220_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_220_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_220_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6220 (class 1259 OID 28620)
-- Name: compress_hyper_2_221_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_221_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_221_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6221 (class 1259 OID 28674)
-- Name: compress_hyper_2_222_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_222_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_222_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6222 (class 1259 OID 28728)
-- Name: compress_hyper_2_223_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_223_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_223_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6223 (class 1259 OID 28782)
-- Name: compress_hyper_2_224_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_224_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_224_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6224 (class 1259 OID 28836)
-- Name: compress_hyper_2_225_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_225_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_225_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6225 (class 1259 OID 28890)
-- Name: compress_hyper_2_226_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_226_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_226_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6226 (class 1259 OID 28944)
-- Name: compress_hyper_2_227_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_227_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_227_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6227 (class 1259 OID 28998)
-- Name: compress_hyper_2_228_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_228_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_228_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6228 (class 1259 OID 29052)
-- Name: compress_hyper_2_229_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_229_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_229_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6229 (class 1259 OID 29098)
-- Name: compress_hyper_2_230_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_230_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_230_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6230 (class 1259 OID 29152)
-- Name: compress_hyper_2_231_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_231_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_231_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6231 (class 1259 OID 29206)
-- Name: compress_hyper_2_232_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_232_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_232_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6232 (class 1259 OID 29260)
-- Name: compress_hyper_2_233_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_233_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_233_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6233 (class 1259 OID 29314)
-- Name: compress_hyper_2_234_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_234_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_234_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6234 (class 1259 OID 29368)
-- Name: compress_hyper_2_235_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_235_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_235_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6235 (class 1259 OID 29422)
-- Name: compress_hyper_2_236_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_236_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_236_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6236 (class 1259 OID 29476)
-- Name: compress_hyper_2_237_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_237_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_237_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6237 (class 1259 OID 29530)
-- Name: compress_hyper_2_238_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_238_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_238_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6238 (class 1259 OID 29584)
-- Name: compress_hyper_2_239_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_239_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_239_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6239 (class 1259 OID 29638)
-- Name: compress_hyper_2_240_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_240_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_240_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6240 (class 1259 OID 29692)
-- Name: compress_hyper_2_241_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_241_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_241_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6241 (class 1259 OID 29746)
-- Name: compress_hyper_2_242_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_242_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_242_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6242 (class 1259 OID 29800)
-- Name: compress_hyper_2_243_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_243_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_243_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6243 (class 1259 OID 29854)
-- Name: compress_hyper_2_244_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_244_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_244_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6244 (class 1259 OID 29868)
-- Name: compress_hyper_2_245_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_245_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_245_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6245 (class 1259 OID 29922)
-- Name: compress_hyper_2_246_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_246_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_246_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6246 (class 1259 OID 29976)
-- Name: compress_hyper_2_247_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_247_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_247_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6247 (class 1259 OID 30030)
-- Name: compress_hyper_2_248_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_248_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_248_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6248 (class 1259 OID 30084)
-- Name: compress_hyper_2_249_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_249_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_249_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6249 (class 1259 OID 30138)
-- Name: compress_hyper_2_250_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_250_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_250_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6250 (class 1259 OID 30192)
-- Name: compress_hyper_2_251_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_251_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_251_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6251 (class 1259 OID 30246)
-- Name: compress_hyper_2_252_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_252_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_252_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6252 (class 1259 OID 30292)
-- Name: compress_hyper_2_253_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_253_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_253_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6253 (class 1259 OID 30346)
-- Name: compress_hyper_2_254_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_254_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_254_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6254 (class 1259 OID 30400)
-- Name: compress_hyper_2_255_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_255_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_255_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6255 (class 1259 OID 30454)
-- Name: compress_hyper_2_256_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_256_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_256_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6256 (class 1259 OID 30508)
-- Name: compress_hyper_2_257_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_257_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_257_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6303 (class 1259 OID 31935)
-- Name: compress_hyper_2_279_chunk_region__ts_meta_min_1__ts_meta_m_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_2_279_chunk_region__ts_meta_min_1__ts_meta_m_idx ON _timescaledb_internal.compress_hyper_2_279_chunk USING btree (region, _ts_meta_min_1 DESC, _ts_meta_max_1 DESC);


--
-- TOC entry 6293 (class 1259 OID 30693)
-- Name: compress_hyper_4_269_chunk__ts_meta_min_1__ts_meta_max_1__t_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_4_269_chunk__ts_meta_min_1__ts_meta_max_1__t_idx ON _timescaledb_internal.compress_hyper_4_269_chunk USING btree (_ts_meta_min_1, _ts_meta_max_1, _ts_meta_min_2, _ts_meta_max_2, _ts_meta_min_3, _ts_meta_max_3);


--
-- TOC entry 6294 (class 1259 OID 30726)
-- Name: compress_hyper_4_270_chunk__ts_meta_min_1__ts_meta_max_1__t_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_4_270_chunk__ts_meta_min_1__ts_meta_max_1__t_idx ON _timescaledb_internal.compress_hyper_4_270_chunk USING btree (_ts_meta_min_1, _ts_meta_max_1, _ts_meta_min_2, _ts_meta_max_2, _ts_meta_min_3, _ts_meta_max_3);


--
-- TOC entry 6295 (class 1259 OID 30773)
-- Name: compress_hyper_4_271_chunk__ts_meta_min_1__ts_meta_max_1__t_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_4_271_chunk__ts_meta_min_1__ts_meta_max_1__t_idx ON _timescaledb_internal.compress_hyper_4_271_chunk USING btree (_ts_meta_min_1, _ts_meta_max_1, _ts_meta_min_2, _ts_meta_max_2, _ts_meta_min_3, _ts_meta_max_3);


--
-- TOC entry 6296 (class 1259 OID 30820)
-- Name: compress_hyper_4_272_chunk__ts_meta_min_1__ts_meta_max_1__t_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_4_272_chunk__ts_meta_min_1__ts_meta_max_1__t_idx ON _timescaledb_internal.compress_hyper_4_272_chunk USING btree (_ts_meta_min_1, _ts_meta_max_1, _ts_meta_min_2, _ts_meta_max_2, _ts_meta_min_3, _ts_meta_max_3);


--
-- TOC entry 6297 (class 1259 OID 30867)
-- Name: compress_hyper_4_273_chunk__ts_meta_min_1__ts_meta_max_1__t_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_4_273_chunk__ts_meta_min_1__ts_meta_max_1__t_idx ON _timescaledb_internal.compress_hyper_4_273_chunk USING btree (_ts_meta_min_1, _ts_meta_max_1, _ts_meta_min_2, _ts_meta_max_2, _ts_meta_min_3, _ts_meta_max_3);


--
-- TOC entry 6298 (class 1259 OID 30914)
-- Name: compress_hyper_4_274_chunk__ts_meta_min_1__ts_meta_max_1__t_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_4_274_chunk__ts_meta_min_1__ts_meta_max_1__t_idx ON _timescaledb_internal.compress_hyper_4_274_chunk USING btree (_ts_meta_min_1, _ts_meta_max_1, _ts_meta_min_2, _ts_meta_max_2, _ts_meta_min_3, _ts_meta_max_3);


--
-- TOC entry 6299 (class 1259 OID 30996)
-- Name: compress_hyper_4_275_chunk__ts_meta_min_1__ts_meta_max_1__t_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_4_275_chunk__ts_meta_min_1__ts_meta_max_1__t_idx ON _timescaledb_internal.compress_hyper_4_275_chunk USING btree (_ts_meta_min_1, _ts_meta_max_1, _ts_meta_min_2, _ts_meta_max_2, _ts_meta_min_3, _ts_meta_max_3);


--
-- TOC entry 6300 (class 1259 OID 31141)
-- Name: compress_hyper_4_276_chunk__ts_meta_min_1__ts_meta_max_1__t_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_4_276_chunk__ts_meta_min_1__ts_meta_max_1__t_idx ON _timescaledb_internal.compress_hyper_4_276_chunk USING btree (_ts_meta_min_1, _ts_meta_max_1, _ts_meta_min_2, _ts_meta_max_2, _ts_meta_min_3, _ts_meta_max_3);


--
-- TOC entry 6301 (class 1259 OID 31286)
-- Name: compress_hyper_4_277_chunk__ts_meta_min_1__ts_meta_max_1__t_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_4_277_chunk__ts_meta_min_1__ts_meta_max_1__t_idx ON _timescaledb_internal.compress_hyper_4_277_chunk USING btree (_ts_meta_min_1, _ts_meta_max_1, _ts_meta_min_2, _ts_meta_max_2, _ts_meta_min_3, _ts_meta_max_3);


--
-- TOC entry 6302 (class 1259 OID 31431)
-- Name: compress_hyper_4_278_chunk__ts_meta_min_1__ts_meta_max_1__t_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: postgres
--

CREATE INDEX compress_hyper_4_278_chunk__ts_meta_min_1__ts_meta_max_1__t_idx ON _timescaledb_internal.compress_hyper_4_278_chunk USING btree (_ts_meta_min_1, _ts_meta_max_1, _ts_meta_min_2, _ts_meta_max_2, _ts_meta_min_3, _ts_meta_max_3);


--
-- TOC entry 6313 (class 1259 OID 32508)
-- Name: idx_embeddings_hnsw; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_embeddings_hnsw ON public.product_embeddings USING hnsw (embedding public.vector_cosine_ops) WITH (m='16', ef_construction='64');


--
-- TOC entry 6314 (class 1259 OID 32507)
-- Name: idx_embeddings_ivfflat; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_embeddings_ivfflat ON public.product_embeddings USING ivfflat (embedding public.vector_cosine_ops) WITH (lists='100');


--
-- TOC entry 5413 (class 1259 OID 20997)
-- Name: idx_order_customer; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_order_customer ON public.order_events USING btree (customer_id);


--
-- TOC entry 5414 (class 1259 OID 20942)
-- Name: idx_order_region; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_order_region ON public.order_events USING btree (region);


--
-- TOC entry 5415 (class 1259 OID 20888)
-- Name: idx_order_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_order_status ON public.order_events USING btree (status);


--
-- TOC entry 5416 (class 1259 OID 31692)
-- Name: idx_status_completed; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_status_completed ON public.order_events USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 5417 (class 1259 OID 20828)
-- Name: idx_status_region; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_status_region ON public.order_events USING btree (status, region);


--
-- TOC entry 5418 (class 1259 OID 31798)
-- Name: idx_status_time_region; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_status_time_region ON public.order_events USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6304 (class 1259 OID 32005)
-- Name: order_events_archive_customer_id_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_events_archive_customer_id_idx ON public.order_events_archive USING btree (customer_id);


--
-- TOC entry 6305 (class 1259 OID 32001)
-- Name: order_events_archive_event_time_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_events_archive_event_time_idx ON public.order_events_archive USING btree (event_time DESC);


--
-- TOC entry 6306 (class 1259 OID 32004)
-- Name: order_events_archive_region_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_events_archive_region_idx ON public.order_events_archive USING btree (region);


--
-- TOC entry 6307 (class 1259 OID 32007)
-- Name: order_events_archive_status_event_time_region_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_events_archive_status_event_time_region_idx ON public.order_events_archive USING btree (status, event_time, region) WHERE (status = 'completed'::text);


--
-- TOC entry 6308 (class 1259 OID 32003)
-- Name: order_events_archive_status_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_events_archive_status_idx ON public.order_events_archive USING btree (status);


--
-- TOC entry 6309 (class 1259 OID 32006)
-- Name: order_events_archive_status_idx1; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_events_archive_status_idx1 ON public.order_events_archive USING btree (status) WHERE (status = 'completed'::text);


--
-- TOC entry 6310 (class 1259 OID 32002)
-- Name: order_events_archive_status_region_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_events_archive_status_region_idx ON public.order_events_archive USING btree (status, region);


--
-- TOC entry 5419 (class 1259 OID 18999)
-- Name: order_events_event_time_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX order_events_event_time_idx ON public.order_events USING btree (event_time DESC);


--
-- TOC entry 6584 (class 2620 OID 32077)
-- Name: _hyper_1_106_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_106_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6585 (class 2620 OID 32078)
-- Name: _hyper_1_107_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_107_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6586 (class 2620 OID 32079)
-- Name: _hyper_1_108_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_108_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6587 (class 2620 OID 32080)
-- Name: _hyper_1_109_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_109_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6540 (class 2620 OID 32033)
-- Name: _hyper_1_10_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_10_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6588 (class 2620 OID 32081)
-- Name: _hyper_1_110_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_110_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6589 (class 2620 OID 32082)
-- Name: _hyper_1_111_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_111_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6590 (class 2620 OID 32083)
-- Name: _hyper_1_112_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_112_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6591 (class 2620 OID 32084)
-- Name: _hyper_1_113_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_113_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6592 (class 2620 OID 32085)
-- Name: _hyper_1_114_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_114_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6593 (class 2620 OID 32086)
-- Name: _hyper_1_115_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_115_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6594 (class 2620 OID 32087)
-- Name: _hyper_1_116_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_116_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6595 (class 2620 OID 32088)
-- Name: _hyper_1_117_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_117_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6596 (class 2620 OID 32089)
-- Name: _hyper_1_118_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_118_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6597 (class 2620 OID 32090)
-- Name: _hyper_1_119_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_119_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6541 (class 2620 OID 32034)
-- Name: _hyper_1_11_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_11_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6598 (class 2620 OID 32091)
-- Name: _hyper_1_120_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_120_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6599 (class 2620 OID 32092)
-- Name: _hyper_1_121_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_121_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6600 (class 2620 OID 32093)
-- Name: _hyper_1_122_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_122_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6601 (class 2620 OID 32094)
-- Name: _hyper_1_123_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_123_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6602 (class 2620 OID 32095)
-- Name: _hyper_1_124_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_124_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6603 (class 2620 OID 32096)
-- Name: _hyper_1_125_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_125_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6604 (class 2620 OID 32097)
-- Name: _hyper_1_126_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_126_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6605 (class 2620 OID 32098)
-- Name: _hyper_1_127_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_127_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6606 (class 2620 OID 32099)
-- Name: _hyper_1_128_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_128_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6607 (class 2620 OID 32100)
-- Name: _hyper_1_129_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_129_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6542 (class 2620 OID 32035)
-- Name: _hyper_1_12_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_12_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6608 (class 2620 OID 32101)
-- Name: _hyper_1_130_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_130_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6609 (class 2620 OID 32102)
-- Name: _hyper_1_131_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_131_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6610 (class 2620 OID 32103)
-- Name: _hyper_1_132_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_132_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6611 (class 2620 OID 32104)
-- Name: _hyper_1_133_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_133_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6612 (class 2620 OID 32105)
-- Name: _hyper_1_134_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_134_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6613 (class 2620 OID 32106)
-- Name: _hyper_1_135_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_135_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6614 (class 2620 OID 32107)
-- Name: _hyper_1_136_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_136_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6615 (class 2620 OID 32108)
-- Name: _hyper_1_137_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_137_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6616 (class 2620 OID 32109)
-- Name: _hyper_1_138_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_138_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6617 (class 2620 OID 32110)
-- Name: _hyper_1_139_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_139_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6543 (class 2620 OID 32036)
-- Name: _hyper_1_13_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_13_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6618 (class 2620 OID 32111)
-- Name: _hyper_1_140_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_140_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6619 (class 2620 OID 32112)
-- Name: _hyper_1_141_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_141_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6620 (class 2620 OID 32113)
-- Name: _hyper_1_142_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_142_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6621 (class 2620 OID 32114)
-- Name: _hyper_1_143_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_143_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6622 (class 2620 OID 32115)
-- Name: _hyper_1_144_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_144_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6623 (class 2620 OID 32116)
-- Name: _hyper_1_145_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_145_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6624 (class 2620 OID 32117)
-- Name: _hyper_1_146_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_146_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6625 (class 2620 OID 32118)
-- Name: _hyper_1_147_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_147_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6626 (class 2620 OID 32119)
-- Name: _hyper_1_148_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_148_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6627 (class 2620 OID 32120)
-- Name: _hyper_1_149_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_149_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6544 (class 2620 OID 32037)
-- Name: _hyper_1_14_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_14_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6628 (class 2620 OID 32121)
-- Name: _hyper_1_150_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_150_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6629 (class 2620 OID 32122)
-- Name: _hyper_1_151_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_151_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6630 (class 2620 OID 32123)
-- Name: _hyper_1_152_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_152_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6631 (class 2620 OID 32124)
-- Name: _hyper_1_153_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_153_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6632 (class 2620 OID 32125)
-- Name: _hyper_1_154_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_154_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6633 (class 2620 OID 32126)
-- Name: _hyper_1_155_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_155_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6634 (class 2620 OID 32127)
-- Name: _hyper_1_156_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_156_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6635 (class 2620 OID 32128)
-- Name: _hyper_1_157_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_157_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6545 (class 2620 OID 32038)
-- Name: _hyper_1_15_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_15_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6546 (class 2620 OID 32039)
-- Name: _hyper_1_16_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_16_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6547 (class 2620 OID 32040)
-- Name: _hyper_1_17_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_17_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6548 (class 2620 OID 32041)
-- Name: _hyper_1_18_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_18_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6549 (class 2620 OID 32042)
-- Name: _hyper_1_19_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_19_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6531 (class 2620 OID 32024)
-- Name: _hyper_1_1_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_1_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6550 (class 2620 OID 32043)
-- Name: _hyper_1_20_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_20_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6551 (class 2620 OID 32044)
-- Name: _hyper_1_21_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_21_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6552 (class 2620 OID 32045)
-- Name: _hyper_1_22_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_22_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6553 (class 2620 OID 32046)
-- Name: _hyper_1_23_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_23_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6554 (class 2620 OID 32047)
-- Name: _hyper_1_24_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_24_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6555 (class 2620 OID 32048)
-- Name: _hyper_1_25_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_25_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6556 (class 2620 OID 32049)
-- Name: _hyper_1_26_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_26_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6557 (class 2620 OID 32050)
-- Name: _hyper_1_27_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_27_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6558 (class 2620 OID 32051)
-- Name: _hyper_1_28_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_28_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6559 (class 2620 OID 32052)
-- Name: _hyper_1_29_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_29_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6532 (class 2620 OID 32025)
-- Name: _hyper_1_2_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_2_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6560 (class 2620 OID 32053)
-- Name: _hyper_1_30_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_30_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6561 (class 2620 OID 32054)
-- Name: _hyper_1_31_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_31_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6562 (class 2620 OID 32055)
-- Name: _hyper_1_32_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_32_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6563 (class 2620 OID 32056)
-- Name: _hyper_1_33_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_33_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6564 (class 2620 OID 32057)
-- Name: _hyper_1_34_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_34_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6565 (class 2620 OID 32058)
-- Name: _hyper_1_35_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_35_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6566 (class 2620 OID 32059)
-- Name: _hyper_1_36_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_36_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6567 (class 2620 OID 32060)
-- Name: _hyper_1_37_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_37_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6568 (class 2620 OID 32061)
-- Name: _hyper_1_38_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_38_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6569 (class 2620 OID 32062)
-- Name: _hyper_1_39_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_39_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6533 (class 2620 OID 32026)
-- Name: _hyper_1_3_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_3_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6570 (class 2620 OID 32063)
-- Name: _hyper_1_40_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_40_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6571 (class 2620 OID 32064)
-- Name: _hyper_1_41_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_41_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6572 (class 2620 OID 32065)
-- Name: _hyper_1_42_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_42_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6573 (class 2620 OID 32066)
-- Name: _hyper_1_43_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_43_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6574 (class 2620 OID 32067)
-- Name: _hyper_1_44_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_44_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6575 (class 2620 OID 32068)
-- Name: _hyper_1_45_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_45_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6576 (class 2620 OID 32069)
-- Name: _hyper_1_46_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_46_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6577 (class 2620 OID 32070)
-- Name: _hyper_1_47_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_47_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6578 (class 2620 OID 32071)
-- Name: _hyper_1_48_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_48_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6579 (class 2620 OID 32072)
-- Name: _hyper_1_49_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_49_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6534 (class 2620 OID 32027)
-- Name: _hyper_1_4_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_4_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6580 (class 2620 OID 32073)
-- Name: _hyper_1_50_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_50_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6581 (class 2620 OID 32074)
-- Name: _hyper_1_51_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_51_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6582 (class 2620 OID 32075)
-- Name: _hyper_1_52_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_52_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6583 (class 2620 OID 32076)
-- Name: _hyper_1_53_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_53_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6535 (class 2620 OID 32028)
-- Name: _hyper_1_5_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_5_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6536 (class 2620 OID 32029)
-- Name: _hyper_1_6_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_6_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6537 (class 2620 OID 32030)
-- Name: _hyper_1_7_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_7_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6538 (class 2620 OID 32031)
-- Name: _hyper_1_8_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_8_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6539 (class 2620 OID 32032)
-- Name: _hyper_1_9_chunk trg_audit_order_deletion; Type: TRIGGER; Schema: _timescaledb_internal; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON _timescaledb_internal._hyper_1_9_chunk FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6530 (class 2620 OID 32023)
-- Name: order_events trg_audit_order_deletion; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_audit_order_deletion BEFORE DELETE ON public.order_events FOR EACH ROW EXECUTE FUNCTION public.log_order_deletion();


--
-- TOC entry 6425 (class 2606 OID 23713)
-- Name: _hyper_1_106_chunk 106_211_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_106_chunk
    ADD CONSTRAINT "106_211_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6426 (class 2606 OID 23718)
-- Name: _hyper_1_106_chunk 106_212_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_106_chunk
    ADD CONSTRAINT "106_212_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6427 (class 2606 OID 23742)
-- Name: _hyper_1_107_chunk 107_213_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_107_chunk
    ADD CONSTRAINT "107_213_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6428 (class 2606 OID 23747)
-- Name: _hyper_1_107_chunk 107_214_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_107_chunk
    ADD CONSTRAINT "107_214_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6429 (class 2606 OID 23771)
-- Name: _hyper_1_108_chunk 108_215_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_108_chunk
    ADD CONSTRAINT "108_215_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6430 (class 2606 OID 23776)
-- Name: _hyper_1_108_chunk 108_216_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_108_chunk
    ADD CONSTRAINT "108_216_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6431 (class 2606 OID 23800)
-- Name: _hyper_1_109_chunk 109_217_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_109_chunk
    ADD CONSTRAINT "109_217_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6432 (class 2606 OID 23805)
-- Name: _hyper_1_109_chunk 109_218_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_109_chunk
    ADD CONSTRAINT "109_218_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6337 (class 2606 OID 19238)
-- Name: _hyper_1_10_chunk 10_19_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_10_chunk
    ADD CONSTRAINT "10_19_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6338 (class 2606 OID 19243)
-- Name: _hyper_1_10_chunk 10_20_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_10_chunk
    ADD CONSTRAINT "10_20_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6433 (class 2606 OID 23829)
-- Name: _hyper_1_110_chunk 110_219_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_110_chunk
    ADD CONSTRAINT "110_219_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6434 (class 2606 OID 23834)
-- Name: _hyper_1_110_chunk 110_220_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_110_chunk
    ADD CONSTRAINT "110_220_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6435 (class 2606 OID 23858)
-- Name: _hyper_1_111_chunk 111_221_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_111_chunk
    ADD CONSTRAINT "111_221_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6436 (class 2606 OID 23863)
-- Name: _hyper_1_111_chunk 111_222_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_111_chunk
    ADD CONSTRAINT "111_222_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6437 (class 2606 OID 23887)
-- Name: _hyper_1_112_chunk 112_223_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_112_chunk
    ADD CONSTRAINT "112_223_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6438 (class 2606 OID 23892)
-- Name: _hyper_1_112_chunk 112_224_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_112_chunk
    ADD CONSTRAINT "112_224_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6439 (class 2606 OID 23916)
-- Name: _hyper_1_113_chunk 113_225_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_113_chunk
    ADD CONSTRAINT "113_225_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6440 (class 2606 OID 23921)
-- Name: _hyper_1_113_chunk 113_226_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_113_chunk
    ADD CONSTRAINT "113_226_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6441 (class 2606 OID 23945)
-- Name: _hyper_1_114_chunk 114_227_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_114_chunk
    ADD CONSTRAINT "114_227_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6442 (class 2606 OID 23950)
-- Name: _hyper_1_114_chunk 114_228_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_114_chunk
    ADD CONSTRAINT "114_228_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6443 (class 2606 OID 23974)
-- Name: _hyper_1_115_chunk 115_229_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_115_chunk
    ADD CONSTRAINT "115_229_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6444 (class 2606 OID 23979)
-- Name: _hyper_1_115_chunk 115_230_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_115_chunk
    ADD CONSTRAINT "115_230_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6445 (class 2606 OID 24003)
-- Name: _hyper_1_116_chunk 116_231_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_116_chunk
    ADD CONSTRAINT "116_231_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6446 (class 2606 OID 24008)
-- Name: _hyper_1_116_chunk 116_232_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_116_chunk
    ADD CONSTRAINT "116_232_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6447 (class 2606 OID 24032)
-- Name: _hyper_1_117_chunk 117_233_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_117_chunk
    ADD CONSTRAINT "117_233_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6448 (class 2606 OID 24037)
-- Name: _hyper_1_117_chunk 117_234_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_117_chunk
    ADD CONSTRAINT "117_234_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6449 (class 2606 OID 24061)
-- Name: _hyper_1_118_chunk 118_235_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_118_chunk
    ADD CONSTRAINT "118_235_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6450 (class 2606 OID 24066)
-- Name: _hyper_1_118_chunk 118_236_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_118_chunk
    ADD CONSTRAINT "118_236_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6451 (class 2606 OID 24090)
-- Name: _hyper_1_119_chunk 119_237_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_119_chunk
    ADD CONSTRAINT "119_237_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6452 (class 2606 OID 24095)
-- Name: _hyper_1_119_chunk 119_238_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_119_chunk
    ADD CONSTRAINT "119_238_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6339 (class 2606 OID 19263)
-- Name: _hyper_1_11_chunk 11_21_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_11_chunk
    ADD CONSTRAINT "11_21_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6340 (class 2606 OID 19268)
-- Name: _hyper_1_11_chunk 11_22_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_11_chunk
    ADD CONSTRAINT "11_22_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6453 (class 2606 OID 24119)
-- Name: _hyper_1_120_chunk 120_239_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_120_chunk
    ADD CONSTRAINT "120_239_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6454 (class 2606 OID 24124)
-- Name: _hyper_1_120_chunk 120_240_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_120_chunk
    ADD CONSTRAINT "120_240_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6455 (class 2606 OID 24148)
-- Name: _hyper_1_121_chunk 121_241_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_121_chunk
    ADD CONSTRAINT "121_241_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6456 (class 2606 OID 24153)
-- Name: _hyper_1_121_chunk 121_242_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_121_chunk
    ADD CONSTRAINT "121_242_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6457 (class 2606 OID 24177)
-- Name: _hyper_1_122_chunk 122_243_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_122_chunk
    ADD CONSTRAINT "122_243_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6458 (class 2606 OID 24182)
-- Name: _hyper_1_122_chunk 122_244_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_122_chunk
    ADD CONSTRAINT "122_244_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6459 (class 2606 OID 24206)
-- Name: _hyper_1_123_chunk 123_245_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_123_chunk
    ADD CONSTRAINT "123_245_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6460 (class 2606 OID 24211)
-- Name: _hyper_1_123_chunk 123_246_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_123_chunk
    ADD CONSTRAINT "123_246_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6461 (class 2606 OID 24235)
-- Name: _hyper_1_124_chunk 124_247_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_124_chunk
    ADD CONSTRAINT "124_247_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6462 (class 2606 OID 24240)
-- Name: _hyper_1_124_chunk 124_248_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_124_chunk
    ADD CONSTRAINT "124_248_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6463 (class 2606 OID 24264)
-- Name: _hyper_1_125_chunk 125_249_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_125_chunk
    ADD CONSTRAINT "125_249_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6464 (class 2606 OID 24269)
-- Name: _hyper_1_125_chunk 125_250_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_125_chunk
    ADD CONSTRAINT "125_250_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6465 (class 2606 OID 24293)
-- Name: _hyper_1_126_chunk 126_251_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_126_chunk
    ADD CONSTRAINT "126_251_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6466 (class 2606 OID 24298)
-- Name: _hyper_1_126_chunk 126_252_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_126_chunk
    ADD CONSTRAINT "126_252_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6467 (class 2606 OID 24322)
-- Name: _hyper_1_127_chunk 127_253_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_127_chunk
    ADD CONSTRAINT "127_253_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6468 (class 2606 OID 24327)
-- Name: _hyper_1_127_chunk 127_254_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_127_chunk
    ADD CONSTRAINT "127_254_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6469 (class 2606 OID 24351)
-- Name: _hyper_1_128_chunk 128_255_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_128_chunk
    ADD CONSTRAINT "128_255_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6470 (class 2606 OID 24356)
-- Name: _hyper_1_128_chunk 128_256_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_128_chunk
    ADD CONSTRAINT "128_256_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6471 (class 2606 OID 24380)
-- Name: _hyper_1_129_chunk 129_257_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_129_chunk
    ADD CONSTRAINT "129_257_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6472 (class 2606 OID 24385)
-- Name: _hyper_1_129_chunk 129_258_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_129_chunk
    ADD CONSTRAINT "129_258_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6341 (class 2606 OID 19288)
-- Name: _hyper_1_12_chunk 12_23_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_12_chunk
    ADD CONSTRAINT "12_23_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6342 (class 2606 OID 19293)
-- Name: _hyper_1_12_chunk 12_24_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_12_chunk
    ADD CONSTRAINT "12_24_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6473 (class 2606 OID 24409)
-- Name: _hyper_1_130_chunk 130_259_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_130_chunk
    ADD CONSTRAINT "130_259_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6474 (class 2606 OID 24414)
-- Name: _hyper_1_130_chunk 130_260_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_130_chunk
    ADD CONSTRAINT "130_260_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6475 (class 2606 OID 24438)
-- Name: _hyper_1_131_chunk 131_261_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_131_chunk
    ADD CONSTRAINT "131_261_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6476 (class 2606 OID 24443)
-- Name: _hyper_1_131_chunk 131_262_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_131_chunk
    ADD CONSTRAINT "131_262_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6477 (class 2606 OID 24467)
-- Name: _hyper_1_132_chunk 132_263_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_132_chunk
    ADD CONSTRAINT "132_263_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6478 (class 2606 OID 24472)
-- Name: _hyper_1_132_chunk 132_264_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_132_chunk
    ADD CONSTRAINT "132_264_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6479 (class 2606 OID 24496)
-- Name: _hyper_1_133_chunk 133_265_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_133_chunk
    ADD CONSTRAINT "133_265_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6480 (class 2606 OID 24501)
-- Name: _hyper_1_133_chunk 133_266_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_133_chunk
    ADD CONSTRAINT "133_266_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6481 (class 2606 OID 24525)
-- Name: _hyper_1_134_chunk 134_267_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_134_chunk
    ADD CONSTRAINT "134_267_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6482 (class 2606 OID 24530)
-- Name: _hyper_1_134_chunk 134_268_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_134_chunk
    ADD CONSTRAINT "134_268_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6483 (class 2606 OID 24554)
-- Name: _hyper_1_135_chunk 135_269_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_135_chunk
    ADD CONSTRAINT "135_269_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6484 (class 2606 OID 24559)
-- Name: _hyper_1_135_chunk 135_270_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_135_chunk
    ADD CONSTRAINT "135_270_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6485 (class 2606 OID 24583)
-- Name: _hyper_1_136_chunk 136_271_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_136_chunk
    ADD CONSTRAINT "136_271_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6486 (class 2606 OID 24588)
-- Name: _hyper_1_136_chunk 136_272_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_136_chunk
    ADD CONSTRAINT "136_272_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6487 (class 2606 OID 24612)
-- Name: _hyper_1_137_chunk 137_273_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_137_chunk
    ADD CONSTRAINT "137_273_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6488 (class 2606 OID 24617)
-- Name: _hyper_1_137_chunk 137_274_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_137_chunk
    ADD CONSTRAINT "137_274_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6489 (class 2606 OID 24641)
-- Name: _hyper_1_138_chunk 138_275_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_138_chunk
    ADD CONSTRAINT "138_275_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6490 (class 2606 OID 24646)
-- Name: _hyper_1_138_chunk 138_276_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_138_chunk
    ADD CONSTRAINT "138_276_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6491 (class 2606 OID 24670)
-- Name: _hyper_1_139_chunk 139_277_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_139_chunk
    ADD CONSTRAINT "139_277_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6492 (class 2606 OID 24675)
-- Name: _hyper_1_139_chunk 139_278_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_139_chunk
    ADD CONSTRAINT "139_278_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6343 (class 2606 OID 19313)
-- Name: _hyper_1_13_chunk 13_25_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_13_chunk
    ADD CONSTRAINT "13_25_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6344 (class 2606 OID 19318)
-- Name: _hyper_1_13_chunk 13_26_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_13_chunk
    ADD CONSTRAINT "13_26_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6493 (class 2606 OID 24699)
-- Name: _hyper_1_140_chunk 140_279_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_140_chunk
    ADD CONSTRAINT "140_279_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6494 (class 2606 OID 24704)
-- Name: _hyper_1_140_chunk 140_280_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_140_chunk
    ADD CONSTRAINT "140_280_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6495 (class 2606 OID 24728)
-- Name: _hyper_1_141_chunk 141_281_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_141_chunk
    ADD CONSTRAINT "141_281_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6496 (class 2606 OID 24733)
-- Name: _hyper_1_141_chunk 141_282_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_141_chunk
    ADD CONSTRAINT "141_282_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6497 (class 2606 OID 24757)
-- Name: _hyper_1_142_chunk 142_283_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_142_chunk
    ADD CONSTRAINT "142_283_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6498 (class 2606 OID 24762)
-- Name: _hyper_1_142_chunk 142_284_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_142_chunk
    ADD CONSTRAINT "142_284_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6499 (class 2606 OID 24786)
-- Name: _hyper_1_143_chunk 143_285_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_143_chunk
    ADD CONSTRAINT "143_285_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6500 (class 2606 OID 24791)
-- Name: _hyper_1_143_chunk 143_286_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_143_chunk
    ADD CONSTRAINT "143_286_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6501 (class 2606 OID 24815)
-- Name: _hyper_1_144_chunk 144_287_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_144_chunk
    ADD CONSTRAINT "144_287_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6502 (class 2606 OID 24820)
-- Name: _hyper_1_144_chunk 144_288_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_144_chunk
    ADD CONSTRAINT "144_288_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6503 (class 2606 OID 24844)
-- Name: _hyper_1_145_chunk 145_289_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_145_chunk
    ADD CONSTRAINT "145_289_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6504 (class 2606 OID 24849)
-- Name: _hyper_1_145_chunk 145_290_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_145_chunk
    ADD CONSTRAINT "145_290_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6505 (class 2606 OID 24873)
-- Name: _hyper_1_146_chunk 146_291_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_146_chunk
    ADD CONSTRAINT "146_291_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6506 (class 2606 OID 24878)
-- Name: _hyper_1_146_chunk 146_292_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_146_chunk
    ADD CONSTRAINT "146_292_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6507 (class 2606 OID 24902)
-- Name: _hyper_1_147_chunk 147_293_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_147_chunk
    ADD CONSTRAINT "147_293_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6508 (class 2606 OID 24907)
-- Name: _hyper_1_147_chunk 147_294_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_147_chunk
    ADD CONSTRAINT "147_294_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6509 (class 2606 OID 24931)
-- Name: _hyper_1_148_chunk 148_295_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_148_chunk
    ADD CONSTRAINT "148_295_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6510 (class 2606 OID 24936)
-- Name: _hyper_1_148_chunk 148_296_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_148_chunk
    ADD CONSTRAINT "148_296_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6511 (class 2606 OID 24960)
-- Name: _hyper_1_149_chunk 149_297_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_149_chunk
    ADD CONSTRAINT "149_297_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6512 (class 2606 OID 24965)
-- Name: _hyper_1_149_chunk 149_298_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_149_chunk
    ADD CONSTRAINT "149_298_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6345 (class 2606 OID 19338)
-- Name: _hyper_1_14_chunk 14_27_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_14_chunk
    ADD CONSTRAINT "14_27_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6346 (class 2606 OID 19343)
-- Name: _hyper_1_14_chunk 14_28_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_14_chunk
    ADD CONSTRAINT "14_28_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6513 (class 2606 OID 24989)
-- Name: _hyper_1_150_chunk 150_299_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_150_chunk
    ADD CONSTRAINT "150_299_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6514 (class 2606 OID 24994)
-- Name: _hyper_1_150_chunk 150_300_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_150_chunk
    ADD CONSTRAINT "150_300_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6515 (class 2606 OID 25018)
-- Name: _hyper_1_151_chunk 151_301_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_151_chunk
    ADD CONSTRAINT "151_301_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6516 (class 2606 OID 25023)
-- Name: _hyper_1_151_chunk 151_302_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_151_chunk
    ADD CONSTRAINT "151_302_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6517 (class 2606 OID 25047)
-- Name: _hyper_1_152_chunk 152_303_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_152_chunk
    ADD CONSTRAINT "152_303_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6518 (class 2606 OID 25052)
-- Name: _hyper_1_152_chunk 152_304_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_152_chunk
    ADD CONSTRAINT "152_304_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6519 (class 2606 OID 25076)
-- Name: _hyper_1_153_chunk 153_305_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_153_chunk
    ADD CONSTRAINT "153_305_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6520 (class 2606 OID 25081)
-- Name: _hyper_1_153_chunk 153_306_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_153_chunk
    ADD CONSTRAINT "153_306_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6521 (class 2606 OID 25105)
-- Name: _hyper_1_154_chunk 154_307_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_154_chunk
    ADD CONSTRAINT "154_307_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6522 (class 2606 OID 25110)
-- Name: _hyper_1_154_chunk 154_308_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_154_chunk
    ADD CONSTRAINT "154_308_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6523 (class 2606 OID 25134)
-- Name: _hyper_1_155_chunk 155_309_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_155_chunk
    ADD CONSTRAINT "155_309_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6524 (class 2606 OID 25139)
-- Name: _hyper_1_155_chunk 155_310_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_155_chunk
    ADD CONSTRAINT "155_310_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6525 (class 2606 OID 25163)
-- Name: _hyper_1_156_chunk 156_311_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_156_chunk
    ADD CONSTRAINT "156_311_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6526 (class 2606 OID 25168)
-- Name: _hyper_1_156_chunk 156_312_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_156_chunk
    ADD CONSTRAINT "156_312_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6527 (class 2606 OID 25192)
-- Name: _hyper_1_157_chunk 157_313_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_157_chunk
    ADD CONSTRAINT "157_313_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6528 (class 2606 OID 25197)
-- Name: _hyper_1_157_chunk 157_314_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_157_chunk
    ADD CONSTRAINT "157_314_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6347 (class 2606 OID 19363)
-- Name: _hyper_1_15_chunk 15_29_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_15_chunk
    ADD CONSTRAINT "15_29_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6348 (class 2606 OID 19368)
-- Name: _hyper_1_15_chunk 15_30_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_15_chunk
    ADD CONSTRAINT "15_30_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6349 (class 2606 OID 19388)
-- Name: _hyper_1_16_chunk 16_31_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_16_chunk
    ADD CONSTRAINT "16_31_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6350 (class 2606 OID 19393)
-- Name: _hyper_1_16_chunk 16_32_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_16_chunk
    ADD CONSTRAINT "16_32_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6351 (class 2606 OID 19413)
-- Name: _hyper_1_17_chunk 17_33_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_17_chunk
    ADD CONSTRAINT "17_33_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6352 (class 2606 OID 19418)
-- Name: _hyper_1_17_chunk 17_34_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_17_chunk
    ADD CONSTRAINT "17_34_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6353 (class 2606 OID 19438)
-- Name: _hyper_1_18_chunk 18_35_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_18_chunk
    ADD CONSTRAINT "18_35_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6354 (class 2606 OID 19443)
-- Name: _hyper_1_18_chunk 18_36_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_18_chunk
    ADD CONSTRAINT "18_36_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6355 (class 2606 OID 19463)
-- Name: _hyper_1_19_chunk 19_37_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_19_chunk
    ADD CONSTRAINT "19_37_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6356 (class 2606 OID 19468)
-- Name: _hyper_1_19_chunk 19_38_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_19_chunk
    ADD CONSTRAINT "19_38_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6319 (class 2606 OID 19013)
-- Name: _hyper_1_1_chunk 1_1_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_1_chunk
    ADD CONSTRAINT "1_1_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6320 (class 2606 OID 19018)
-- Name: _hyper_1_1_chunk 1_2_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_1_chunk
    ADD CONSTRAINT "1_2_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6357 (class 2606 OID 19488)
-- Name: _hyper_1_20_chunk 20_39_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_20_chunk
    ADD CONSTRAINT "20_39_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6358 (class 2606 OID 19493)
-- Name: _hyper_1_20_chunk 20_40_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_20_chunk
    ADD CONSTRAINT "20_40_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6359 (class 2606 OID 19513)
-- Name: _hyper_1_21_chunk 21_41_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_21_chunk
    ADD CONSTRAINT "21_41_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6360 (class 2606 OID 19518)
-- Name: _hyper_1_21_chunk 21_42_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_21_chunk
    ADD CONSTRAINT "21_42_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6361 (class 2606 OID 19538)
-- Name: _hyper_1_22_chunk 22_43_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_22_chunk
    ADD CONSTRAINT "22_43_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6362 (class 2606 OID 19543)
-- Name: _hyper_1_22_chunk 22_44_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_22_chunk
    ADD CONSTRAINT "22_44_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6363 (class 2606 OID 19563)
-- Name: _hyper_1_23_chunk 23_45_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_23_chunk
    ADD CONSTRAINT "23_45_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6364 (class 2606 OID 19568)
-- Name: _hyper_1_23_chunk 23_46_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_23_chunk
    ADD CONSTRAINT "23_46_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6365 (class 2606 OID 19588)
-- Name: _hyper_1_24_chunk 24_47_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_24_chunk
    ADD CONSTRAINT "24_47_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6366 (class 2606 OID 19593)
-- Name: _hyper_1_24_chunk 24_48_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_24_chunk
    ADD CONSTRAINT "24_48_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6367 (class 2606 OID 19613)
-- Name: _hyper_1_25_chunk 25_49_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_25_chunk
    ADD CONSTRAINT "25_49_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6368 (class 2606 OID 19618)
-- Name: _hyper_1_25_chunk 25_50_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_25_chunk
    ADD CONSTRAINT "25_50_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6369 (class 2606 OID 19638)
-- Name: _hyper_1_26_chunk 26_51_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_26_chunk
    ADD CONSTRAINT "26_51_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6370 (class 2606 OID 19643)
-- Name: _hyper_1_26_chunk 26_52_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_26_chunk
    ADD CONSTRAINT "26_52_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6371 (class 2606 OID 19663)
-- Name: _hyper_1_27_chunk 27_53_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_27_chunk
    ADD CONSTRAINT "27_53_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6372 (class 2606 OID 19668)
-- Name: _hyper_1_27_chunk 27_54_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_27_chunk
    ADD CONSTRAINT "27_54_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6373 (class 2606 OID 19688)
-- Name: _hyper_1_28_chunk 28_55_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_28_chunk
    ADD CONSTRAINT "28_55_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6374 (class 2606 OID 19693)
-- Name: _hyper_1_28_chunk 28_56_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_28_chunk
    ADD CONSTRAINT "28_56_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6375 (class 2606 OID 19713)
-- Name: _hyper_1_29_chunk 29_57_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_29_chunk
    ADD CONSTRAINT "29_57_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6376 (class 2606 OID 19718)
-- Name: _hyper_1_29_chunk 29_58_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_29_chunk
    ADD CONSTRAINT "29_58_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6321 (class 2606 OID 19038)
-- Name: _hyper_1_2_chunk 2_3_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_2_chunk
    ADD CONSTRAINT "2_3_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6322 (class 2606 OID 19043)
-- Name: _hyper_1_2_chunk 2_4_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_2_chunk
    ADD CONSTRAINT "2_4_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6377 (class 2606 OID 19738)
-- Name: _hyper_1_30_chunk 30_59_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_30_chunk
    ADD CONSTRAINT "30_59_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6378 (class 2606 OID 19743)
-- Name: _hyper_1_30_chunk 30_60_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_30_chunk
    ADD CONSTRAINT "30_60_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6379 (class 2606 OID 19763)
-- Name: _hyper_1_31_chunk 31_61_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_31_chunk
    ADD CONSTRAINT "31_61_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6380 (class 2606 OID 19768)
-- Name: _hyper_1_31_chunk 31_62_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_31_chunk
    ADD CONSTRAINT "31_62_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6381 (class 2606 OID 19788)
-- Name: _hyper_1_32_chunk 32_63_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_32_chunk
    ADD CONSTRAINT "32_63_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6382 (class 2606 OID 19793)
-- Name: _hyper_1_32_chunk 32_64_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_32_chunk
    ADD CONSTRAINT "32_64_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6383 (class 2606 OID 19813)
-- Name: _hyper_1_33_chunk 33_65_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_33_chunk
    ADD CONSTRAINT "33_65_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6384 (class 2606 OID 19818)
-- Name: _hyper_1_33_chunk 33_66_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_33_chunk
    ADD CONSTRAINT "33_66_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6385 (class 2606 OID 19838)
-- Name: _hyper_1_34_chunk 34_67_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_34_chunk
    ADD CONSTRAINT "34_67_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6386 (class 2606 OID 19843)
-- Name: _hyper_1_34_chunk 34_68_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_34_chunk
    ADD CONSTRAINT "34_68_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6387 (class 2606 OID 19863)
-- Name: _hyper_1_35_chunk 35_69_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_35_chunk
    ADD CONSTRAINT "35_69_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6388 (class 2606 OID 19868)
-- Name: _hyper_1_35_chunk 35_70_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_35_chunk
    ADD CONSTRAINT "35_70_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6389 (class 2606 OID 19888)
-- Name: _hyper_1_36_chunk 36_71_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_36_chunk
    ADD CONSTRAINT "36_71_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6390 (class 2606 OID 19893)
-- Name: _hyper_1_36_chunk 36_72_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_36_chunk
    ADD CONSTRAINT "36_72_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6391 (class 2606 OID 19913)
-- Name: _hyper_1_37_chunk 37_73_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_37_chunk
    ADD CONSTRAINT "37_73_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6392 (class 2606 OID 19918)
-- Name: _hyper_1_37_chunk 37_74_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_37_chunk
    ADD CONSTRAINT "37_74_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6393 (class 2606 OID 19938)
-- Name: _hyper_1_38_chunk 38_75_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_38_chunk
    ADD CONSTRAINT "38_75_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6394 (class 2606 OID 19943)
-- Name: _hyper_1_38_chunk 38_76_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_38_chunk
    ADD CONSTRAINT "38_76_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6395 (class 2606 OID 19963)
-- Name: _hyper_1_39_chunk 39_77_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_39_chunk
    ADD CONSTRAINT "39_77_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6396 (class 2606 OID 19968)
-- Name: _hyper_1_39_chunk 39_78_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_39_chunk
    ADD CONSTRAINT "39_78_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6323 (class 2606 OID 19063)
-- Name: _hyper_1_3_chunk 3_5_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_3_chunk
    ADD CONSTRAINT "3_5_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6324 (class 2606 OID 19068)
-- Name: _hyper_1_3_chunk 3_6_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_3_chunk
    ADD CONSTRAINT "3_6_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6397 (class 2606 OID 19988)
-- Name: _hyper_1_40_chunk 40_79_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_40_chunk
    ADD CONSTRAINT "40_79_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6398 (class 2606 OID 19993)
-- Name: _hyper_1_40_chunk 40_80_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_40_chunk
    ADD CONSTRAINT "40_80_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6399 (class 2606 OID 20013)
-- Name: _hyper_1_41_chunk 41_81_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_41_chunk
    ADD CONSTRAINT "41_81_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6400 (class 2606 OID 20018)
-- Name: _hyper_1_41_chunk 41_82_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_41_chunk
    ADD CONSTRAINT "41_82_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6401 (class 2606 OID 20038)
-- Name: _hyper_1_42_chunk 42_83_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_42_chunk
    ADD CONSTRAINT "42_83_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6402 (class 2606 OID 20043)
-- Name: _hyper_1_42_chunk 42_84_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_42_chunk
    ADD CONSTRAINT "42_84_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6403 (class 2606 OID 20063)
-- Name: _hyper_1_43_chunk 43_85_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_43_chunk
    ADD CONSTRAINT "43_85_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6404 (class 2606 OID 20068)
-- Name: _hyper_1_43_chunk 43_86_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_43_chunk
    ADD CONSTRAINT "43_86_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6405 (class 2606 OID 20088)
-- Name: _hyper_1_44_chunk 44_87_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_44_chunk
    ADD CONSTRAINT "44_87_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6406 (class 2606 OID 20093)
-- Name: _hyper_1_44_chunk 44_88_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_44_chunk
    ADD CONSTRAINT "44_88_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6407 (class 2606 OID 20113)
-- Name: _hyper_1_45_chunk 45_89_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_45_chunk
    ADD CONSTRAINT "45_89_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6408 (class 2606 OID 20118)
-- Name: _hyper_1_45_chunk 45_90_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_45_chunk
    ADD CONSTRAINT "45_90_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6409 (class 2606 OID 20138)
-- Name: _hyper_1_46_chunk 46_91_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_46_chunk
    ADD CONSTRAINT "46_91_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6410 (class 2606 OID 20143)
-- Name: _hyper_1_46_chunk 46_92_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_46_chunk
    ADD CONSTRAINT "46_92_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6411 (class 2606 OID 20163)
-- Name: _hyper_1_47_chunk 47_93_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_47_chunk
    ADD CONSTRAINT "47_93_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6412 (class 2606 OID 20168)
-- Name: _hyper_1_47_chunk 47_94_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_47_chunk
    ADD CONSTRAINT "47_94_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6413 (class 2606 OID 20188)
-- Name: _hyper_1_48_chunk 48_95_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_48_chunk
    ADD CONSTRAINT "48_95_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6414 (class 2606 OID 20193)
-- Name: _hyper_1_48_chunk 48_96_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_48_chunk
    ADD CONSTRAINT "48_96_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6415 (class 2606 OID 20213)
-- Name: _hyper_1_49_chunk 49_97_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_49_chunk
    ADD CONSTRAINT "49_97_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6416 (class 2606 OID 20218)
-- Name: _hyper_1_49_chunk 49_98_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_49_chunk
    ADD CONSTRAINT "49_98_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6325 (class 2606 OID 19088)
-- Name: _hyper_1_4_chunk 4_7_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_4_chunk
    ADD CONSTRAINT "4_7_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6326 (class 2606 OID 19093)
-- Name: _hyper_1_4_chunk 4_8_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_4_chunk
    ADD CONSTRAINT "4_8_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6417 (class 2606 OID 20243)
-- Name: _hyper_1_50_chunk 50_100_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_50_chunk
    ADD CONSTRAINT "50_100_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6418 (class 2606 OID 20238)
-- Name: _hyper_1_50_chunk 50_99_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_50_chunk
    ADD CONSTRAINT "50_99_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6419 (class 2606 OID 20263)
-- Name: _hyper_1_51_chunk 51_101_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_51_chunk
    ADD CONSTRAINT "51_101_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6420 (class 2606 OID 20268)
-- Name: _hyper_1_51_chunk 51_102_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_51_chunk
    ADD CONSTRAINT "51_102_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6421 (class 2606 OID 20288)
-- Name: _hyper_1_52_chunk 52_103_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_52_chunk
    ADD CONSTRAINT "52_103_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6422 (class 2606 OID 20293)
-- Name: _hyper_1_52_chunk 52_104_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_52_chunk
    ADD CONSTRAINT "52_104_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6423 (class 2606 OID 20313)
-- Name: _hyper_1_53_chunk 53_105_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_53_chunk
    ADD CONSTRAINT "53_105_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6424 (class 2606 OID 20318)
-- Name: _hyper_1_53_chunk 53_106_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_53_chunk
    ADD CONSTRAINT "53_106_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6327 (class 2606 OID 19118)
-- Name: _hyper_1_5_chunk 5_10_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5_chunk
    ADD CONSTRAINT "5_10_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6328 (class 2606 OID 19113)
-- Name: _hyper_1_5_chunk 5_9_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5_chunk
    ADD CONSTRAINT "5_9_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6329 (class 2606 OID 19138)
-- Name: _hyper_1_6_chunk 6_11_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_6_chunk
    ADD CONSTRAINT "6_11_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6330 (class 2606 OID 19143)
-- Name: _hyper_1_6_chunk 6_12_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_6_chunk
    ADD CONSTRAINT "6_12_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6331 (class 2606 OID 19163)
-- Name: _hyper_1_7_chunk 7_13_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_7_chunk
    ADD CONSTRAINT "7_13_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6332 (class 2606 OID 19168)
-- Name: _hyper_1_7_chunk 7_14_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_7_chunk
    ADD CONSTRAINT "7_14_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6333 (class 2606 OID 19188)
-- Name: _hyper_1_8_chunk 8_15_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_8_chunk
    ADD CONSTRAINT "8_15_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6334 (class 2606 OID 19193)
-- Name: _hyper_1_8_chunk 8_16_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_8_chunk
    ADD CONSTRAINT "8_16_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6335 (class 2606 OID 19213)
-- Name: _hyper_1_9_chunk 9_17_order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_9_chunk
    ADD CONSTRAINT "9_17_order_events_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6336 (class 2606 OID 19218)
-- Name: _hyper_1_9_chunk 9_18_order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: postgres
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_9_chunk
    ADD CONSTRAINT "9_18_order_events_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6317 (class 2606 OID 18986)
-- Name: order_events order_events_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_events
    ADD CONSTRAINT order_events_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- TOC entry 6318 (class 2606 OID 18991)
-- Name: order_events order_events_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_events
    ADD CONSTRAINT order_events_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- TOC entry 6529 (class 2606 OID 32500)
-- Name: product_embeddings product_embeddings_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_embeddings
    ADD CONSTRAINT product_embeddings_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


-- Completed on 2026-05-03 12:52:25

--
-- PostgreSQL database dump complete
--

\unrestrict yCS8lF1NjtLULEsalWj4z3z9YAwWuNa5NymYq9lW6rAVdnNr7rTaoFsygJETITK


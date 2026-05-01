/*============================== Window Function Queries =====================================================*/

-- Query 1 — Revenue Ranking Per Region Using RANK()

SELECT
    region,
    DATE_TRUNC('month', event_time) AS month,
    ROUND(SUM(total_amount)::NUMERIC, 2) AS monthly_revenue,
    RANK() OVER (
        PARTITION BY region
        ORDER BY SUM(total_amount) DESC
    ) AS revenue_rank
FROM order_events
WHERE status = 'completed'
GROUP BY region, month
ORDER BY region, revenue_rank;

-- Planning Time: 395.360 ms
-- Execution Time: 157.794 ms
-- Total Time: 553.154 ms


-- **Adding an index on 'status'**

CREATE INDEX IF NOT EXISTS idx_status_completed
ON order_events(status)
WHERE status = 'completed';

--Performance now:
-- Planning Time: 37.321 ms
-- Execution Time: 47.540 ms

/*-----------------------------------------------------------------------------------------------------------------*/


-- Query 2 — Month-over-Month Revenue Change Using LAG()

WITH monthly_revenue AS (
    SELECT
        DATE_TRUNC('month', event_time) AS month,
        ROUND(SUM(total_amount)::NUMERIC, 2) AS revenue
    FROM order_events
    WHERE status = 'completed'
    GROUP BY month
)
SELECT
    month,
    revenue,
    LAG(revenue) OVER (ORDER BY month) AS previous_month_revenue,
    ROUND(
        (revenue - LAG(revenue) OVER (ORDER BY month)) /
        NULLIF(LAG(revenue) OVER (ORDER BY month), 0) * 100,
    2) AS pct_change
FROM monthly_revenue
ORDER BY month;

-- This shows month-over-month growth rate

-- Planning Time: 17.308 ms
-- Execution Time: 86.254 ms

/*------------------------------------------------------------------------------------------------------------------*/

-- Query 3 — Running Total Revenue Using SUM() OVER()

SELECT
    DATE_TRUNC('week', event_time) AS week,
    region,
    ROUND(SUM(total_amount)::NUMERIC, 2) AS weekly_revenue,
    ROUND(SUM(SUM(total_amount)) OVER (
        PARTITION BY region
        ORDER BY DATE_TRUNC('week', event_time)
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )::NUMERIC, 2) AS running_total
FROM order_events
WHERE status = 'completed'
GROUP BY week, region
ORDER BY region, week;

-- This is a running total — very common in dashboards.

-- Planning Time: 15.114 ms
-- Execution Time: 46.838 ms

/*-------------------------------------------------------------------------------------------------------------------*/

-- Query 4 — Customer Percentile Ranking Using NTILE()

WITH customer_totals AS (
    SELECT
        customer_id,
        COUNT(*) AS order_count,
        ROUND(SUM(total_amount)::NUMERIC, 2) AS lifetime_value
    FROM order_events
    WHERE status = 'completed'
    GROUP BY customer_id
)
SELECT
    customer_id,
    order_count,
    lifetime_value,
    NTILE(4) OVER (ORDER BY lifetime_value DESC) AS quartile,
    CASE NTILE(4) OVER (ORDER BY lifetime_value DESC)
        WHEN 1 THEN 'Top 25% — Platinum'
        WHEN 2 THEN 'Top 50% — Gold'
        WHEN 3 THEN 'Top 75% — Silver'
        ELSE 'Bottom 25% — Bronze'
    END AS customer_tier
FROM customer_totals
ORDER BY lifetime_value DESC;

-- Planning Time: 16.747 ms
-- Execution Time: 73.879 ms


-- **Query to show the number of customers belonging to each tier**

WITH customer_totals AS (
    SELECT
        customer_id,
        COUNT(*) AS order_count,
        ROUND(SUM(total_amount)::NUMERIC, 2) AS lifetime_value
    FROM order_events
    WHERE status = 'completed'
    GROUP BY customer_id
),
tiered AS (
    SELECT
        customer_id,
        order_count,
        lifetime_value,
        CASE NTILE(4) OVER (ORDER BY lifetime_value DESC)
            WHEN 1 THEN 'Top 25% — Platinum'
            WHEN 2 THEN 'Top 50% — Gold'
            WHEN 3 THEN 'Top 75% — Silver'
            ELSE 'Bottom 25% — Bronze'
        END AS customer_tier
    FROM customer_totals
)
SELECT
    customer_tier,
    COUNT(*) AS customer_count,
    ROUND(AVG(lifetime_value)::NUMERIC, 2) AS avg_lifetime_value,
    ROUND(MIN(lifetime_value)::NUMERIC, 2) AS min_lifetime_value,
    ROUND(MAX(lifetime_value)::NUMERIC, 2) AS max_lifetime_value
FROM tiered
GROUP BY customer_tier
ORDER BY MIN(lifetime_value) DESC;

/*
RESULT:
    customer_tier    | customer_count | avg_lifetime_value | min_lifetime_value | max_lifetime_value
---------------------+----------------+--------------------+--------------------+--------------------
 Top 25% - Platinum  |            125 |          481280.78 |          458375.25 |          586189.16
 Top 50% - Gold      |            125 |          444316.48 |          431575.85 |          458063.40
 Top 75% - Silver    |            125 |          415331.53 |          398454.74 |          431136.00
 Bottom 25% - Bronze |            125 |          373624.18 |          298890.25 |          398274.34
*/

/*---------------------------------------------------------------------------------------------------------------*/

-- Query 5 — Lead/Lag to Find Order Gaps Per Customer

SELECT
    customer_id,
    event_time,
    LAG(event_time) OVER (
        PARTITION BY customer_id
        ORDER BY event_time
    ) AS previous_order_time,
    ROUND(EXTRACT(EPOCH FROM (
        event_time - LAG(event_time) OVER (
            PARTITION BY customer_id ORDER BY event_time
        )
    )) / 86400, 1) AS days_since_last_order
FROM order_events
WHERE status = 'completed'
ORDER BY customer_id, event_time
LIMIT 50;

-- This shows the gap between a customer's consecutive orders — useful for churn analysis.

-- Planning Time: 12.444 ms
-- Execution Time: 51.073 ms

/*================================== CTE Queries ================================================================*/

-- Query 6 — Multi-Level CTE: Top Products by Region

WITH regional_sales AS (
    SELECT
        o.region,
        o.product_id,
        COUNT(*) AS order_count,
        ROUND(SUM(o.total_amount)::NUMERIC, 2) AS revenue
    FROM order_events o
    WHERE o.status = 'completed'
    GROUP BY o.region, o.product_id
),
ranked_products AS (
    SELECT
        region,
        product_id,
        order_count,
        revenue,
        RANK() OVER (PARTITION BY region ORDER BY revenue DESC) AS rnk
    FROM regional_sales
),
top_products AS (
    SELECT *
    FROM ranked_products
    WHERE rnk <= 3
)
SELECT
    tp.region,
    tp.rnk AS rank,
    p.name AS product_name,
    p.category,
    tp.order_count,
    tp.revenue
FROM top_products tp
JOIN products p ON p.product_id = tp.product_id
ORDER BY tp.region, tp.rnk;

-- Planning Time: 30.523 ms
-- Execution Time: 75.939 ms

/*-------------------------------------------------------------------------------------------------------------*/

-- Query 7 — CTE With Filtering: Flagging High-Value Orders

WITH order_stats AS (
    SELECT
        AVG(total_amount) AS avg_amount,
        STDDEV(total_amount) AS stddev_amount
    FROM order_events
    WHERE status = 'completed'
),
flagged_orders AS (
    SELECT
        o.event_time,
        o.customer_id,
        o.region,
        o.total_amount,
        ROUND(
            (o.total_amount - s.avg_amount) / NULLIF(s.stddev_amount, 0),
        2) AS z_score
    FROM order_events o
    CROSS JOIN order_stats s
    WHERE o.status = 'completed'
      AND o.total_amount > (s.avg_amount + 2 * s.stddev_amount)
)
SELECT *
FROM flagged_orders
ORDER BY z_score DESC
LIMIT 20;

-- This flags statistically anomalous orders using z-score

-- Planning Time: 30.764 ms
-- Execution Time: 95.062 ms

/*------------------------------------------------------------------------------------------------------------*/

-- Query 8 — Recursive CTE: Customer Order Sequence

WITH RECURSIVE order_sequence AS (
    SELECT
        customer_id,
        event_time,
        total_amount,
        1 AS order_number,
        total_amount::NUMERIC AS cumulative_spend
    FROM order_events
    WHERE status = 'completed'
      AND event_time = (
          SELECT MIN(event_time) FROM order_events oe2
          WHERE oe2.customer_id = order_events.customer_id
            AND oe2.status = 'completed'
      )
      AND customer_id <= 10

    UNION ALL

    SELECT
        o.customer_id,
        o.event_time,
        o.total_amount,
        os.order_number + 1,
        os.cumulative_spend + o.total_amount
    FROM order_events o
    JOIN order_sequence os ON o.customer_id = os.customer_id
    WHERE o.status = 'completed'
      AND o.event_time > os.event_time
      AND o.event_time = (
          SELECT MIN(oe3.event_time)
          FROM order_events oe3
          WHERE oe3.customer_id = o.customer_id
            AND oe3.status = 'completed'
            AND oe3.event_time > os.event_time
      )
)
SELECT
    customer_id,
    order_number,
    ROUND(total_amount::NUMERIC, 2) AS order_amount,
    ROUND(cumulative_spend::NUMERIC, 2) AS cumulative_spend,
    event_time
FROM order_sequence
ORDER BY customer_id, order_number
LIMIT 30;

-- A recursive CTE building each customer's order history sequentially

-- Planning Time: 101.037 ms
-- Execution Time: 62025.266 ms

-- <<<<<<<<<<**This query is taking excessively more time to execute.**>>>>>>>>>>

-- **The above result can also be obtained by the below optimized Query:**


WITH completed_orders AS (
    SELECT
        customer_id,
        event_time,
        total_amount,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY event_time
        ) AS order_number,
        SUM(total_amount) OVER (
            PARTITION BY customer_id
            ORDER BY event_time
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_spend
    FROM order_events
    WHERE status = 'completed'
      AND customer_id <= 10
)
SELECT
    customer_id,
    order_number,
    ROUND(total_amount::NUMERIC, 2) AS order_amount,
    ROUND(cumulative_spend::NUMERIC, 2) AS cumulative_spend,
    event_time
FROM completed_orders
ORDER BY customer_id, order_number
LIMIT 30;

-- Planning Time: 17.944 ms
-- Execution Time: 16.209 ms

/*=======================================================XXXXX=======================================================*/
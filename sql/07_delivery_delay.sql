-- =====================================================================
-- 07_delivery_delay.sql — Delivery performance & its effect on reviews
--
-- Definitions (computed once in dw.fact_orders):
--   delivery_days = purchase -> delivered to customer (fractional days)
--   delay_days    = delivered DATE - promised DATE   (>0 late, <=0 on time)
--   is_late       = delay_days > 0
-- Only orders with status 'delivered' AND a delivered date are measured.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS analytics;

-- ---------------------------------------------------------------------
-- 7a. Headline KPIs
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_delivery_kpis AS
SELECT COUNT(*)                                                    AS delivered_orders,
       ROUND(100.0 * AVG(is_late::INT), 2)                         AS late_pct,
       ROUND(AVG(delivery_days), 1)                                AS avg_delivery_days,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delivery_days)  AS median_delivery_days,
       ROUND(AVG(estimated_days), 1)                               AS avg_promised_days,
       ROUND(AVG(delay_days) FILTER (WHERE is_late), 1)            AS avg_days_late_when_late,
       ROUND(AVG(review_score) FILTER (WHERE NOT is_late), 2)      AS avg_review_on_time,
       ROUND(AVG(review_score) FILTER (WHERE is_late), 2)          AS avg_review_late
FROM dw.fact_orders
WHERE is_delivered;

-- ---------------------------------------------------------------------
-- 7b. Delay bucket vs review score — does lateness hurt satisfaction?
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_delay_vs_review AS
SELECT CASE WHEN delay_days <= -10 THEN '1. 10+ days early'
            WHEN delay_days <= -1  THEN '2. 1-9 days early'
            WHEN delay_days =  0   THEN '3. On the promised day'
            WHEN delay_days <= 3   THEN '4. 1-3 days late'
            WHEN delay_days <= 7   THEN '5. 4-7 days late'
            ELSE                        '6. 8+ days late' END       AS delay_bucket,
       COUNT(*)                                                     AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)           AS pct_orders,
       ROUND(AVG(review_score), 2)                                  AS avg_review,
       ROUND(100.0 * AVG((review_score <= 2)::INT), 1)              AS pct_bad_reviews_1_2
FROM dw.fact_orders
WHERE is_delivered AND review_score IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------
-- 7c. By customer state — where is delivery worst? RANK() over states.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_delivery_by_state AS
SELECT c.state,
       COUNT(*)                                               AS delivered_orders,
       ROUND(AVG(f.delivery_days), 1)                         AS avg_delivery_days,
       ROUND(100.0 * AVG(f.is_late::INT), 2)                  AS late_pct,
       ROUND(AVG(f.review_score), 2)                          AS avg_review,
       RANK() OVER (ORDER BY AVG(f.is_late::INT) DESC)        AS late_rank,       -- 1 = worst
       RANK() OVER (ORDER BY AVG(f.delivery_days) DESC)       AS slowest_rank
FROM dw.fact_orders f
JOIN dw.dim_customer c USING (customer_key)
WHERE f.is_delivered
GROUP BY c.state
ORDER BY late_pct DESC;

-- ---------------------------------------------------------------------
-- 7d. Monthly trend of late deliveries, with MoM change in percentage
--     POINTS (late rate is already a %, so we subtract, not divide).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_delivery_monthly AS
WITH m AS (
    SELECT d.year_month,
           COUNT(*)                               AS delivered_orders,
           100.0 * AVG(f.is_late::INT)            AS late_pct,
           AVG(f.delivery_days)                   AS avg_delivery_days
    FROM dw.fact_orders f
    JOIN dw.dim_date d ON d.date_key = f.purchase_date_key
    WHERE f.is_delivered
      AND d.full_date BETWEEN '2017-01-01' AND '2018-08-31'
    GROUP BY d.year_month
)
SELECT year_month,
       delivered_orders,
       ROUND(late_pct, 2)                                          AS late_pct,
       ROUND(late_pct - LAG(late_pct) OVER (ORDER BY year_month), 2) AS late_pct_change_pts,
       ROUND(avg_delivery_days, 1)                                 AS avg_delivery_days
FROM m
ORDER BY year_month;

-- ---------------------------------------------------------------------
-- 7e. Who caused the delay? Split late orders by whether the SELLER
--     missed its hand-over deadline (shipping_limit) or the seller was on
--     time and the carrier/logistics leg ran late.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_delay_root_cause AS
WITH order_seller AS (
    SELECT order_id,
           MAX(shipping_limit_ts) AS shipping_limit_ts      -- latest deadline among the order's items
    FROM dw.fact_order_items
    GROUP BY order_id
)
SELECT CASE WHEN f.delivered_carrier_ts > os.shipping_limit_ts
            THEN 'Seller handed over late'
            ELSE 'Seller on time -> logistics late' END     AS cause,
       COUNT(*)                                             AS late_orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)   AS pct_of_late,
       ROUND(AVG(f.delay_days), 1)                          AS avg_days_late
FROM dw.fact_orders f
JOIN order_seller os USING (order_id)
WHERE f.is_late
GROUP BY 1;

-- ---------------------------------------------------------------------
-- 7f. Seller scorecard: sellers with >= 50 delivered orders, ranked.
--     PERCENT_RANK = relative position 0..1; NTILE(4) = quartile.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_seller_delivery AS
WITH seller_orders AS (                -- one row per (seller, order): avoid counting multi-item orders twice
    SELECT DISTINCT i.seller_key, i.order_id,
           (o.delivered_carrier_ts > i.shipping_limit_ts) AS handed_over_late,
           o.is_late, o.review_score
    FROM dw.fact_order_items i
    JOIN dw.fact_orders o USING (order_id)
    WHERE o.is_delivered
),
agg AS (
    SELECT seller_key,
           COUNT(*)                                     AS delivered_orders,
           100.0 * AVG(is_late::INT)                    AS late_pct,
           100.0 * AVG(handed_over_late::INT)           AS handover_late_pct,
           AVG(review_score)                            AS avg_review
    FROM seller_orders
    GROUP BY seller_key
    HAVING COUNT(*) >= 50
)
SELECT s.seller_id,
       s.state                                                AS seller_state,
       a.delivered_orders,
       ROUND(a.late_pct, 2)                                   AS late_pct,
       ROUND(a.handover_late_pct, 2)                          AS handover_late_pct,
       ROUND(a.avg_review, 2)                                 AS avg_review,
       ROUND(PERCENT_RANK() OVER (ORDER BY a.late_pct)::NUMERIC, 3) AS late_pct_percentile,
       NTILE(4) OVER (ORDER BY a.late_pct)                    AS late_quartile       -- 4 = worst 25%
FROM agg a
JOIN dw.dim_seller s USING (seller_key)
ORDER BY a.late_pct DESC;

-- ---------------------------------------------------------------------
-- 7g. Same-state vs inter-state shipping
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_delivery_route AS
WITH order_route AS (
    SELECT DISTINCT ON (i.order_id)                    -- first item's seller defines the route
           i.order_id,
           CASE WHEN s.state = c.state THEN 'Same state' ELSE 'Inter-state' END AS route
    FROM dw.fact_order_items i
    JOIN dw.dim_seller   s USING (seller_key)
    JOIN dw.dim_customer c USING (customer_key)
    ORDER BY i.order_id, i.order_item_id
)
SELECT r.route,
       COUNT(*)                                   AS delivered_orders,
       ROUND(AVG(f.delivery_days), 1)             AS avg_delivery_days,
       ROUND(100.0 * AVG(f.is_late::INT), 2)      AS late_pct,
       ROUND(AVG(f.freight_value), 2)             AS avg_freight
FROM dw.fact_orders f
JOIN order_route r USING (order_id)
WHERE f.is_delivered
GROUP BY r.route;

-- ---------------------------------------------------------------------
-- Show results
-- ---------------------------------------------------------------------
SELECT * FROM analytics.v_delivery_kpis;
SELECT * FROM analytics.v_delay_vs_review;
SELECT * FROM analytics.v_delivery_by_state LIMIT 10;
SELECT * FROM analytics.v_delivery_monthly;
SELECT * FROM analytics.v_delay_root_cause;
SELECT * FROM analytics.v_seller_delivery LIMIT 10;
SELECT * FROM analytics.v_delivery_route;

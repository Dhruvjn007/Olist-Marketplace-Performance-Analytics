-- =====================================================================
-- 05_mom_growth.sql — Month-over-Month growth with window functions
--
-- Revenue definition (GMV): item price + freight, for orders that were not
-- 'canceled' or 'unavailable'. Window: Jan-2017 .. Aug-2018 (the 20 full
-- months; see 03_data_quality_checks.sql #3).
--
-- Window functions used:
--   LAG(x, 1)              previous month's value  -> MoM %
--   LAG(x, 12)             same month last year    -> YoY %
--   AVG(...) ROWS 2 PRECEDING  3-month moving average (smooths spikes)
--   SUM(...) OVER (ORDER BY)   running / cumulative total
--   RANK() OVER (PARTITION BY) ranking inside each month
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS analytics;

-- ---------------------------------------------------------------------
-- 5a. Monthly KPIs + MoM / YoY growth
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_monthly_growth AS
WITH monthly AS (                                -- step 1: aggregate to month
    SELECT d.year_month,
           COUNT(DISTINCT f.order_id)                 AS orders,
           COUNT(DISTINCT f.customer_key)             AS active_customers,
           SUM(f.price + f.freight_value)             AS revenue
    FROM dw.fact_order_items f
    JOIN dw.dim_date d ON d.date_key = f.purchase_date_key
    WHERE f.order_status NOT IN ('canceled', 'unavailable')
      AND d.full_date BETWEEN '2017-01-01' AND '2018-08-31'
    GROUP BY d.year_month
)
SELECT year_month,                               -- step 2: compare rows with windows
       orders,
       active_customers,
       ROUND(revenue, 2)                                         AS revenue,
       ROUND(revenue / orders, 2)                                AS avg_order_value,
       ROUND(LAG(revenue) OVER w, 2)                             AS prev_month_revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER w)
                   / NULLIF(LAG(revenue) OVER w, 0), 2)          AS revenue_mom_pct,
       ROUND(100.0 * (orders - LAG(orders) OVER w)
                   / NULLIF(LAG(orders) OVER w, 0), 2)           AS orders_mom_pct,
       ROUND(100.0 * (revenue - LAG(revenue, 12) OVER w)
                   / NULLIF(LAG(revenue, 12) OVER w, 0), 2)      AS revenue_yoy_pct,
       ROUND(AVG(revenue) OVER (ORDER BY year_month
                                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS revenue_3m_avg,
       ROUND(SUM(revenue) OVER (ORDER BY year_month), 2)         AS cumulative_revenue
FROM monthly
WINDOW w AS (ORDER BY year_month)                -- named window, reused above
ORDER BY year_month;

-- ---------------------------------------------------------------------
-- 5b. Category MoM: top-5 categories per month and their own growth.
--     PARTITION BY category -> LAG looks back within the same category.
--     PARTITION BY month    -> RANK ranks categories inside each month.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_category_monthly AS
WITH cat_month AS (
    SELECT d.year_month,
           p.category,
           SUM(f.price + f.freight_value) AS revenue
    FROM dw.fact_order_items f
    JOIN dw.dim_date    d ON d.date_key    = f.purchase_date_key
    JOIN dw.dim_product p ON p.product_key = f.product_key
    WHERE f.order_status NOT IN ('canceled', 'unavailable')
      AND d.full_date BETWEEN '2017-01-01' AND '2018-08-31'
    GROUP BY d.year_month, p.category
),
ranked AS (
    SELECT year_month,
           category,
           ROUND(revenue, 2) AS revenue,
           ROUND(100.0 * (revenue - LAG(revenue) OVER (PARTITION BY category ORDER BY year_month))
                 / NULLIF(LAG(revenue) OVER (PARTITION BY category ORDER BY year_month), 0), 2) AS mom_pct,
           ROUND(100.0 * revenue / SUM(revenue) OVER (PARTITION BY year_month), 2)             AS share_of_month_pct,
           RANK() OVER (PARTITION BY year_month ORDER BY revenue DESC)                          AS rank_in_month
    FROM cat_month
)
SELECT * FROM ranked
WHERE rank_in_month <= 5                         -- can't filter on a window fn in WHERE of same level
ORDER BY year_month, rank_in_month;

-- ---------------------------------------------------------------------
-- Show results
-- ---------------------------------------------------------------------
SELECT * FROM analytics.v_monthly_growth;

SELECT * FROM analytics.v_category_monthly WHERE year_month IN ('2017-11', '2018-08');

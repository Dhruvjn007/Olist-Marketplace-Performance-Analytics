-- =====================================================================
-- 06_rfm_segmentation.sql — Recency / Frequency / Monetary segmentation
--
--   R = days since the customer's last order (smaller = better)
--   F = number of distinct orders
--   M = total amount paid
--
-- Customer = customer_unique_id (dim_customer), NOT customer_id —
-- otherwise every customer looks like a one-time buyer.
-- Only delivered orders count (a canceled order isn't a purchase).
-- "Today" = the day after the last purchase in the data, so recency is
-- measured from the dataset's end, not from the real current date.
--
-- Scoring (1 = worst, 5 = best):
--   R and M: NTILE(5) — splits customers into 5 equal-sized buckets.
--   F: fixed rules. ~97% of customers ordered once, so NTILE would put
--      identical one-order customers into different buckets at random.
--      Business rules (1 order=1, 2=3, 3=4, 4+=5) are honest about that skew.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS analytics;

CREATE OR REPLACE VIEW analytics.v_rfm_customers AS
WITH ref AS (
    SELECT MAX(purchase_ts)::DATE + 1 AS ref_date
    FROM dw.fact_orders
    WHERE is_delivered
),
base AS (                                             -- 1. raw R, F, M per person
    SELECT f.customer_key,
           (SELECT ref_date FROM ref) - MAX(f.purchase_ts)::DATE AS recency_days,
           COUNT(DISTINCT f.order_id)                           AS frequency,
           SUM(f.payment_value)                                 AS monetary
    FROM dw.fact_orders f
    WHERE f.is_delivered
    GROUP BY f.customer_key
),
scored AS (                                           -- 2. turn values into 1-5 scores
    SELECT b.*,
           NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,   -- most recent -> 5
           CASE WHEN frequency >= 4 THEN 5
                WHEN frequency = 3  THEN 4
                WHEN frequency = 2  THEN 3
                ELSE 1 END                            AS f_score,
           NTILE(5) OVER (ORDER BY monetary ASC)      AS m_score    -- biggest spend -> 5
    FROM base b
)
SELECT s.*,
       r_score::TEXT || f_score::TEXT || m_score::TEXT AS rfm_code,
       CASE                                           -- 3. scores -> named segments
           WHEN r_score >= 4 AND f_score >= 3                  THEN 'Champions'
           WHEN f_score >= 3                                   THEN 'Loyal (repeat buyers)'
           WHEN r_score >= 4 AND m_score >= 4                  THEN 'Promising high-value'
           WHEN r_score >= 4                                   THEN 'New customers'
           WHEN r_score <= 2 AND m_score >= 4                  THEN 'At risk high-value'
           WHEN r_score <= 2                                   THEN 'Hibernating'
           ELSE                                                     'Need attention'
       END AS segment
FROM scored s;

-- Segment summary — the table a manager actually reads.
-- SUM(...) OVER () = grand total across all rows (empty window), so each
-- row can show its share without a second query.
CREATE OR REPLACE VIEW analytics.v_rfm_segments AS
SELECT segment,
       COUNT(*)                                                     AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)           AS pct_customers,
       ROUND(AVG(recency_days), 0)                                  AS avg_recency_days,
       ROUND(AVG(frequency), 2)                                     AS avg_orders,
       ROUND(AVG(monetary), 2)                                      AS avg_spend,
       ROUND(SUM(monetary), 2)                                      AS total_revenue,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 2) AS pct_revenue
FROM analytics.v_rfm_customers
GROUP BY segment
ORDER BY total_revenue DESC;

-- ---------------------------------------------------------------------
-- Show results
-- ---------------------------------------------------------------------
SELECT * FROM analytics.v_rfm_segments;

-- How skewed is frequency? (justifies the rule-based F score)
SELECT frequency, COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM analytics.v_rfm_customers
GROUP BY frequency ORDER BY frequency;

-- Score boundaries actually produced by NTILE (good to quote in interviews)
SELECT 'recency_days' AS metric, r_score AS score, MIN(recency_days) AS min_val, MAX(recency_days) AS max_val
FROM analytics.v_rfm_customers GROUP BY r_score
UNION ALL
SELECT 'monetary', m_score, MIN(monetary), MAX(monetary)
FROM analytics.v_rfm_customers GROUP BY m_score
ORDER BY metric, score;

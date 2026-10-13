-- =====================================================================
-- 03_data_quality_checks.sql
-- Profiling queries run BEFORE building the warehouse. Every cleaning
-- rule in 04_star_schema.sql exists because of a finding here.
-- (Numbers in comments are what the public Olist dataset returns.)
-- =====================================================================

-- 1. customer_id is per ORDER, not per person.
--    99,441 orders -> 99,441 customer_ids, but only 96,096 real people.
--    => Use customer_unique_id for anything "per customer" (RFM!).
SELECT COUNT(*)                            AS orders,
       COUNT(DISTINCT o.customer_id)        AS customer_ids,
       COUNT(DISTINCT c.customer_unique_id) AS real_customers
FROM staging.orders o
JOIN staging.customers c USING (customer_id);

-- 2. Order status mix. 96,478 delivered; canceled (625) and unavailable
--    (609) never generated real revenue.
SELECT order_status, COUNT(*) AS orders
FROM staging.orders GROUP BY 1 ORDER BY 2 DESC;

-- 3. Date coverage & sparse edges. Sep-2016 to Oct-2018, but 2016 has
--    only ~330 orders (with a gap in Nov-2016) and Sep/Oct-2018 have
--    16 and 4 orders (the data export was cut mid-way).
--    => Trend analysis uses Jan-2017 .. Aug-2018 only (20 full months).
SELECT DATE_TRUNC('month', order_purchase_timestamp)::date AS month,
       COUNT(*) AS orders
FROM staging.orders GROUP BY 1 ORDER BY 1;

-- 4. Delivery timestamp inconsistencies.
--    8 orders are 'delivered' but have no delivered date; 6 non-delivered
--    orders have one. => Delivery metrics require status='delivered'
--    AND a non-null delivered date.
SELECT
  COUNT(*) FILTER (WHERE order_status = 'delivered'
                   AND order_delivered_customer_date IS NULL)  AS delivered_missing_date,
  COUNT(*) FILTER (WHERE order_status <> 'delivered'
                   AND order_delivered_customer_date IS NOT NULL) AS undelivered_with_date,
  COUNT(*) FILTER (WHERE order_delivered_carrier_date
                   < order_purchase_timestamp)                  AS carrier_before_purchase
FROM staging.orders;

-- 5. Reviews: 814 duplicate review_ids and 547 orders with >1 review.
--    => Keep only the LATEST review per order (ROW_NUMBER in 04).
SELECT COUNT(*) - COUNT(DISTINCT review_id) AS duplicate_review_ids,
       (SELECT COUNT(*) FROM (SELECT order_id FROM staging.order_reviews
                              GROUP BY 1 HAVING COUNT(*) > 1) x) AS orders_with_multiple_reviews
FROM staging.order_reviews;

-- 6. Orders with no items (775, almost all canceled/unavailable) and
--    1 order with no payment row. => LEFT JOINs + COALESCE in fact_orders.
SELECT
  (SELECT COUNT(*) FROM staging.orders o WHERE NOT EXISTS
     (SELECT 1 FROM staging.order_items i WHERE i.order_id = o.order_id))    AS orders_without_items,
  (SELECT COUNT(*) FROM staging.orders o WHERE NOT EXISTS
     (SELECT 1 FROM staging.order_payments p WHERE p.order_id = o.order_id)) AS orders_without_payment;

-- 7. Product categories: 610 products have NULL category; 2 categories
--    have no English translation. => COALESCE to a manual mapping / 'unknown'.
SELECT DISTINCT p.product_category_name
FROM staging.products p
LEFT JOIN staging.category_translation t USING (product_category_name)
WHERE t.product_category_name IS NULL;

-- 8. Zip codes: customer/seller zips came through as 4 digits when the
--    source dropped a leading zero ("1037" vs geolocation's "01037").
--    => LPAD(zip, 5, '0') before joining to geolocation.
SELECT MIN(LENGTH(customer_zip_code_prefix)) AS min_len,
       MAX(LENGTH(customer_zip_code_prefix)) AS max_len
FROM staging.customers;

-- 9. Geolocation: 1,000,163 rows for only 19,015 zip prefixes (many
--    duplicate points per zip). => Collapse to one averaged lat/lng per zip.
SELECT COUNT(*) AS rows, COUNT(DISTINCT geolocation_zip_code_prefix) AS zips
FROM staging.geolocation;

-- 10. Uniqueness of natural keys we will use as dimension keys.
SELECT 'orders.order_id'     AS key_col, COUNT(*) - COUNT(DISTINCT order_id)    AS duplicates FROM staging.orders   UNION ALL
SELECT 'products.product_id',            COUNT(*) - COUNT(DISTINCT product_id)  FROM staging.products UNION ALL
SELECT 'sellers.seller_id',              COUNT(*) - COUNT(DISTINCT seller_id)   FROM staging.sellers  UNION ALL
SELECT 'order_items (order_id,item_id)', COUNT(*) - COUNT(DISTINCT (order_id, order_item_id)) FROM staging.order_items;

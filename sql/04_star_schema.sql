-- =====================================================================
-- 04_star_schema.sql
-- Builds the analytics warehouse (schema "dw") from staging.
--
--                         dim_date
--                            |
--   dim_customer --- fact_orders            (grain: 1 row per ORDER)
--        |                   |  (order_id)
--        +-------- fact_order_items --- dim_product   (grain: 1 row per ITEM)
--                            |
--                        dim_seller
--
-- Facts hold numbers you add up (price, freight, delay days).
-- Dimensions hold the words you group/filter by (state, category, month).
-- Two fact tables because "per order" questions (delivery, reviews,
-- payments) and "per item" questions (category, seller revenue) live at
-- different grains — mixing them double-counts.
-- =====================================================================

DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;

-- ---------------------------------------------------------------------
-- Helper: one lat/lng per zip prefix (1M geolocation rows -> ~19K).
-- ---------------------------------------------------------------------
CREATE TEMP TABLE zip_geo AS
SELECT geolocation_zip_code_prefix          AS zip_prefix,
       ROUND(AVG(geolocation_lat), 6)       AS lat,
       ROUND(AVG(geolocation_lng), 6)       AS lng
FROM staging.geolocation
GROUP BY geolocation_zip_code_prefix;

-- =====================================================================
-- DIMENSIONS
-- =====================================================================

-- dim_date: calendar table, key = YYYYMMDD integer (fast joins, readable).
CREATE TABLE dw.dim_date (
    date_key     INT PRIMARY KEY,
    full_date    DATE NOT NULL UNIQUE,
    year         INT,
    quarter      INT,
    month        INT,
    month_name   TEXT,
    year_month   TEXT,          -- '2018-03' — handy for grouping/charts
    day_of_week  INT,           -- 1 = Monday ... 7 = Sunday (ISO)
    day_name     TEXT,
    is_weekend   BOOLEAN
);

INSERT INTO dw.dim_date
SELECT TO_CHAR(d, 'YYYYMMDD')::INT,
       d::DATE,
       EXTRACT(YEAR    FROM d)::INT,
       EXTRACT(QUARTER FROM d)::INT,
       EXTRACT(MONTH   FROM d)::INT,
       TO_CHAR(d, 'Mon'),
       TO_CHAR(d, 'YYYY-MM'),
       EXTRACT(ISODOW  FROM d)::INT,
       TO_CHAR(d, 'Dy'),
       EXTRACT(ISODOW  FROM d) IN (6, 7)
FROM GENERATE_SERIES('2016-01-01'::DATE, '2018-12-31'::DATE, INTERVAL '1 day') AS d;

-- dim_customer: grain = one REAL person (customer_unique_id).
-- A person who moved has several addresses; keep the one from their most
-- recent order (ROW_NUMBER ... ORDER BY purchase DESC, keep rn = 1).
CREATE TABLE dw.dim_customer (
    customer_key       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- surrogate key
    customer_unique_id TEXT NOT NULL UNIQUE,                          -- natural key
    zip_prefix         TEXT,
    city               TEXT,
    state              CHAR(2),
    lat                NUMERIC,
    lng                NUMERIC
);

INSERT INTO dw.dim_customer (customer_unique_id, zip_prefix, city, state, lat, lng)
SELECT latest.customer_unique_id, latest.zip_prefix, latest.city, latest.state, g.lat, g.lng
FROM (
    SELECT c.customer_unique_id,
           LPAD(c.customer_zip_code_prefix, 5, '0') AS zip_prefix,   -- fix lost leading zero
           INITCAP(c.customer_city)                 AS city,
           UPPER(c.customer_state)                  AS state,
           ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id
                              ORDER BY o.order_purchase_timestamp DESC) AS rn
    FROM staging.customers c
    JOIN staging.orders o USING (customer_id)
) latest
LEFT JOIN zip_geo g ON g.zip_prefix = latest.zip_prefix
WHERE rn = 1;

-- Bridge from the per-order customer_id to our customer_key (used below).
CREATE TEMP TABLE customer_map AS
SELECT c.customer_id, d.customer_key
FROM staging.customers c
JOIN dw.dim_customer d USING (customer_unique_id);

-- dim_seller
CREATE TABLE dw.dim_seller (
    seller_key  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id   TEXT NOT NULL UNIQUE,
    zip_prefix  TEXT,
    city        TEXT,
    state       CHAR(2),
    lat         NUMERIC,
    lng         NUMERIC
);

INSERT INTO dw.dim_seller (seller_id, zip_prefix, city, state, lat, lng)
SELECT s.seller_id,
       LPAD(s.seller_zip_code_prefix, 5, '0'),
       INITCAP(s.seller_city),
       UPPER(s.seller_state),
       g.lat, g.lng
FROM staging.sellers s
LEFT JOIN zip_geo g ON g.zip_prefix = LPAD(s.seller_zip_code_prefix, 5, '0');

-- dim_product: translate categories; fill the 2 untranslated ones by hand
-- and label the 610 NULL-category products 'unknown' instead of dropping them.
CREATE TABLE dw.dim_product (
    product_key       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id        TEXT NOT NULL UNIQUE,
    category_pt       TEXT,
    category          TEXT NOT NULL,    -- English name used in reports
    photos_qty        INT,
    weight_g          INT,
    volume_cm3        INT
);

INSERT INTO dw.dim_product (product_id, category_pt, category, photos_qty, weight_g, volume_cm3)
SELECT p.product_id,
       p.product_category_name,
       COALESCE(t.product_category_name_english,
                CASE p.product_category_name
                     WHEN 'pc_gamer' THEN 'pc_gamer'
                     WHEN 'portateis_cozinha_e_preparadores_de_alimentos'
                          THEN 'portable_kitchen_food_preparers'
                END,
                'unknown'),
       p.product_photos_qty,
       p.product_weight_g,
       p.product_length_cm * p.product_height_cm * p.product_width_cm
FROM staging.products p
LEFT JOIN staging.category_translation t USING (product_category_name);

-- =====================================================================
-- FACTS
-- =====================================================================

-- fact_order_items: grain = one row per item in an order.
CREATE TABLE dw.fact_order_items (
    order_id          TEXT    NOT NULL,     -- degenerate dimension
    order_item_id     INT     NOT NULL,
    customer_key      INT     NOT NULL REFERENCES dw.dim_customer,
    product_key       INT     NOT NULL REFERENCES dw.dim_product,
    seller_key        INT     NOT NULL REFERENCES dw.dim_seller,
    purchase_date_key INT     NOT NULL REFERENCES dw.dim_date,
    order_status      TEXT    NOT NULL,
    shipping_limit_ts TIMESTAMP,            -- deadline for seller to hand to carrier
    price             NUMERIC(10,2) NOT NULL,
    freight_value     NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

INSERT INTO dw.fact_order_items
SELECT i.order_id,
       i.order_item_id,
       cm.customer_key,
       dp.product_key,
       ds.seller_key,
       TO_CHAR(o.order_purchase_timestamp, 'YYYYMMDD')::INT,
       o.order_status,
       i.shipping_limit_date,
       i.price,
       i.freight_value
FROM staging.order_items i
JOIN staging.orders   o  USING (order_id)
JOIN customer_map     cm ON cm.customer_id = o.customer_id
JOIN dw.dim_product   dp ON dp.product_id  = i.product_id
JOIN dw.dim_seller    ds ON ds.seller_id   = i.seller_id;

-- fact_orders: grain = one row per order. Items, payments and reviews are
-- pre-aggregated to order level in CTEs so the joins can't fan out.
CREATE TABLE dw.fact_orders (
    order_id                TEXT PRIMARY KEY,   -- degenerate dimension
    customer_key            INT  NOT NULL REFERENCES dw.dim_customer,
    purchase_date_key       INT  NOT NULL REFERENCES dw.dim_date,
    order_status            TEXT NOT NULL,
    purchase_ts             TIMESTAMP NOT NULL,
    approved_ts             TIMESTAMP,
    delivered_carrier_ts    TIMESTAMP,
    delivered_customer_ts   TIMESTAMP,
    estimated_delivery_ts   TIMESTAMP,
    -- money
    item_count              INT,
    items_value             NUMERIC(12,2),      -- sum of item prices
    freight_value           NUMERIC(12,2),
    payment_value           NUMERIC(12,2),      -- what the customer actually paid
    main_payment_type       TEXT,
    max_installments        INT,
    -- satisfaction
    review_score            INT,
    -- delivery metrics (NULL unless truly delivered)
    is_delivered            BOOLEAN NOT NULL,
    delivery_days           NUMERIC(6,2),       -- purchase -> customer, in days
    estimated_days          INT,                -- purchase -> promised date
    delay_days              INT,                -- delivered date - promised date (>0 = late)
    is_late                 BOOLEAN
);

INSERT INTO dw.fact_orders
WITH items AS (
    SELECT order_id,
           COUNT(*)           AS item_count,
           SUM(price)         AS items_value,
           SUM(freight_value) AS freight_value
    FROM staging.order_items
    GROUP BY order_id
),
payments AS (
    SELECT order_id,
           SUM(payment_value)        AS payment_value,
           MAX(payment_installments) AS max_installments,
           -- payment type that covered the biggest share of the order
           (ARRAY_AGG(payment_type ORDER BY payment_value DESC))[1] AS main_payment_type
    FROM staging.order_payments
    GROUP BY order_id
),
reviews AS (
    SELECT order_id, review_score
    FROM (
        SELECT order_id, review_score,
               ROW_NUMBER() OVER (PARTITION BY order_id
                                  ORDER BY review_answer_timestamp DESC NULLS LAST) AS rn
        FROM staging.order_reviews
    ) r
    WHERE rn = 1                           -- latest review wins (dedupe)
)
SELECT o.order_id,
       cm.customer_key,
       TO_CHAR(o.order_purchase_timestamp, 'YYYYMMDD')::INT,
       o.order_status,
       o.order_purchase_timestamp,
       o.order_approved_at,
       o.order_delivered_carrier_date,
       o.order_delivered_customer_date,
       o.order_estimated_delivery_date,
       COALESCE(i.item_count, 0),
       COALESCE(i.items_value, 0),
       COALESCE(i.freight_value, 0),
       COALESCE(p.payment_value, 0),
       p.main_payment_type,
       p.max_installments,
       r.review_score,
       d.ok,
       CASE WHEN d.ok THEN ROUND(EXTRACT(EPOCH FROM o.order_delivered_customer_date
                                         - o.order_purchase_timestamp) / 86400.0, 2) END,
       o.order_estimated_delivery_date::DATE - o.order_purchase_timestamp::DATE,
       CASE WHEN d.ok THEN o.order_delivered_customer_date::DATE
                           - o.order_estimated_delivery_date::DATE END,
       CASE WHEN d.ok THEN o.order_delivered_customer_date::DATE
                           > o.order_estimated_delivery_date::DATE END
FROM staging.orders o
JOIN customer_map cm ON cm.customer_id = o.customer_id
LEFT JOIN items    i USING (order_id)
LEFT JOIN payments p USING (order_id)
LEFT JOIN reviews  r USING (order_id)
CROSS JOIN LATERAL (
    SELECT (o.order_status = 'delivered'
            AND o.order_delivered_customer_date IS NOT NULL) AS ok
) d;

-- fact_order_items -> fact_orders relationship
ALTER TABLE dw.fact_order_items
  ADD CONSTRAINT fk_items_order FOREIGN KEY (order_id) REFERENCES dw.fact_orders (order_id);

-- =====================================================================
-- INDEXES on foreign keys / common filters (Postgres does NOT auto-index FKs)
-- =====================================================================
CREATE INDEX ON dw.fact_orders      (customer_key);
CREATE INDEX ON dw.fact_orders      (purchase_date_key);
CREATE INDEX ON dw.fact_orders      (order_status);
CREATE INDEX ON dw.fact_order_items (product_key);
CREATE INDEX ON dw.fact_order_items (seller_key);
CREATE INDEX ON dw.fact_order_items (customer_key);
CREATE INDEX ON dw.fact_order_items (purchase_date_key);

ANALYZE;   -- refresh planner statistics after the bulk load

-- =====================================================================
-- RECONCILIATION: warehouse must tie back to staging exactly.
-- =====================================================================
SELECT 'orders'      AS check, (SELECT COUNT(*) FROM staging.orders)      AS staging, (SELECT COUNT(*) FROM dw.fact_orders)      AS warehouse UNION ALL
SELECT 'order_items',          (SELECT COUNT(*) FROM staging.order_items),            (SELECT COUNT(*) FROM dw.fact_order_items)           UNION ALL
SELECT 'customers (unique)',   (SELECT COUNT(DISTINCT customer_unique_id) FROM staging.customers), (SELECT COUNT(*) FROM dw.dim_customer) UNION ALL
SELECT 'products',             (SELECT COUNT(*) FROM staging.products),               (SELECT COUNT(*) FROM dw.dim_product)                UNION ALL
SELECT 'sellers',              (SELECT COUNT(*) FROM staging.sellers),                (SELECT COUNT(*) FROM dw.dim_seller)                 UNION ALL
SELECT 'item revenue (R$)',    (SELECT SUM(price) FROM staging.order_items),          (SELECT SUM(price) FROM dw.fact_order_items);

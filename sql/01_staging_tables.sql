-- =====================================================================
-- 01_staging_tables.sql
-- Raw landing zone: one table per Olist CSV, columns kept exactly as the
-- source (including Olist's "lenght" typos). No cleaning happens here —
-- staging is a faithful copy so we can always trace a number back to the
-- source file.
--
-- Why everything that looks like an ID or zip code is TEXT:
--   * IDs are 32-char hex hashes, not numbers.
--   * Zip prefixes like "01037" would lose the leading zero as INTEGER.
-- =====================================================================

DROP SCHEMA IF EXISTS staging CASCADE;
CREATE SCHEMA staging;

-- 1. Customers: one row per customer_id. NOTE: customer_id is generated
--    PER ORDER; customer_unique_id is the real person. This is the single
--    most important quirk of the dataset.
CREATE TABLE staging.customers (
    customer_id              TEXT,
    customer_unique_id       TEXT,
    customer_zip_code_prefix TEXT,
    customer_city            TEXT,
    customer_state           TEXT
);

-- 2. Geolocation: ~1M rows, many duplicate rows per zip prefix.
CREATE TABLE staging.geolocation (
    geolocation_zip_code_prefix TEXT,
    geolocation_lat             NUMERIC,
    geolocation_lng             NUMERIC,
    geolocation_city            TEXT,
    geolocation_state           TEXT
);

-- 3. Order items: one row per item inside an order.
CREATE TABLE staging.order_items (
    order_id            TEXT,
    order_item_id       INT,          -- 1, 2, 3 ... position inside the order
    product_id          TEXT,
    seller_id           TEXT,
    shipping_limit_date TIMESTAMP,
    price               NUMERIC(10,2),
    freight_value       NUMERIC(10,2)
);

-- 4. Payments: an order can be paid in several parts (e.g. voucher + card).
CREATE TABLE staging.order_payments (
    order_id             TEXT,
    payment_sequential   INT,
    payment_type         TEXT,
    payment_installments INT,
    payment_value        NUMERIC(10,2)
);

-- 5. Reviews: customer satisfaction survey sent after delivery.
CREATE TABLE staging.order_reviews (
    review_id               TEXT,
    order_id                TEXT,
    review_score            INT,
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TIMESTAMP,
    review_answer_timestamp TIMESTAMP
);

-- 6. Orders: the header table, one row per order, with the 5 lifecycle
--    timestamps that drive the delivery analysis.
CREATE TABLE staging.orders (
    order_id                      TEXT,
    customer_id                   TEXT,
    order_status                  TEXT,
    order_purchase_timestamp      TIMESTAMP,
    order_approved_at             TIMESTAMP,
    order_delivered_carrier_date  TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP
);

-- 7. Products (category names are in Portuguese).
CREATE TABLE staging.products (
    product_id                 TEXT,
    product_category_name      TEXT,
    product_name_lenght        INT,
    product_description_lenght INT,
    product_photos_qty         INT,
    product_weight_g           INT,
    product_length_cm          INT,
    product_height_cm          INT,
    product_width_cm           INT
);

-- 8. Sellers.
CREATE TABLE staging.sellers (
    seller_id              TEXT,
    seller_zip_code_prefix TEXT,
    seller_city            TEXT,
    seller_state           TEXT
);

-- 9. Portuguese -> English category lookup.
CREATE TABLE staging.category_translation (
    product_category_name         TEXT,
    product_category_name_english TEXT
);

-- =====================================================================
-- 02_load_staging.sql
-- Bulk-load the 9 CSVs with psql's client-side \copy (works without
-- superuser rights, reads files from YOUR machine, not the server's).
-- Run from the project root:  psql -d olist -f sql/02_load_staging.sql
-- =====================================================================

\copy staging.customers            FROM 'data/olist_customers_dataset.csv'          WITH (FORMAT csv, HEADER true)
\copy staging.geolocation          FROM 'data/olist_geolocation_dataset.csv'        WITH (FORMAT csv, HEADER true)
\copy staging.order_items          FROM 'data/olist_order_items_dataset.csv'        WITH (FORMAT csv, HEADER true)
\copy staging.order_payments       FROM 'data/olist_order_payments_dataset.csv'     WITH (FORMAT csv, HEADER true)
\copy staging.order_reviews        FROM 'data/olist_order_reviews_dataset.csv'      WITH (FORMAT csv, HEADER true)
\copy staging.orders               FROM 'data/olist_orders_dataset.csv'             WITH (FORMAT csv, HEADER true)
\copy staging.products             FROM 'data/olist_products_dataset.csv'           WITH (FORMAT csv, HEADER true)
\copy staging.sellers              FROM 'data/olist_sellers_dataset.csv'            WITH (FORMAT csv, HEADER true)
\copy staging.category_translation FROM 'data/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true)

-- Row counts: should match `wc -l` minus the header line.
SELECT 'customers'   AS tbl, COUNT(*) FROM staging.customers      UNION ALL
SELECT 'geolocation',        COUNT(*) FROM staging.geolocation    UNION ALL
SELECT 'order_items',        COUNT(*) FROM staging.order_items    UNION ALL
SELECT 'order_payments',     COUNT(*) FROM staging.order_payments UNION ALL
SELECT 'order_reviews',      COUNT(*) FROM staging.order_reviews  UNION ALL
SELECT 'orders',             COUNT(*) FROM staging.orders         UNION ALL
SELECT 'products',           COUNT(*) FROM staging.products       UNION ALL
SELECT 'sellers',            COUNT(*) FROM staging.sellers        UNION ALL
SELECT 'category_translation', COUNT(*) FROM staging.category_translation;

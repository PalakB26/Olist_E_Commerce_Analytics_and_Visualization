-- =============================================================================
-- 04_load_data.sql
-- Olist Brazilian E-Commerce — SQL Analytics Project
-- Step 4: bulk-load the 9 CSV files into the tables created in 02.
--
-- Run: psql -U postgres -d brazilian_e_commerce -f .\sql\04_load_data.sql
--
--
-- Options used:
--   FORMAT csv  -> handles quotes, commas inside quotes, and multi-line
--                  review comments correctly.
--   HEADER      -> skips the first line (also skips the BOM byte in the
--                  translation file's header, since the header is not parsed).
--   ENCODING    -> source files are UTF-8 (Portuguese accents).
--   Blank unquoted fields become NULL automatically in csv mode.
--
-- Load order matters: parent tables first, so foreign keys are satisfied.
-- =============================================================================

\echo '--- 1/9 customers'
\copy customers FROM 'data/olist_customers_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

\echo '--- 2/9 sellers'
\copy sellers FROM 'data/olist_sellers_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

\echo '--- 3/9 product_category_name_translation'
\copy product_category_name_translation FROM 'data/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

\echo '--- 4/9 products'
\copy products FROM 'data/olist_products_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

\echo '--- 5/9 geolocation  (~1M rows, this one takes a while)'
\copy geolocation FROM 'data/olist_geolocation_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

\echo '--- 6/9 orders'
\copy orders FROM 'data/olist_orders_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

\echo '--- 7/9 order_items'
\copy order_items FROM 'data/olist_order_items_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

\echo '--- 8/9 order_payments'
\copy order_payments FROM 'data/olist_order_payments_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

\echo '--- 9/9 order_reviews'
\copy order_reviews FROM 'data/olist_order_reviews_dataset.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

-- Refresh planner statistics after a bulk load (makes later queries faster).
ANALYZE;

-- -----------------------------------------------------------------------------
-- Verify: row counts must equal (CSV line count - 1 header line).
-- -----------------------------------------------------------------------------
\echo '--- row counts'
SELECT 'customers'                          AS tbl, COUNT(*) AS rows_loaded, 99441   AS expected FROM customers
UNION ALL SELECT 'sellers',                 COUNT(*), 3095    FROM sellers
UNION ALL SELECT 'category_translation',    COUNT(*), 71      FROM product_category_name_translation
UNION ALL SELECT 'products',                COUNT(*), 32951   FROM products
UNION ALL SELECT 'geolocation',             COUNT(*), 1000163 FROM geolocation
UNION ALL SELECT 'orders',                  COUNT(*), 99441   FROM orders
UNION ALL SELECT 'order_items',             COUNT(*), 112650  FROM order_items
UNION ALL SELECT 'order_payments',          COUNT(*), 103886  FROM order_payments
UNION ALL SELECT 'order_reviews',           COUNT(*), 99224   FROM order_reviews
ORDER BY tbl;

-- Spot-check that leading zeros survived (São Paulo zips start with 0).
\echo '--- leading-zero check (should return rows starting with 0)'
SELECT customer_zip_code_prefix, customer_city, customer_state
FROM customers
WHERE customer_zip_code_prefix LIKE '0%'
LIMIT 5;

-- =============================================================================
-- 03_profiling.sql
-- Olist Brazilian E-Commerce — SQL Analytics Project
-- Step 2 (verified in SQL): data profiling. Run AFTER 04_load_data.sql.
--
-- Run: psql -U postgres -d brazilian_e_commerce -f .\sql\03_profiling.sql
--
-- The core trick in every block: COUNT(*) vs COUNT(DISTINCT key).
--   equal     -> that column is a valid primary key
--   not equal -> need a composite key, or the table has no natural key
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Row counts for every table (should match the CSV line counts minus header)
-- -----------------------------------------------------------------------------
SELECT 'customers'      AS tbl, COUNT(*) AS n FROM customers
UNION ALL SELECT 'geolocation',    COUNT(*) FROM geolocation
UNION ALL SELECT 'orders',         COUNT(*) FROM orders
UNION ALL SELECT 'order_items',    COUNT(*) FROM order_items
UNION ALL SELECT 'order_payments', COUNT(*) FROM order_payments
UNION ALL SELECT 'order_reviews',  COUNT(*) FROM order_reviews
UNION ALL SELECT 'products',       COUNT(*) FROM products
UNION ALL SELECT 'sellers',        COUNT(*) FROM sellers
UNION ALL SELECT 'category_translation', COUNT(*) FROM product_category_name_translation
ORDER BY tbl;

-- -----------------------------------------------------------------------------
-- Q2: customer_id (one per ORDER) vs customer_unique_id (one per PERSON)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)                           AS total_rows,
       COUNT(DISTINCT customer_id)        AS unique_customer_id,
       COUNT(DISTINCT customer_unique_id) AS unique_persons,
       COUNT(*) - COUNT(DISTINCT customer_unique_id) AS repeat_order_rows
FROM customers;
-- expect 99441 / 99441 / 96096 / 3345  -> ~3.5% repeat customers

-- -----------------------------------------------------------------------------
-- Q3: order_items — is order_id unique? (no)  is (order_id, order_item_id)? (yes)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)                                  AS total_rows,
       COUNT(DISTINCT order_id)                  AS unique_orders,
       COUNT(DISTINCT (order_id, order_item_id)) AS unique_order_item_pairs
FROM order_items;
-- expect 112650 / 98666 / 112650  -> composite key confirmed

-- Q3b: orders that have no items at all — what status are they?
SELECT o.order_status, COUNT(*) AS orders_without_items
FROM orders o
LEFT JOIN order_items i ON i.order_id = o.order_id
WHERE i.order_id IS NULL
GROUP BY o.order_status
ORDER BY orders_without_items DESC;
-- expect 775 total, mostly 'unavailable' and 'canceled'

-- -----------------------------------------------------------------------------
-- Q4: order_payments — more than one payment per order?
-- -----------------------------------------------------------------------------
SELECT COUNT(*)                 AS total_rows,
       COUNT(DISTINCT order_id) AS unique_orders,
       MAX(payment_sequential)  AS max_payments_on_one_order
FROM order_payments;
-- expect 103886 / 99440 / 29  -> fan-out risk on join: aggregate BEFORE joining

SELECT payment_type,
       COUNT(*)                                               AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)     AS pct,
       ROUND(SUM(payment_value), 2)                           AS total_value
FROM order_payments
GROUP BY payment_type
ORDER BY n DESC;
-- note the 'not_defined' rows -> Step 5 cleanup

-- -----------------------------------------------------------------------------
-- Q5: order_reviews — which column is actually unique?  (none of them)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)                              AS total_rows,
       COUNT(DISTINCT review_id)             AS unique_review_id,
       COUNT(DISTINCT order_id)              AS unique_order_id,
       COUNT(DISTINCT (review_id, order_id)) AS unique_pairs
FROM order_reviews;
-- expect 99224 / 98410 / 98673 / 99224
-- Only the PAIR is unique: some review_ids cover several orders,
-- and some orders received several reviews.

-- -----------------------------------------------------------------------------
-- Q6: geolocation — zip_code_prefix is NOT unique
-- -----------------------------------------------------------------------------
SELECT COUNT(*)                                     AS total_rows,
       COUNT(DISTINCT geolocation_zip_code_prefix)  AS unique_zips,
       ROUND(COUNT(*)::numeric
             / COUNT(DISTINCT geolocation_zip_code_prefix), 1) AS avg_points_per_zip
FROM geolocation;
-- expect ~1000163 / ~19015 / ~52  -> a direct join would multiply rows ~52x.
-- Fix in Step 8: build geo_zip (one AVG lat/lng per zip) and join to that.

-- -----------------------------------------------------------------------------
-- Q7: products -> English category names via the translation table
-- -----------------------------------------------------------------------------
SELECT COUNT(*) FILTER (WHERE p.product_category_name IS NULL)         AS no_category,
       COUNT(*) FILTER (WHERE p.product_category_name IS NOT NULL
                          AND t.product_category_name IS NULL)         AS category_not_translated,
       COUNT(*)                                                        AS total_products
FROM products p
LEFT JOIN product_category_name_translation t
       ON t.product_category_name = p.product_category_name;
-- expect 610 / ~13 / 32951

-- Which categories are missing from the translation file?
SELECT DISTINCT p.product_category_name
FROM products p
LEFT JOIN product_category_name_translation t
       ON t.product_category_name = p.product_category_name
WHERE p.product_category_name IS NOT NULL
  AND t.product_category_name IS NULL;
-- expect: pc_gamer, portateis_cozinha_e_preparadores_de_alimentos

-- -----------------------------------------------------------------------------
-- Date range of the data (sets the scope for every time-series analysis)
-- -----------------------------------------------------------------------------
SELECT MIN(order_purchase_timestamp) AS first_order,
       MAX(order_purchase_timestamp) AS last_order,
       COUNT(*)                      AS orders
FROM orders;
-- expect 2016-09 to 2018-10; 2016 and late-2018 are thin -> handle in Step 6

SELECT order_status, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM orders
GROUP BY order_status
ORDER BY n DESC;
-- ~97% delivered. Revenue analysis should normally filter to delivered orders.

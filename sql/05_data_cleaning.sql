-- =============================================================================
-- 05_data_cleaning.sql
-- Olist Brazilian E-Commerce — SQL Analytics Project
-- Step 5: data quality checks + cleaning layer.
--
-- Run: sql -U postgres -d brazilian_e_commerce -f .\sql\05_data_cleaning.sql > .\sql\05_data_cleaning_output.txt
--
-- Principle: the raw tables loaded in 04 are NEVER updated or deleted.
-- Cleaning is done by ADDING things: a surrogate key, a lookup table,
-- two translation rows, and views that encode the analysis rules.
-- Every decision below is tied to a finding in 03_profiling_output.txt.
-- =============================================================================


-- =============================================================================
-- PART A — DATA QUALITY CHECKS (read-only; these go in the README)
-- =============================================================================

\echo '=== A1. Delivered orders missing a delivery date'
SELECT COUNT(*) AS delivered_but_no_delivery_date
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NULL;

\echo '=== A2. Orders missing approval timestamp, by status'
SELECT order_status, COUNT(*) AS missing_approved_at
FROM orders
WHERE order_approved_at IS NULL
GROUP BY order_status
ORDER BY missing_approved_at DESC;

\echo '=== A3. Timeline sanity: any event dated before the purchase?'
SELECT
  COUNT(*) FILTER (WHERE order_approved_at             < order_purchase_timestamp) AS approved_before_purchase,
  COUNT(*) FILTER (WHERE order_delivered_carrier_date  < order_purchase_timestamp) AS carrier_before_purchase,
  COUNT(*) FILTER (WHERE order_delivered_customer_date < order_purchase_timestamp) AS delivered_before_purchase,
  COUNT(*) FILTER (WHERE order_delivered_customer_date < order_delivered_carrier_date) AS delivered_before_carrier
FROM orders;

\echo '=== A4. Non-positive prices, freight, payments'
SELECT
  (SELECT COUNT(*) FROM order_items    WHERE price <= 0)          AS items_price_le_0,
  (SELECT COUNT(*) FROM order_items    WHERE freight_value < 0)   AS items_freight_lt_0,
  (SELECT COUNT(*) FROM order_payments WHERE payment_value <= 0)  AS payments_le_0;

\echo '=== A5. Does payment total match item total per order? (tolerance 1 cent)'
WITH items AS (
  SELECT order_id, SUM(price + freight_value) AS item_total
  FROM order_items GROUP BY order_id
), pays AS (
  SELECT order_id, SUM(payment_value) AS paid_total
  FROM order_payments GROUP BY order_id
)
SELECT
  COUNT(*)                                                   AS orders_with_both,
  COUNT(*) FILTER (WHERE ABS(item_total - paid_total) <= 0.01) AS matching,
  COUNT(*) FILTER (WHERE paid_total > item_total + 0.01)       AS paid_more,
  COUNT(*) FILTER (WHERE paid_total < item_total - 0.01)       AS paid_less
FROM items JOIN pays USING (order_id);
-- Expect most to match; small 'paid_more' = interest on installments,
-- 'paid_less' = vouchers not recorded. Neither is an error to fix.

\echo '=== A6. Orders per month at the edges of the date range'
SELECT DATE_TRUNC('month', order_purchase_timestamp)::date AS month,
       COUNT(*) AS orders
FROM orders
GROUP BY 1
HAVING COUNT(*) < 1000          -- show only the thin months
ORDER BY 1;
-- Sep–Dec 2016 and Sep–Oct 2018 have a handful of orders each.
-- Including them would make growth charts look absurd (e.g. +8000% MoM).

\echo '=== A7. Customer / seller zips with no geolocation match'
SELECT
  (SELECT COUNT(DISTINCT customer_zip_code_prefix) FROM customers c
    WHERE NOT EXISTS (SELECT 1 FROM geolocation g
                      WHERE g.geolocation_zip_code_prefix = c.customer_zip_code_prefix)) AS customer_zips_unmatched,
  (SELECT COUNT(DISTINCT seller_zip_code_prefix) FROM sellers s
    WHERE NOT EXISTS (SELECT 1 FROM geolocation g
                      WHERE g.geolocation_zip_code_prefix = s.seller_zip_code_prefix)) AS seller_zips_unmatched;

\echo '=== A8. Geolocation points outside Brazil (bad coordinates)'
SELECT COUNT(*) AS points_outside_brazil
FROM geolocation
WHERE geolocation_lat  NOT BETWEEN -33.75 AND  5.27   -- Brazil's lat range
   OR geolocation_lng  NOT BETWEEN -73.99 AND -34.79; -- Brazil's lng range

\echo '=== A9. Duplicate reviews: how many orders have >1 review?'
SELECT COUNT(*) AS orders_with_multiple_reviews,
       SUM(n - 1) AS extra_review_rows
FROM (SELECT order_id, COUNT(*) AS n FROM order_reviews GROUP BY order_id) t
WHERE n > 1;


-- =============================================================================
-- PART B — CLEANING ACTIONS (additive only)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- B1. Add the two category translations missing from the source file.
--     Finding: 03_profiling Q7 — 13 products had a category with no English name.
-- -----------------------------------------------------------------------------
\echo '=== B1. Insert missing category translations'
INSERT INTO product_category_name_translation (product_category_name, product_category_name_english)
VALUES
  ('pc_gamer',                                      'pc_gamer'),
  ('portateis_cozinha_e_preparadores_de_alimentos', 'portable_kitchen_and_food_preparers')
ON CONFLICT (product_category_name) DO NOTHING;   -- safe to re-run

-- -----------------------------------------------------------------------------
-- B2. Give order_reviews a surrogate primary key.
--     Finding: 03_profiling Q5 — no natural key exists.
-- -----------------------------------------------------------------------------
\echo '=== B2. Add surrogate key to order_reviews'
ALTER TABLE order_reviews DROP COLUMN IF EXISTS review_sk;
ALTER TABLE order_reviews ADD COLUMN review_sk BIGSERIAL PRIMARY KEY;

-- -----------------------------------------------------------------------------
-- B3. One review per order: keep the most recently ANSWERED review.
--     (If an order was reviewed twice, the later one reflects the final opinion.)
-- -----------------------------------------------------------------------------
\echo '=== B3. Create v_order_reviews_latest'
CREATE OR REPLACE VIEW v_order_reviews_latest AS
SELECT review_sk, review_id, order_id, review_score,
       review_comment_title, review_comment_message,
       review_creation_date, review_answer_timestamp
FROM (
  SELECT r.*,
         ROW_NUMBER() OVER (PARTITION BY order_id
                            ORDER BY review_answer_timestamp DESC NULLS LAST,
                                     review_creation_date   DESC NULLS LAST,
                                     review_sk              DESC) AS rn
  FROM order_reviews r
) t
WHERE rn = 1;

-- -----------------------------------------------------------------------------
-- B4. geo_zip: ONE row per zip prefix (average coordinates, inside Brazil only).
--     Finding: 03_profiling Q6 — 52.6 points per zip; direct join would fan out.
--     This is a TABLE (not a view) because it is used in many joins and the
--     1M-row aggregation should run once, not every query.
-- -----------------------------------------------------------------------------
\echo '=== B4. Build geo_zip lookup table'
DROP TABLE IF EXISTS geo_zip;
CREATE TABLE geo_zip AS
SELECT geolocation_zip_code_prefix                       AS zip_code_prefix,
       AVG(geolocation_lat)                              AS lat,
       AVG(geolocation_lng)                              AS lng,
       MODE() WITHIN GROUP (ORDER BY geolocation_city)   AS city,     -- most common spelling
       MODE() WITHIN GROUP (ORDER BY geolocation_state)  AS state,
       COUNT(*)                                          AS n_points
FROM geolocation
WHERE geolocation_lat BETWEEN -33.75 AND  5.27
  AND geolocation_lng BETWEEN -73.99 AND -34.79
GROUP BY geolocation_zip_code_prefix;

ALTER TABLE geo_zip ADD PRIMARY KEY (zip_code_prefix);

-- -----------------------------------------------------------------------------
-- B5. v_orders_clean: the single definition of "an order we analyse".
--     Rules (each tied to a finding above):
--       * status = 'delivered'            -> excludes the 775 item-less orders
--                                            (A: all unavailable/canceled/etc.)
--       * delivery date present           -> A1
--       * purchase between 2017-01-01 and 2018-08-31 -> A6 thin edge months
--     Every Step 6/7/8 query starts FROM v_orders_clean, so the rule
--     lives in exactly one place.
-- -----------------------------------------------------------------------------
\echo '=== B5. Create v_orders_clean'
CREATE OR REPLACE VIEW v_orders_clean AS
SELECT o.order_id,
       o.customer_id,
       c.customer_unique_id,
       c.customer_zip_code_prefix,
       c.customer_city,
       c.customer_state,
       o.order_status,
       o.order_purchase_timestamp,
       o.order_approved_at,
       o.order_delivered_carrier_date,
       o.order_delivered_customer_date,
       o.order_estimated_delivery_date,
       -- handy derived fields used everywhere downstream
       DATE_TRUNC('month', o.order_purchase_timestamp)::date          AS order_month,
       (o.order_delivered_customer_date::date
          - o.order_purchase_timestamp::date)                          AS delivery_days,
       (o.order_delivered_customer_date::date
          - o.order_estimated_delivery_date::date)                     AS days_vs_estimate,   -- >0 = late
       (o.order_delivered_customer_date > o.order_estimated_delivery_date) AS is_late
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_purchase_timestamp >= '2017-01-01'
  AND o.order_purchase_timestamp <  '2018-09-01';

-- -----------------------------------------------------------------------------
-- B6. v_order_payments_agg: ONE row per order (kills the fan-out at the source).
--     Finding: 03_profiling Q4.
-- -----------------------------------------------------------------------------
\echo '=== B6. Create v_order_payments_agg'
CREATE OR REPLACE VIEW v_order_payments_agg AS
SELECT order_id,
       SUM(payment_value)                       AS total_paid,
       COUNT(*)                                 AS n_payments,
       MAX(payment_installments)                AS max_installments,
       -- the payment type that carried the most value on this order
       (ARRAY_AGG(payment_type ORDER BY payment_value DESC))[1] AS main_payment_type,
       BOOL_OR(payment_type = 'voucher')        AS used_voucher
FROM order_payments
WHERE payment_type <> 'not_defined'              -- 3 rows, all 0.00
GROUP BY order_id;


-- =============================================================================
-- PART C — VERIFY THE CLEANING LAYER
-- =============================================================================

\echo '=== C1. Translation coverage is now complete'
SELECT COUNT(*) FILTER (WHERE p.product_category_name IS NOT NULL
                          AND t.product_category_name IS NULL) AS still_untranslated
FROM products p
LEFT JOIN product_category_name_translation t USING (product_category_name);
-- expect 0

\echo '=== C2. Reviews: one per order in the view'
SELECT (SELECT COUNT(*) FROM order_reviews)             AS raw_rows,
       (SELECT COUNT(*) FROM v_order_reviews_latest)    AS view_rows,
       (SELECT COUNT(DISTINCT order_id) FROM v_order_reviews_latest) AS distinct_orders;
-- expect view_rows = distinct_orders = 98673

\echo '=== C3. geo_zip: one row per zip, and coverage of customers'
SELECT (SELECT COUNT(*) FROM geo_zip)                                    AS zips_in_lookup,
       (SELECT COUNT(*) FROM customers c JOIN geo_zip g
          ON g.zip_code_prefix = c.customer_zip_code_prefix)             AS customers_with_coords,
       (SELECT COUNT(*) FROM customers)                                  AS customers_total;

\echo '=== C4. v_orders_clean size vs raw orders'
SELECT (SELECT COUNT(*) FROM orders)         AS raw_orders,
       (SELECT COUNT(*) FROM v_orders_clean) AS clean_orders,
       ROUND(100.0 * (SELECT COUNT(*) FROM v_orders_clean)
                   / (SELECT COUNT(*) FROM orders), 2) AS pct_kept;
-- expect ~96k kept (~96–97%)

\echo '=== C5. Payments view: exactly one row per order, no fan-out'
SELECT COUNT(*) AS rows, COUNT(DISTINCT order_id) AS orders
FROM v_order_payments_agg;
-- expect rows = orders

\echo '=== C6. Objects created by this script'
SELECT table_name, table_type
FROM information_schema.tables
WHERE table_schema = 'public'
  AND (table_name LIKE 'v\_%' OR table_name = 'geo_zip')
ORDER BY table_type, table_name;

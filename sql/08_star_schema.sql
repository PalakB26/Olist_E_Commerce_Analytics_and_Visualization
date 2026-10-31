-- =============================================================================
-- 08_star_schema.sql
-- Olist Brazilian E-Commerce — SQL Analytics Project
-- Step 8: star schema for BI (Power BI / Tableau connect to schema "dw").
--
-- Run:
--   psql -U postgres -d brazilian_e_commerce -f .\sql\08_star_schema.sql -o .\sql\08_star_schema_output.txt
--
-- Why a star schema?
--   The raw tables are normalised for the operational system. BI tools want
--   ONE wide fact table surrounded by small descriptive dimension tables:
--   fewer joins, faster slicers, and measures that cannot fan out.
--
-- Design
--   dw.dim_date        one row per calendar day, 2016-01-01 .. 2018-12-31
--   dw.dim_customer    one row per PERSON (customer_unique_id) + RFM segment
--   dw.dim_product     one row per product, with English category
--   dw.dim_seller      one row per seller, with coordinates
--   dw.fact_orders     grain = one ORDER (delivered, 2017-01..2018-08)
--   dw.fact_order_items grain = one ORDER LINE (for product/seller analysis)
--
--   Both facts are pre-aggregated per grain, so SUM(gmv) in Power BI is safe
--   no matter which dimensions are sliced. Payments are already one-per-order
--   via v_order_payments_agg; reviews via v_order_reviews_latest.
--
--   Materialised as TABLES (not views) so the dashboard is fast; re-run this
--   script to refresh.
-- =============================================================================

\pset footer off

CREATE SCHEMA IF NOT EXISTS dw;

DROP TABLE IF EXISTS dw.fact_order_items;
DROP TABLE IF EXISTS dw.fact_orders;
DROP TABLE IF EXISTS dw.dim_customer;
DROP TABLE IF EXISTS dw.dim_product;
DROP TABLE IF EXISTS dw.dim_seller;
DROP TABLE IF EXISTS dw.dim_date;


-- =============================================================================
-- dim_date
-- =============================================================================
\echo '=== dim_date'
CREATE TABLE dw.dim_date AS
SELECT d::date                                   AS date_key,
       EXTRACT(YEAR    FROM d)::int              AS year,
       EXTRACT(QUARTER FROM d)::int              AS quarter,
       'Q' || EXTRACT(QUARTER FROM d)::int       AS quarter_name,
       EXTRACT(MONTH   FROM d)::int              AS month,
       TO_CHAR(d, 'Mon')                         AS month_name,
       TO_CHAR(d, 'YYYY-MM')                     AS year_month,
       DATE_TRUNC('month', d)::date              AS month_start,
       EXTRACT(DAY     FROM d)::int              AS day,
       EXTRACT(ISODOW  FROM d)::int              AS weekday_num,     -- 1=Mon .. 7=Sun
       TO_CHAR(d, 'Dy')                          AS weekday_name,
       EXTRACT(ISODOW  FROM d) IN (6, 7)         AS is_weekend,
       EXTRACT(WEEK    FROM d)::int              AS iso_week,
       d::date = DATE '2017-11-24'               AS is_black_friday_2017
FROM GENERATE_SERIES(DATE '2017-01-01', DATE '2018-08-31', INTERVAL '1 day') d;

ALTER TABLE dw.dim_date ADD PRIMARY KEY (date_key);


-- =============================================================================
-- dim_customer  (one row per PERSON)
-- Location = the most recent order's address. RFM from 07.
-- =============================================================================
\echo '=== dim_customer'
CREATE TABLE dw.dim_customer AS
WITH latest_address AS (
  SELECT DISTINCT ON (customer_unique_id)
         customer_unique_id, customer_zip_code_prefix, customer_city, customer_state
  FROM v_orders_clean
  ORDER BY customer_unique_id, order_purchase_timestamp DESC
), stats AS (
  SELECT customer_unique_id,
         MIN(order_purchase_timestamp)::date AS first_order_date,
         MAX(order_purchase_timestamp)::date AS last_order_date,
         COUNT(*)                            AS n_orders
  FROM v_orders_clean
  GROUP BY customer_unique_id
)
SELECT a.customer_unique_id,
       a.customer_zip_code_prefix,
       a.customer_city,
       a.customer_state,
       g.lat,
       g.lng,
       s.first_order_date,
       s.last_order_date,
       s.n_orders,
       CASE WHEN s.n_orders > 1 THEN 'Repeat' ELSE 'One-time' END AS customer_type,
       r.recency_days,
       r.frequency,
       ROUND(r.monetary::numeric, 2)       AS monetary,
       r.r_score, r.f_score, r.m_score,
       r.segment                           AS rfm_segment
FROM latest_address a
JOIN stats s USING (customer_unique_id)
LEFT JOIN geo_zip g       ON g.zip_code_prefix = a.customer_zip_code_prefix
LEFT JOIN customer_rfm r  USING (customer_unique_id);

ALTER TABLE dw.dim_customer ADD PRIMARY KEY (customer_unique_id);
CREATE INDEX ON dw.dim_customer (customer_state);
CREATE INDEX ON dw.dim_customer (rfm_segment);


-- =============================================================================
-- dim_product
-- =============================================================================
\echo '=== dim_product'
CREATE TABLE dw.dim_product AS
SELECT p.product_id,
       p.product_category_name                                  AS category_pt,
       COALESCE(t.product_category_name_english, 'unknown')     AS category,
       p.product_name_length,
       p.product_description_length,
       p.product_photos_qty,
       p.product_weight_g,
       p.product_length_cm, p.product_height_cm, p.product_width_cm,
       p.product_length_cm * p.product_height_cm * p.product_width_cm AS volume_cm3,
       CASE
         WHEN p.product_weight_g IS NULL      THEN 'unknown'
         WHEN p.product_weight_g <  500       THEN '1. < 0.5 kg'
         WHEN p.product_weight_g <  2000      THEN '2. 0.5-2 kg'
         WHEN p.product_weight_g <  10000     THEN '3. 2-10 kg'
         ELSE                                      '4. 10+ kg'
       END                                                      AS weight_band
FROM products p
LEFT JOIN product_category_name_translation t USING (product_category_name);

ALTER TABLE dw.dim_product ADD PRIMARY KEY (product_id);
CREATE INDEX ON dw.dim_product (category);


-- =============================================================================
-- dim_seller
-- =============================================================================
\echo '=== dim_seller'
CREATE TABLE dw.dim_seller AS
SELECT s.seller_id,
       s.seller_zip_code_prefix,
       s.seller_city,
       s.seller_state,
       g.lat,
       g.lng
FROM sellers s
LEFT JOIN geo_zip g ON g.zip_code_prefix = s.seller_zip_code_prefix;

ALTER TABLE dw.dim_seller ADD PRIMARY KEY (seller_id);
CREATE INDEX ON dw.dim_seller (seller_state);


-- =============================================================================
-- fact_orders  (grain: one delivered order, 2017-01 .. 2018-08)
-- =============================================================================
\echo '=== fact_orders'
CREATE TABLE dw.fact_orders AS
WITH items AS (
  SELECT order_id,
         COUNT(*)                     AS n_items,
         COUNT(DISTINCT product_id)   AS n_distinct_products,
         COUNT(DISTINCT seller_id)    AS n_sellers,
         SUM(price)                   AS product_revenue,
         SUM(freight_value)           AS freight,
         SUM(price + freight_value)   AS gmv
  FROM order_items
  GROUP BY order_id
)
SELECT o.order_id,
       o.order_purchase_timestamp::date            AS purchase_date_key,
       o.order_delivered_customer_date::date       AS delivered_date_key,
       o.order_estimated_delivery_date::date       AS estimated_date_key,
       o.order_purchase_timestamp,
       EXTRACT(HOUR FROM o.order_purchase_timestamp)::int AS purchase_hour,
       o.customer_unique_id,
       o.customer_state,
       -- items
       i.n_items, i.n_distinct_products, i.n_sellers,
       i.product_revenue, i.freight, i.gmv,
       -- payments (one row per order, from the de-fanned view)
       p.total_paid,
       p.n_payments,
       p.max_installments,
       p.main_payment_type,
       p.used_voucher,
       -- review (latest per order)
       r.review_score,
       (r.review_comment_message IS NOT NULL)      AS has_review_comment,
       -- delivery
       o.delivery_days,
       o.days_vs_estimate,
       o.is_late,
       CASE
         WHEN o.days_vs_estimate <= -7 THEN '1. >1 week early'
         WHEN o.days_vs_estimate <   0 THEN '2. early'
         WHEN o.days_vs_estimate =   0 THEN '3. on the day'
         WHEN o.days_vs_estimate <=  7 THEN '4. up to 1 week late'
         ELSE                               '5. >1 week late'
       END                                          AS delivery_bucket,
       ROUND(EXTRACT(EPOCH FROM o.order_approved_at - o.order_purchase_timestamp) / 3600, 1)
                                                    AS hours_to_approval,
       (o.order_delivered_carrier_date::date - o.order_approved_at::date)         AS days_approval_to_carrier,
       (o.order_delivered_customer_date::date - o.order_delivered_carrier_date::date) AS days_carrier_to_customer
FROM v_orders_clean o
JOIN items i                    ON i.order_id = o.order_id
LEFT JOIN v_order_payments_agg p ON p.order_id = o.order_id
LEFT JOIN v_order_reviews_latest r ON r.order_id = o.order_id;

ALTER TABLE dw.fact_orders ADD PRIMARY KEY (order_id);
CREATE INDEX ON dw.fact_orders (purchase_date_key);
CREATE INDEX ON dw.fact_orders (customer_unique_id);
CREATE INDEX ON dw.fact_orders (customer_state);


-- =============================================================================
-- fact_order_items  (grain: one order line)
-- Order-level attributes are repeated on each line; DO NOT sum total_paid or
-- review_score here — use fact_orders for those. gmv/price/freight are safe.
-- =============================================================================
\echo '=== fact_order_items'
CREATE TABLE dw.fact_order_items AS
SELECT i.order_id,
       i.order_item_id,
       f.purchase_date_key,
       f.customer_unique_id,
       f.customer_state,
       i.product_id,
       i.seller_id,
       i.price,
       i.freight_value,
       i.price + i.freight_value                       AS gmv,
       ROUND(100.0 * i.freight_value / NULLIF(i.price, 0), 1) AS freight_pct_of_price,
       i.shipping_limit_date,
       f.is_late,
       f.delivery_days,
       f.review_score                                   -- order-level; AVG ok, SUM not
FROM order_items i
JOIN dw.fact_orders f ON f.order_id = i.order_id;

ALTER TABLE dw.fact_order_items ADD PRIMARY KEY (order_id, order_item_id);
CREATE INDEX ON dw.fact_order_items (product_id);
CREATE INDEX ON dw.fact_order_items (seller_id);
CREATE INDEX ON dw.fact_order_items (purchase_date_key);

ANALYZE;


-- =============================================================================
-- Reconciliation: the star schema must reproduce the Step-6 headline KPIs
-- =============================================================================
\echo '=== Reconciliation vs 06 Q12 (orders 96203, gmv 15371741.09, cash 15374496.52)'
SELECT COUNT(*)                                  AS orders,
       COUNT(DISTINCT customer_unique_id)        AS customers,
       ROUND(SUM(gmv), 2)                        AS gmv,
       ROUND(SUM(total_paid), 2)                 AS cash_collected,
       ROUND(AVG(gmv), 2)                        AS avg_order_value,
       ROUND(AVG(review_score), 2)               AS avg_review,
       ROUND(100.0 * AVG(is_late::int), 1)       AS pct_late
FROM dw.fact_orders;

\echo '=== Items fact sums to the same GMV'
SELECT COUNT(*) AS order_lines, ROUND(SUM(gmv), 2) AS gmv
FROM dw.fact_order_items;

\echo '=== Row counts of every dw object'
SELECT 'dim_date'         AS tbl, COUNT(*) FROM dw.dim_date
UNION ALL SELECT 'dim_customer',    COUNT(*) FROM dw.dim_customer
UNION ALL SELECT 'dim_product',     COUNT(*) FROM dw.dim_product
UNION ALL SELECT 'dim_seller',      COUNT(*) FROM dw.dim_seller
UNION ALL SELECT 'fact_orders',     COUNT(*) FROM dw.fact_orders
UNION ALL SELECT 'fact_order_items',COUNT(*) FROM dw.fact_order_items;

\echo '=== Referential check: every fact key has a dimension row'
SELECT
  (SELECT COUNT(*) FROM dw.fact_orders f
     WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer d WHERE d.customer_unique_id = f.customer_unique_id)) AS orders_missing_customer,
  (SELECT COUNT(*) FROM dw.fact_orders f
     WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date d WHERE d.date_key = f.purchase_date_key))               AS orders_missing_date,
  (SELECT COUNT(*) FROM dw.fact_order_items f
     WHERE NOT EXISTS (SELECT 1 FROM dw.dim_product d WHERE d.product_id = f.product_id))                 AS items_missing_product,
  (SELECT COUNT(*) FROM dw.fact_order_items f
     WHERE NOT EXISTS (SELECT 1 FROM dw.dim_seller d WHERE d.seller_id = f.seller_id))                    AS items_missing_seller;
-- expect all zeros

\echo '=== Sample: monthly GMV straight from the star (what Power BI will compute)'
SELECT d.year_month,
       COUNT(*)                 AS orders,
       ROUND(SUM(f.gmv), 2)     AS gmv,
       ROUND(AVG(f.review_score), 2) AS avg_review
FROM dw.fact_orders f
JOIN dw.dim_date d ON d.date_key = f.purchase_date_key
GROUP BY d.year_month
ORDER BY d.year_month;

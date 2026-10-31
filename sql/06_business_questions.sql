-- =============================================================================
-- 06_business_questions.sql
-- Olist Brazilian E-Commerce — SQL Analytics Project
-- Step 6: core business questions (the "interview layer").
--
-- Run: psql -U postgres -d brazilian_e_commerce -f .\sql\06_business_questions.sql > .\sql\06_business_questions_output.txt
--
-- Conventions
--   * Every query starts from v_orders_clean (delivered, 2017-01..2018-08).
--   * TWO revenue definitions — each query says which one it uses:
--       GMV   = SUM(price + freight_value) from order_items  (what was sold)
--       CASH  = total_paid from v_order_payments_agg         (what was collected,
--               includes installment interest, nets out vouchers)
--   * Never join order_items to order_payments directly (fan-out). Go through
--     v_order_payments_agg, which is one row per order.
--   * Customers are counted by customer_unique_id (the person), never customer_id.
-- =============================================================================

\pset footer off


-- =============================================================================
-- Q1. Monthly performance: orders, customers, GMV, AOV
--     Business question: how is the marketplace growing month to month?
--     Tables: v_orders_clean, order_items  (GMV)
-- =============================================================================
\qecho '=== Q1. Monthly orders, customers, GMV, AOV'
SELECT o.order_month,
       COUNT(DISTINCT o.order_id)             AS orders,
       COUNT(DISTINCT o.customer_unique_id)   AS customers,
       ROUND(SUM(i.price + i.freight_value), 2) AS gmv,
       ROUND(SUM(i.price + i.freight_value)
             / COUNT(DISTINCT o.order_id), 2) AS avg_order_value
FROM v_orders_clean o
JOIN order_items i ON i.order_id = o.order_id
GROUP BY o.order_month
ORDER BY o.order_month;


-- =============================================================================
-- Q2. Top 10 product categories by GMV, with share of total
--     Tables: v_orders_clean, order_items, products, category translation (4 tables)
-- =============================================================================
\qecho '=== Q2. Top 10 categories by GMV'
SELECT COALESCE(t.product_category_name_english, 'unknown') AS category,
       COUNT(DISTINCT o.order_id)                          AS orders,
       SUM(1)                                              AS items_sold,
       ROUND(SUM(i.price), 2)                              AS product_revenue,
       ROUND(100.0 * SUM(i.price) / SUM(SUM(i.price)) OVER (), 2) AS pct_of_total,
       ROUND(AVG(i.price), 2)                              AS avg_item_price
FROM v_orders_clean o
JOIN order_items i ON i.order_id   = o.order_id
JOIN products    p ON p.product_id = i.product_id
LEFT JOIN product_category_name_translation t
       ON t.product_category_name = p.product_category_name
GROUP BY category
ORDER BY product_revenue DESC
LIMIT 10;


-- =============================================================================
-- Q3. Revenue by customer state: where are the customers and the money?
--     Tables: v_orders_clean, order_items
-- =============================================================================
\qecho '=== Q3. Revenue and customers by state (top 10)'
SELECT o.customer_state                                   AS state,
       COUNT(DISTINCT o.customer_unique_id)               AS customers,
       COUNT(DISTINCT o.order_id)                         AS orders,
       ROUND(SUM(i.price + i.freight_value), 2)           AS gmv,
       ROUND(100.0 * SUM(i.price + i.freight_value)
             / SUM(SUM(i.price + i.freight_value)) OVER (), 2) AS pct_gmv,
       ROUND(AVG(i.freight_value), 2)                     AS avg_freight_per_item,
       ROUND(AVG(o.delivery_days), 1)                     AS avg_delivery_days
FROM v_orders_clean o
JOIN order_items i ON i.order_id = o.order_id
GROUP BY o.customer_state
ORDER BY gmv DESC
LIMIT 10;


-- =============================================================================
-- Q4. Seller performance: top 15 sellers by GMV with service quality
--     Tables: v_orders_clean, order_items, sellers, v_order_reviews_latest (4)
--     Note: review is per ORDER, so an order with 3 sellers gives each seller
--     the same score. Acceptable approximation; stated in README.
-- =============================================================================
\qecho '=== Q4. Top 15 sellers by GMV'
SELECT s.seller_id,
       s.seller_state,
       COUNT(DISTINCT o.order_id)                  AS orders,
       ROUND(SUM(i.price + i.freight_value), 2)    AS gmv,
       ROUND(AVG(r.review_score), 2)               AS avg_review,
       ROUND(100.0 * AVG(o.is_late::int), 1)       AS pct_late_deliveries,
       ROUND(AVG(o.delivery_days), 1)              AS avg_delivery_days
FROM v_orders_clean o
JOIN order_items i ON i.order_id  = o.order_id
JOIN sellers     s ON s.seller_id = i.seller_id
LEFT JOIN v_order_reviews_latest r ON r.order_id = o.order_id
GROUP BY s.seller_id, s.seller_state
ORDER BY gmv DESC
LIMIT 15;


-- =============================================================================
-- Q5. Delivery performance by month: are we getting faster or slower?
--     Tables: v_orders_clean only
-- =============================================================================
\qecho '=== Q5. Delivery performance by month'
SELECT order_month,
       COUNT(*)                                        AS orders,
       ROUND(AVG(delivery_days), 1)                    AS avg_delivery_days,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delivery_days) AS median_delivery_days,
       ROUND(100.0 * AVG(is_late::int), 1)             AS pct_late,
       ROUND(AVG(days_vs_estimate), 1)                 AS avg_days_vs_estimate  -- negative = early
FROM v_orders_clean
GROUP BY order_month
ORDER BY order_month;

\qecho '=== Q5b. Delivery performance by customer state (min 500 orders)'
SELECT customer_state,
       COUNT(*)                                  AS orders,
       ROUND(AVG(delivery_days), 1)              AS avg_delivery_days,
       ROUND(100.0 * AVG(is_late::int), 1)       AS pct_late,
       ROUND(AVG(days_vs_estimate), 1)           AS avg_days_vs_estimate
FROM v_orders_clean
GROUP BY customer_state
HAVING COUNT(*) >= 500
ORDER BY pct_late DESC;


-- =============================================================================
-- Q6. Does late delivery hurt review scores?
--     Tables: v_orders_clean, v_order_reviews_latest
-- =============================================================================
\qecho '=== Q6. Review score vs delivery lateness'
SELECT CASE
         WHEN o.days_vs_estimate <= -7 THEN '1. >1 week early'
         WHEN o.days_vs_estimate <   0 THEN '2. early'
         WHEN o.days_vs_estimate =   0 THEN '3. on the day'
         WHEN o.days_vs_estimate <=  7 THEN '4. up to 1 week late'
         ELSE                               '5. >1 week late'
       END                                              AS delivery_bucket,
       COUNT(*)                                         AS orders,
       ROUND(AVG(r.review_score), 2)                    AS avg_review,
       ROUND(100.0 * AVG((r.review_score <= 2)::int), 1) AS pct_1_or_2_stars,
       ROUND(100.0 * AVG((r.review_score  = 5)::int), 1) AS pct_5_stars
FROM v_orders_clean o
JOIN v_order_reviews_latest r ON r.order_id = o.order_id
GROUP BY delivery_bucket
ORDER BY delivery_bucket;

\qecho '=== Q6b. 2x2: late vs 1-2 star review'
SELECT o.is_late,
       COUNT(*) FILTER (WHERE r.review_score <= 2) AS low_reviews,
       COUNT(*) FILTER (WHERE r.review_score >  2) AS ok_reviews
FROM v_orders_clean o JOIN v_order_reviews_latest r USING (order_id)
GROUP BY o.is_late ORDER BY o.is_late;

\qecho '=== Q6c. Late x reviewed-before-delivery: where do the 1-2 star reviews come from?'
SELECT o.is_late,
       r.review_creation_date < o.order_delivered_customer_date            AS reviewed_pre_delivery,
       COUNT(*)                                                             AS orders,
       ROUND(AVG(r.review_score), 2)                                        AS avg_review,
       COUNT(*) FILTER (WHERE r.review_score <= 2)                          AS low_reviews,
       ROUND(100.0 * COUNT(*) FILTER (WHERE r.review_score <= 2) / COUNT(*), 1)                         AS pct_low_in_cell,
       ROUND(100.0 * COUNT(*) FILTER (WHERE r.review_score <= 2)
             / SUM(COUNT(*) FILTER (WHERE r.review_score <= 2)) OVER (), 1)                             AS pct_of_all_low_reviews
FROM v_orders_clean o
JOIN v_order_reviews_latest r USING (order_id)
GROUP BY 1, 2
ORDER BY 1, 2;


-- =============================================================================
-- Q7. Payment behaviour: type mix, installments, and CASH collected
--     Tables: v_orders_clean, v_order_payments_agg  (CASH definition)
-- =============================================================================
\qecho '=== Q7. Payment type mix (cash collected)'
SELECT p.main_payment_type,
       COUNT(*)                                            AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)  AS pct_orders,
       ROUND(SUM(p.total_paid), 2)                         AS cash_collected,
       ROUND(AVG(p.total_paid), 2)                         AS avg_order_cash,
       ROUND(AVG(p.max_installments), 1)                   AS avg_installments
FROM v_orders_clean o
JOIN v_order_payments_agg p ON p.order_id = o.order_id
GROUP BY p.main_payment_type
ORDER BY orders DESC;

\qecho '=== Q7b. Installment distribution (credit card only)'
SELECT CASE
         WHEN p.max_installments = 1  THEN '1 (full)'
         WHEN p.max_installments <= 3 THEN '2-3'
         WHEN p.max_installments <= 6 THEN '4-6'
         WHEN p.max_installments <= 10 THEN '7-10'
         ELSE '11+'
       END                                   AS installments,
       COUNT(*)                              AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       ROUND(AVG(p.total_paid), 2)           AS avg_order_cash
FROM v_orders_clean o
JOIN v_order_payments_agg p ON p.order_id = o.order_id
WHERE p.main_payment_type = 'credit_card'
GROUP BY installments
ORDER BY MIN(p.max_installments);


-- =============================================================================
-- Q8. Basket size: how many items per order?
--     Tables: v_orders_clean, order_items
-- =============================================================================
\qecho '=== Q8. Items per order distribution'
WITH basket AS (
  SELECT o.order_id,
         COUNT(*)                     AS n_items,
         COUNT(DISTINCT i.product_id) AS n_distinct_products,
         COUNT(DISTINCT i.seller_id)  AS n_sellers,
         SUM(i.price + i.freight_value) AS order_gmv
  FROM v_orders_clean o
  JOIN order_items i ON i.order_id = o.order_id
  GROUP BY o.order_id
)
SELECT CASE WHEN n_items >= 4 THEN '4+' ELSE n_items::text END AS items_in_order,
       COUNT(*)                                            AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS pct_orders,
       ROUND(AVG(order_gmv), 2)                            AS avg_order_gmv,
       ROUND(100.0 * AVG((n_sellers > 1)::int), 1)         AS pct_multi_seller
FROM basket
GROUP BY items_in_order
ORDER BY MIN(n_items);


-- =============================================================================
-- Q9. Freight burden by category: where does shipping eat the price?
--     Tables: v_orders_clean, order_items, products, translation
-- =============================================================================
\qecho '=== Q9. Freight as % of price, by category (min 500 items)'
SELECT COALESCE(t.product_category_name_english, 'unknown') AS category,
       COUNT(*)                                            AS items,
       ROUND(AVG(i.price), 2)                              AS avg_price,
       ROUND(AVG(i.freight_value), 2)                      AS avg_freight,
       ROUND(100.0 * SUM(i.freight_value) / SUM(i.price), 1) AS freight_pct_of_price,
       ROUND(AVG(p.product_weight_g) / 1000.0, 2)          AS avg_weight_kg
FROM v_orders_clean o
JOIN order_items i ON i.order_id   = o.order_id
JOIN products    p ON p.product_id = i.product_id
LEFT JOIN product_category_name_translation t
       ON t.product_category_name = p.product_category_name
GROUP BY category
HAVING COUNT(*) >= 500
ORDER BY freight_pct_of_price DESC;


-- =============================================================================
-- Q10. When do people buy? Day of week x hour of day
--      Tables: v_orders_clean
-- =============================================================================
\qecho '=== Q10a. Orders by day of week'
SELECT TO_CHAR(order_purchase_timestamp, 'Dy')            AS weekday,
       EXTRACT(ISODOW FROM order_purchase_timestamp)       AS dow_num,
       COUNT(*)                                            AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)  AS pct
FROM v_orders_clean
GROUP BY weekday, dow_num
ORDER BY dow_num;

\qecho '=== Q10b. Orders by hour of day (grouped into dayparts)'
SELECT CASE
         WHEN EXTRACT(HOUR FROM order_purchase_timestamp) BETWEEN 0  AND 5  THEN '1. night  00-05'
         WHEN EXTRACT(HOUR FROM order_purchase_timestamp) BETWEEN 6  AND 11 THEN '2. morning 06-11'
         WHEN EXTRACT(HOUR FROM order_purchase_timestamp) BETWEEN 12 AND 17 THEN '3. afternoon 12-17'
         ELSE                                                                  '4. evening 18-23'
       END                                                AS daypart,
       COUNT(*)                                            AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)  AS pct
FROM v_orders_clean
GROUP BY daypart
ORDER BY daypart;


-- =============================================================================
-- Q11. One-time vs repeat customers: how much revenue do repeaters bring?
--      Tables: v_orders_clean, order_items   (grouped by the PERSON)
-- =============================================================================
\qecho '=== Q11. One-time vs repeat customers'
WITH per_customer AS (
  SELECT o.customer_unique_id,
         COUNT(DISTINCT o.order_id)          AS n_orders,
         SUM(i.price + i.freight_value)      AS lifetime_gmv
  FROM v_orders_clean o
  JOIN order_items i ON i.order_id = o.order_id
  GROUP BY o.customer_unique_id
)
SELECT CASE WHEN n_orders = 1 THEN 'one-time' ELSE 'repeat (2+)' END AS customer_type,
       COUNT(*)                                            AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS pct_customers,
       SUM(n_orders)                                       AS orders,
       ROUND(SUM(lifetime_gmv), 2)                         AS gmv,
       ROUND(100.0 * SUM(lifetime_gmv) / SUM(SUM(lifetime_gmv)) OVER (), 2) AS pct_gmv,
       ROUND(AVG(lifetime_gmv), 2)                         AS avg_lifetime_gmv
FROM per_customer
GROUP BY customer_type
ORDER BY customer_type;


-- =============================================================================
-- Q12. Headline KPIs for the README (single row)
-- =============================================================================
\qecho '=== Q12. Headline KPIs (2017-01 to 2018-08, delivered orders)'
WITH gmv AS (
  SELECT SUM(i.price + i.freight_value) AS gmv, SUM(i.price) AS product_rev
  FROM v_orders_clean o JOIN order_items i ON i.order_id = o.order_id
), cash AS (
  SELECT SUM(p.total_paid) AS cash
  FROM v_orders_clean o JOIN v_order_payments_agg p ON p.order_id = o.order_id
)
SELECT (SELECT COUNT(*)                        FROM v_orders_clean)  AS orders,
       (SELECT COUNT(DISTINCT customer_unique_id) FROM v_orders_clean) AS customers,
       (SELECT COUNT(DISTINCT i.seller_id) FROM v_orders_clean o
          JOIN order_items i ON i.order_id = o.order_id)              AS active_sellers,
       ROUND(gmv.gmv, 2)                                              AS gmv,
       ROUND(cash.cash, 2)                                            AS cash_collected,
       ROUND(gmv.gmv / (SELECT COUNT(*) FROM v_orders_clean), 2)      AS avg_order_value,
       (SELECT ROUND(AVG(review_score), 2) FROM v_orders_clean o
          JOIN v_order_reviews_latest r ON r.order_id = o.order_id)   AS avg_review,
       (SELECT ROUND(100.0 * AVG(is_late::int), 1) FROM v_orders_clean) AS pct_late,
       (SELECT ROUND(AVG(delivery_days), 1) FROM v_orders_clean)      AS avg_delivery_days
FROM gmv, cash;

\qecho '=== Q13a. Non-delivered orders by status and month (all orders, 2017-01..2018-08)'
SELECT DATE_TRUNC('month', order_purchase_timestamp)::date AS month,
       COUNT(*) FILTER (WHERE order_status = 'canceled')    AS canceled,
       COUNT(*) FILTER (WHERE order_status = 'unavailable') AS unavailable,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_status IN ('canceled','unavailable')) / COUNT(*), 2) AS pct_lost
FROM orders
WHERE order_purchase_timestamp >= '2017-01-01' AND order_purchase_timestamp < '2018-09-01'
GROUP BY 1 ORDER BY 1;

\qecho '=== Q13b. Cancellation rate by seller (orders with items, min 100 orders)'
SELECT i.seller_id, s.seller_state,
       COUNT(DISTINCT o.order_id)                                                  AS orders,
       COUNT(DISTINCT o.order_id) FILTER (WHERE o.order_status = 'canceled')       AS canceled,
       ROUND(100.0 * COUNT(DISTINCT o.order_id) FILTER (WHERE o.order_status = 'canceled')
             / COUNT(DISTINCT o.order_id), 1)                                      AS pct_canceled
FROM orders o
JOIN order_items i USING (order_id)
JOIN sellers s ON s.seller_id = i.seller_id
WHERE o.order_purchase_timestamp >= '2017-01-01' AND o.order_purchase_timestamp < '2018-09-01'
GROUP BY i.seller_id, s.seller_state
HAVING COUNT(DISTINCT o.order_id) >= 100
ORDER BY pct_canceled DESC
LIMIT 10;

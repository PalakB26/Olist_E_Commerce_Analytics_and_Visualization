-- =============================================================================
-- 07_advanced_analysis.sql
-- Olist Brazilian E-Commerce — SQL Analytics Project
-- Step 7: advanced analysis — window functions, cohorts, RFM, funnel.
--
-- Run psql -U postgres -d brazilian_e_commerce -f .\sql\07_advanced_analysis.sql -o .\sql\07_advanced_analysis_output.txt
--
-- Builds on 05 (v_orders_clean, v_order_payments_agg, v_order_reviews_latest)
-- and on the findings of 06 (97% one-time customers; lateness drives reviews).
-- Every section names the window-function technique it demonstrates.
-- =============================================================================

\pset footer off


-- =============================================================================
-- A1. Month-over-month growth with LAG()
--     Technique: LAG() to compare each row to the previous row.
-- =============================================================================
\echo '=== A1. Month-over-month growth (LAG)'
WITH monthly AS (
  SELECT o.order_month,
         COUNT(DISTINCT o.order_id)        AS orders,
         SUM(i.price + i.freight_value)    AS gmv
  FROM v_orders_clean o
  JOIN order_items i ON i.order_id = o.order_id
  GROUP BY o.order_month
)
SELECT order_month,
       orders,
       ROUND(gmv, 2)                                            AS gmv,
       LAG(orders) OVER (ORDER BY order_month)                  AS prev_orders,
       ROUND(100.0 * (orders - LAG(orders) OVER (ORDER BY order_month))
             / LAG(orders) OVER (ORDER BY order_month), 1)      AS orders_mom_pct,
       ROUND(100.0 * (gmv - LAG(gmv) OVER (ORDER BY order_month))
             / LAG(gmv) OVER (ORDER BY order_month), 1)         AS gmv_mom_pct,
       -- same month last year (12 rows back) — only exists from 2018-01
       ROUND(100.0 * (gmv - LAG(gmv, 12) OVER (ORDER BY order_month))
             / LAG(gmv, 12) OVER (ORDER BY order_month), 1)     AS gmv_yoy_pct
FROM monthly
ORDER BY order_month;


-- =============================================================================
-- A2. Running total and 3-month moving average
--     Technique: window FRAMES — ROWS BETWEEN ... PRECEDING AND CURRENT ROW
-- =============================================================================
\echo '=== A2. Cumulative GMV and 3-month moving average (window frames)'
WITH monthly AS (
  SELECT o.order_month, SUM(i.price + i.freight_value) AS gmv
  FROM v_orders_clean o
  JOIN order_items i ON i.order_id = o.order_id
  GROUP BY o.order_month
)
SELECT order_month,
       ROUND(gmv, 2)                                                         AS gmv,
       ROUND(SUM(gmv) OVER (ORDER BY order_month
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS cumulative_gmv,
       ROUND(AVG(gmv) OVER (ORDER BY order_month
                            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)    AS gmv_3m_moving_avg,
       ROUND(100.0 * SUM(gmv) OVER (ORDER BY order_month)
             / SUM(gmv) OVER (), 1)                                          AS pct_of_total_to_date
FROM monthly
ORDER BY order_month;


-- =============================================================================
-- A3. Monthly COHORT RETENTION
--     Cohort = month of a customer's FIRST delivered order.
--     Retention = % of that cohort who ordered again N months later.
--     Technique: MIN() OVER (PARTITION BY customer), AGE/date arithmetic, pivot.
-- =============================================================================
\echo '=== A3. Cohort retention matrix (% of cohort active in month N)'
WITH first_order AS (
  SELECT customer_unique_id,
         MIN(order_month) AS cohort_month
  FROM v_orders_clean
  GROUP BY customer_unique_id
), activity AS (
  SELECT o.customer_unique_id,
         f.cohort_month,
         -- months between cohort month and this order's month
         (EXTRACT(YEAR  FROM o.order_month) - EXTRACT(YEAR  FROM f.cohort_month)) * 12
       + (EXTRACT(MONTH FROM o.order_month) - EXTRACT(MONTH FROM f.cohort_month)) AS month_number
  FROM v_orders_clean o
  JOIN first_order f USING (customer_unique_id)
), cohort_size AS (
  SELECT cohort_month, COUNT(*) AS customers
  FROM first_order GROUP BY cohort_month
), retained AS (
  SELECT cohort_month, month_number, COUNT(DISTINCT customer_unique_id) AS active
  FROM activity
  GROUP BY cohort_month, month_number
)
SELECT r.cohort_month,
       s.customers                                                   AS cohort_size,
       ROUND(100.0 * MAX(active) FILTER (WHERE month_number = 1) / s.customers, 2) AS m1,
       ROUND(100.0 * MAX(active) FILTER (WHERE month_number = 2) / s.customers, 2) AS m2,
       ROUND(100.0 * MAX(active) FILTER (WHERE month_number = 3) / s.customers, 2) AS m3,
       ROUND(100.0 * MAX(active) FILTER (WHERE month_number = 6) / s.customers, 2) AS m6,
       ROUND(100.0 * MAX(active) FILTER (WHERE month_number = 12) / s.customers, 2) AS m12
FROM retained r
JOIN cohort_size s USING (cohort_month)
GROUP BY r.cohort_month, s.customers
ORDER BY r.cohort_month;

-- =============================================================================
-- A4. Time to second purchase
--     Technique: LEAD() within a customer partition.
-- =============================================================================
\echo '=== A4. Days between 1st and 2nd order (repeat customers only)'
WITH ordered AS (
  SELECT customer_unique_id,
         order_purchase_timestamp,
         LEAD(order_purchase_timestamp) OVER (PARTITION BY customer_unique_id
                                              ORDER BY order_purchase_timestamp) AS next_purchase,
         ROW_NUMBER() OVER (PARTITION BY customer_unique_id
                            ORDER BY order_purchase_timestamp)                  AS order_seq
  FROM v_orders_clean
)
SELECT COUNT(*)                                                        AS repeat_customers,
       ROUND(AVG(EXTRACT(EPOCH FROM next_purchase - order_purchase_timestamp) / 86400), 1) AS avg_days_to_2nd,
       PERCENTILE_CONT(0.5) WITHIN GROUP
         (ORDER BY EXTRACT(EPOCH FROM next_purchase - order_purchase_timestamp) / 86400) AS median_days_to_2nd,
       ROUND(100.0 * AVG((next_purchase - order_purchase_timestamp <= INTERVAL '1 day')::int), 1) AS pct_within_1_day,
       ROUND(100.0 * AVG((next_purchase - order_purchase_timestamp <= INTERVAL '30 days')::int), 1) AS pct_within_30_days
FROM ordered
WHERE order_seq = 1 AND next_purchase IS NOT NULL;
-- A big 'pct_within_1_day' means many repeats are really split checkouts, not loyalty

-- =============================================================================
-- A5. RFM SEGMENTATION
--     Recency  = days since last order
--     Frequency = number of orders
--     Monetary  = lifetime GMV
--     Technique: NTILE() to score each dimension 1-5, then label segments.
-- =============================================================================
\echo '=== A5. RFM segments'
DROP TABLE IF EXISTS customer_rfm;
CREATE TABLE customer_rfm AS
WITH snapshot AS (
  SELECT MAX(order_purchase_timestamp)::date AS as_of FROM v_orders_clean
), base AS (
  SELECT o.customer_unique_id,
         (SELECT as_of FROM snapshot) - MAX(o.order_purchase_timestamp)::date AS recency_days,
         COUNT(DISTINCT o.order_id)                                             AS frequency,
         SUM(i.price + i.freight_value)                                         AS monetary
  FROM v_orders_clean o
  JOIN order_items i ON i.order_id = o.order_id
  GROUP BY o.customer_unique_id
), scored AS (
  SELECT *,
         NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,   -- most recent = 5
         -- frequency is 1 for 97% of people, so NTILE would be meaningless; use a rule
         CASE WHEN frequency >= 4 THEN 5
              WHEN frequency  = 3 THEN 4
              WHEN frequency  = 2 THEN 3
              ELSE 1 END                            AS f_score,
         NTILE(5) OVER (ORDER BY monetary)          AS m_score    -- biggest spender = 5
  FROM base
)
SELECT *,
       CASE
         WHEN f_score >= 3 AND r_score >= 4                 THEN 'Champions'
         WHEN f_score >= 3 AND r_score <= 2                 THEN 'At risk (were loyal)'
         WHEN f_score >= 3                                  THEN 'Loyal'
         WHEN r_score >= 4 AND m_score >= 4                 THEN 'New big spenders'
         WHEN r_score >= 4                                  THEN 'New / recent'
         WHEN r_score <= 2 AND m_score >= 4                 THEN 'Lost big spenders'
         WHEN r_score <= 2                                  THEN 'Lost'
         ELSE                                                    'Occasional'
       END AS segment
FROM scored;

ALTER TABLE customer_rfm ADD PRIMARY KEY (customer_unique_id);

SELECT segment,
       COUNT(*)                                            AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)  AS pct_customers,
       ROUND(SUM(monetary), 2)                             AS gmv,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS pct_gmv,
       ROUND(AVG(monetary), 2)                             AS avg_gmv,
       ROUND(AVG(recency_days), 0)                         AS avg_recency_days,
       ROUND(AVG(frequency), 2)                            AS avg_orders
FROM customer_rfm
GROUP BY segment
ORDER BY gmv DESC;


-- =============================================================================
-- A6. ORDER FUNNEL: purchase -> approved -> handed to carrier -> delivered
--     Uses ALL orders (not v_orders_clean), because the point is to see drop-off.
--     Technique: conditional aggregation + stage-to-stage conversion.
-- =============================================================================
\echo '=== A6. Order fulfilment funnel (all orders, 2017-01..2018-08)'
WITH scope AS (
  SELECT * FROM orders
  WHERE order_purchase_timestamp >= '2017-01-01'
    AND order_purchase_timestamp <  '2018-09-01'
), stages AS (
  SELECT 1 AS step, 'purchased'          AS stage, COUNT(*) AS n FROM scope
  UNION ALL SELECT 2, 'approved',           COUNT(*) FROM scope WHERE order_approved_at IS NOT NULL
  UNION ALL SELECT 3, 'handed_to_carrier',  COUNT(*) FROM scope WHERE order_delivered_carrier_date IS NOT NULL
  UNION ALL SELECT 4, 'delivered',          COUNT(*) FROM scope WHERE order_delivered_customer_date IS NOT NULL
)
SELECT step, stage, n,
       ROUND(100.0 * n / FIRST_VALUE(n) OVER (ORDER BY step), 2)           AS pct_of_purchased,
       ROUND(100.0 * n / LAG(n) OVER (ORDER BY step), 2)                   AS step_conversion_pct,
       n - LAG(n) OVER (ORDER BY step)                                     AS dropped_at_this_step
FROM stages
ORDER BY step;

\echo '=== A6b. Average hours spent in each stage (delivered orders)'
SELECT ROUND(AVG(EXTRACT(EPOCH FROM order_approved_at - order_purchase_timestamp) / 3600), 1)          AS hrs_purchase_to_approval,
       ROUND(AVG(EXTRACT(EPOCH FROM order_delivered_carrier_date - order_approved_at) / 86400), 1)      AS days_approval_to_carrier,
       ROUND(AVG(EXTRACT(EPOCH FROM order_delivered_customer_date - order_delivered_carrier_date) / 86400), 1) AS days_carrier_to_customer,
       ROUND(AVG(delivery_days), 1)                                                                     AS days_total
FROM v_orders_clean
WHERE order_approved_at IS NOT NULL
  AND order_delivered_carrier_date >= order_approved_at;


-- =============================================================================
-- A7. Ranking within groups: top 3 categories per state
--     Technique: RANK() / DENSE_RANK() OVER (PARTITION BY ...)
-- =============================================================================
\echo '=== A7. Top 3 categories in each of the top 5 states'
WITH state_cat AS (
  SELECT o.customer_state,
         COALESCE(t.product_category_name_english, 'unknown') AS category,
         SUM(i.price) AS revenue
  FROM v_orders_clean o
  JOIN order_items i ON i.order_id   = o.order_id
  JOIN products    p ON p.product_id = i.product_id
  LEFT JOIN product_category_name_translation t USING (product_category_name)
  GROUP BY o.customer_state, category
), ranked AS (
  SELECT *,
         DENSE_RANK() OVER (PARTITION BY customer_state ORDER BY revenue DESC) AS rnk,
         SUM(revenue) OVER (PARTITION BY customer_state)                        AS state_total
  FROM state_cat
), top_states AS (
  SELECT customer_state FROM state_cat
  GROUP BY customer_state ORDER BY SUM(revenue) DESC LIMIT 5
)
SELECT r.customer_state, r.rnk, r.category,
       ROUND(r.revenue, 2) AS revenue,
       ROUND(100.0 * r.revenue / r.state_total, 1) AS pct_of_state
FROM ranked r
JOIN top_states USING (customer_state)
WHERE r.rnk <= 3
ORDER BY r.state_total DESC, r.rnk;

-- =============================================================================
-- A8. Seller concentration: what share of GMV do the top sellers hold?
--     Technique: cumulative share with window SUM, percent-rank.
-- =============================================================================
\echo '=== A8. Seller concentration (Pareto)'
WITH seller_gmv AS (
  SELECT i.seller_id, SUM(i.price + i.freight_value) AS gmv
  FROM v_orders_clean o
  JOIN order_items i ON i.order_id = o.order_id
  GROUP BY i.seller_id
), ranked AS (
  SELECT seller_id, gmv,
         ROW_NUMBER() OVER (ORDER BY gmv DESC)                   AS rnk,
         COUNT(*) OVER ()                                        AS n_sellers,
         SUM(gmv) OVER (ORDER BY gmv DESC) / SUM(gmv) OVER ()    AS cum_share
  FROM seller_gmv
)
SELECT ROUND(100.0 * rnk / n_sellers, 0) AS top_pct_of_sellers,
       MAX(rnk)                           AS sellers,
       ROUND(100.0 * MAX(cum_share), 1)   AS pct_of_gmv
FROM ranked
WHERE ROUND(100.0 * rnk / n_sellers, 0) IN (1, 5, 10, 20, 50)
GROUP BY 1
ORDER BY 1;

-- =============================================================================
-- A9. Seller delivery-lateness vs review: who should Olist fix first?
--     Sellers with >= 100 delivered orders, ranked by late %.
-- =============================================================================
\echo '=== A9. Worst 10 sellers by late-delivery rate (min 100 orders)'
SELECT s.seller_id, s.seller_state,
       COUNT(DISTINCT o.order_id)             AS orders,
       ROUND(100.0 * AVG(o.is_late::int), 1)  AS pct_late,
       ROUND(AVG(r.review_score), 2)          AS avg_review,
       ROUND(SUM(i.price + i.freight_value), 2) AS gmv_at_risk
FROM v_orders_clean o
JOIN order_items i ON i.order_id  = o.order_id
JOIN sellers     s ON s.seller_id = i.seller_id
LEFT JOIN v_order_reviews_latest r ON r.order_id = o.order_id
GROUP BY s.seller_id, s.seller_state
HAVING COUNT(DISTINCT o.order_id) >= 100
ORDER BY pct_late DESC
LIMIT 10;

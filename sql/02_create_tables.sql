-- =============================================================================
-- Olist Brazilian E-Commerce — SQL Analytics Project
-- This is used to create the tables in SQL to Link Different aspects of the
-- databse together
-- =============================================================================

-- Start clean so the script is re-runnable.
DROP SCHEMA IF EXISTS dw CASCADE;
DROP VIEW  IF EXISTS v_orders_clean, v_order_payments_agg, v_order_reviews_latest;
DROP TABLE IF EXISTS customer_rfm, geo_zip;

DROP TABLE IF EXISTS order_reviews, order_payments, order_items, orders,
                     products, product_category_name_translation,
                     sellers, customers, geolocation CASCADE;

-- -----------------------------------------------------------------------------
-- Dimension-like tables (no dependencies)
-- -----------------------------------------------------------------------------

CREATE TABLE customers (
    customer_id              CHAR(32)     PRIMARY KEY,   -- one row per ORDER
    customer_unique_id       CHAR(32)     NOT NULL,      -- the actual PERSON
    customer_zip_code_prefix CHAR(5)      NOT NULL,      -- keep leading zeros
    customer_city            VARCHAR(100),
    customer_state           CHAR(2)
);

CREATE TABLE sellers (
    seller_id                CHAR(32)     PRIMARY KEY,
    seller_zip_code_prefix   CHAR(5)      NOT NULL,
    seller_city              VARCHAR(100),
    seller_state             CHAR(2)
);

CREATE TABLE product_category_name_translation (
    product_category_name         VARCHAR(100) PRIMARY KEY,
    product_category_name_english VARCHAR(100) NOT NULL
);

CREATE TABLE products (
    product_id                 CHAR(32)     PRIMARY KEY,
    product_category_name      VARCHAR(100),             -- 610 rows are NULL
    product_name_length        INTEGER,
    product_description_length INTEGER,
    product_photos_qty         INTEGER,
    product_weight_g           INTEGER,
    product_length_cm          INTEGER,
    product_height_cm          INTEGER,
    product_width_cm           INTEGER
);

CREATE TABLE geolocation (
    geolocation_zip_code_prefix CHAR(5)          NOT NULL,
    geolocation_lat             DOUBLE PRECISION NOT NULL,
    geolocation_lng             DOUBLE PRECISION NOT NULL,
    geolocation_city            VARCHAR(100),
    geolocation_state           CHAR(2)
    -- No PK: ~1M rows, only ~19k distinct zip prefixes.
);

-- -----------------------------------------------------------------------------
-- The center table
-- -----------------------------------------------------------------------------

CREATE TABLE orders (
    order_id                      CHAR(32)    PRIMARY KEY,
    customer_id                   CHAR(32)    NOT NULL REFERENCES customers (customer_id),
    order_status                  VARCHAR(20) NOT NULL,
    order_purchase_timestamp      TIMESTAMP   NOT NULL,
    order_approved_at             TIMESTAMP,
    order_delivered_carrier_date  TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- Fact-like tables (depend on orders)
-- -----------------------------------------------------------------------------

CREATE TABLE order_items (
    order_id            CHAR(32)      NOT NULL REFERENCES orders (order_id),
    order_item_id       SMALLINT      NOT NULL,          -- line number within the order
    product_id          CHAR(32)      NOT NULL REFERENCES products (product_id),
    seller_id           CHAR(32)      NOT NULL REFERENCES sellers (seller_id),
    shipping_limit_date TIMESTAMP,
    price               NUMERIC(10,2) NOT NULL,
    freight_value       NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)                -- composite key
);

CREATE TABLE order_payments (
    order_id             CHAR(32)      NOT NULL REFERENCES orders (order_id),
    payment_sequential   SMALLINT      NOT NULL,         -- 1st, 2nd, 3rd payment on the order
    payment_type         VARCHAR(20)   NOT NULL,
    payment_installments SMALLINT      NOT NULL,
    payment_value        NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE order_reviews (
    review_id               CHAR(32)  NOT NULL,
    order_id                CHAR(32)  NOT NULL REFERENCES orders (order_id),
    review_score            SMALLINT  NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title    VARCHAR(100),
    review_comment_message  TEXT,
    review_creation_date    TIMESTAMP,
    review_answer_timestamp TIMESTAMP
    -- No PK: review_id repeats across orders AND order_id repeats across reviews.
    -- A surrogate key is added in 05_data_cleaning.sql after the duplicates
    -- have been examined.
);

-- -----------------------------------------------------------------------------
-- Indexes on the columns we will join / group on constantly.
-- (Primary keys already create indexes; these are the extra ones.)
-- -----------------------------------------------------------------------------

CREATE INDEX idx_customers_unique_id   ON customers (customer_unique_id);
CREATE INDEX idx_customers_zip         ON customers (customer_zip_code_prefix);
CREATE INDEX idx_sellers_zip           ON sellers (seller_zip_code_prefix);
CREATE INDEX idx_orders_customer_id    ON orders (customer_id);
CREATE INDEX idx_orders_purchase_ts    ON orders (order_purchase_timestamp);
CREATE INDEX idx_orders_status         ON orders (order_status);
CREATE INDEX idx_order_items_product   ON order_items (product_id);
CREATE INDEX idx_order_items_seller    ON order_items (seller_id);
CREATE INDEX idx_order_reviews_order   ON order_reviews (order_id);
CREATE INDEX idx_products_category     ON products (product_category_name);
CREATE INDEX idx_geolocation_zip       ON geolocation (geolocation_zip_code_prefix);

-- Sanity check: list the tables we just made.
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;

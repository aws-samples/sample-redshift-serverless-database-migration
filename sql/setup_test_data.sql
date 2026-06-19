-- ============================================================
-- Test Data Setup for Redshift Migration Tool
-- Run this on the SOURCE Redshift cluster
-- Schema: sales_data (matches default SCHEMAS parameter)
-- ============================================================

-- 1. CREATE SCHEMA
CREATE SCHEMA IF NOT EXISTS sales_data;
SET search_path TO sales_data;

-- ============================================================
-- 2. USERS & GROUPS (tests 01_create_users_groups.sh)
-- ============================================================

-- Users with different privilege levels
CREATE USER sales_data_admin PASSWORD 'TempPass123!' CREATEDB;
CREATE USER sales_data_reader PASSWORD 'TempPass123!';
CREATE USER sales_data_writer PASSWORD 'TempPass123!' CONNECTION LIMIT 10;
CREATE USER sales_data_analyst PASSWORD 'TempPass123!';

-- Groups
CREATE GROUP sales_data_readers;
CREATE GROUP sales_data_writers;
CREATE GROUP sales_data_admins;

-- Group memberships
ALTER GROUP sales_data_readers ADD USER sales_data_reader;
ALTER GROUP sales_data_readers ADD USER sales_data_analyst;
ALTER GROUP sales_data_writers ADD USER sales_data_writer;
ALTER GROUP sales_data_writers ADD USER sales_data_admin;
ALTER GROUP sales_data_admins ADD USER sales_data_admin;

-- User config settings
ALTER USER sales_data_reader SET search_path TO sales_data, public;
ALTER USER sales_data_analyst SET statement_timeout TO 300000;

-- ============================================================
-- 3. TABLES with various features (tests 02_migrate_ddl.sh)
-- ============================================================

-- Table with primary key, sortkey, distkey
CREATE TABLE sales_data.customers (
    customer_id INT IDENTITY(1,1) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255),
    phone VARCHAR(20),
    created_at TIMESTAMP DEFAULT GETDATE(),
    is_active BOOLEAN DEFAULT TRUE,
    PRIMARY KEY (customer_id)
)
DISTSTYLE KEY
DISTKEY (customer_id)
SORTKEY (customer_id);

-- Table with foreign key and compound sortkey
CREATE TABLE sales_data.orders (
    order_id INT IDENTITY(1,1) NOT NULL,
    customer_id INT NOT NULL,
    order_date DATE NOT NULL,
    total_amount DECIMAL(12,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    shipping_address VARCHAR(500),
    PRIMARY KEY (order_id),
    FOREIGN KEY (customer_id) REFERENCES sales_data.customers(customer_id)
)
DISTSTYLE KEY
DISTKEY (customer_id)
COMPOUND SORTKEY (order_date, customer_id);

-- Table with interleaved sortkey
CREATE TABLE sales_data.products (
    product_id INT IDENTITY(1,1) NOT NULL,
    product_name VARCHAR(200) NOT NULL,
    category VARCHAR(100),
    price DECIMAL(10,2) NOT NULL,
    stock_quantity INT DEFAULT 0,
    created_at TIMESTAMP DEFAULT GETDATE(),
    PRIMARY KEY (product_id)
)
DISTSTYLE ALL
INTERLEAVED SORTKEY (category, price);

-- Junction table (tests FK with both references)
CREATE TABLE sales_data.order_items (
    order_item_id INT IDENTITY(1,1) NOT NULL,
    order_id INT NOT NULL,
    product_id INT NOT NULL,
    quantity INT NOT NULL DEFAULT 1,
    unit_price DECIMAL(10,2) NOT NULL,
    discount_pct DECIMAL(5,2) DEFAULT 0,
    PRIMARY KEY (order_item_id),
    FOREIGN KEY (order_id) REFERENCES sales_data.orders(order_id),
    FOREIGN KEY (product_id) REFERENCES sales_data.products(product_id)
)
DISTSTYLE KEY
DISTKEY (order_id)
SORTKEY (order_id, product_id);

-- Table with various data types
CREATE TABLE sales_data.audit_log (
    log_id BIGINT IDENTITY(1,1),
    event_type VARCHAR(50),
    event_data SUPER,
    event_timestamp TIMESTAMPTZ DEFAULT GETDATE(),
    user_name VARCHAR(100),
    ip_address VARCHAR(45),
    duration_ms INT
)
DISTSTYLE EVEN
SORTKEY (event_timestamp);

-- ============================================================
-- 4. INSERT SAMPLE DATA (tests data migration via Glue Spark)
-- ============================================================

INSERT INTO sales_data.customers (first_name, last_name, email, phone)
VALUES
    ('Alice', 'Johnson', 'alice@example.com', '555-0101'),
    ('Bob', 'Smith', 'bob@example.com', '555-0102'),
    ('Carol', 'Williams', 'carol@example.com', '555-0103'),
    ('David', 'Brown', 'david@example.com', '555-0104'),
    ('Eve', 'Davis', 'eve@example.com', '555-0105');

INSERT INTO sales_data.products (product_name, category, price, stock_quantity)
VALUES
    ('Laptop Pro 15', 'Electronics', 1299.99, 50),
    ('Wireless Mouse', 'Electronics', 29.99, 200),
    ('Office Chair', 'Furniture', 449.99, 30),
    ('Standing Desk', 'Furniture', 699.99, 15),
    ('USB-C Hub', 'Electronics', 59.99, 100),
    ('Monitor 27"', 'Electronics', 399.99, 40),
    ('Keyboard Mech', 'Electronics', 149.99, 75),
    ('Desk Lamp', 'Furniture', 79.99, 60);

INSERT INTO sales_data.orders (customer_id, order_date, total_amount, status, shipping_address)
VALUES
    (1, '2026-01-15', 1329.98, 'completed', '123 Main St'),
    (2, '2026-01-20', 449.99, 'completed', '456 Oak Ave'),
    (1, '2026-02-01', 59.99, 'shipped', '123 Main St'),
    (3, '2026-02-10', 1149.98, 'processing', '789 Pine Rd'),
    (4, '2026-02-15', 29.99, 'pending', '321 Elm St'),
    (5, '2026-03-01', 849.98, 'completed', '654 Maple Dr');

INSERT INTO sales_data.order_items (order_id, product_id, quantity, unit_price, discount_pct)
VALUES
    (1, 1, 1, 1299.99, 0),
    (1, 2, 1, 29.99, 0),
    (2, 3, 1, 449.99, 0),
    (3, 5, 1, 59.99, 0),
    (4, 4, 1, 699.99, 0),
    (4, 3, 1, 449.99, 0),
    (5, 2, 1, 29.99, 0),
    (6, 6, 1, 399.99, 5.00),
    (6, 3, 1, 449.99, 0);

INSERT INTO sales_data.audit_log (event_type, event_timestamp, user_name, ip_address, duration_ms)
VALUES
    ('LOGIN', '2026-01-15 08:00:00', 'sales_data_admin', '10.0.1.1', 120),
    ('QUERY', '2026-01-15 08:05:00', 'sales_data_reader', '10.0.1.2', 450),
    ('INSERT', '2026-01-15 09:00:00', 'sales_data_writer', '10.0.1.3', 200),
    ('UPDATE', '2026-01-20 10:30:00', 'sales_data_admin', '10.0.1.1', 180),
    ('DELETE', '2026-02-01 14:00:00', 'sales_data_admin', '10.0.1.1', 90);

-- ============================================================
-- 5. VIEWS (tests 04_migrate_views.sh)
-- ============================================================

-- Simple view
CREATE VIEW sales_data.v_active_customers AS
SELECT customer_id, first_name, last_name, email
FROM sales_data.customers
WHERE is_active = TRUE;

-- View with joins
CREATE VIEW sales_data.v_order_summary AS
SELECT
    o.order_id,
    c.first_name || ' ' || c.last_name AS customer_name,
    o.order_date,
    o.total_amount,
    o.status,
    COUNT(oi.order_item_id) AS item_count
FROM sales_data.orders o
JOIN sales_data.customers c ON o.customer_id = c.customer_id
JOIN sales_data.order_items oi ON o.order_id = oi.order_id
GROUP BY o.order_id, c.first_name, c.last_name, o.order_date, o.total_amount, o.status;

-- View with aggregation
CREATE VIEW sales_data.v_product_sales AS
SELECT
    p.product_id,
    p.product_name,
    p.category,
    SUM(oi.quantity) AS total_sold,
    SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct/100)) AS total_revenue
FROM sales_data.products p
LEFT JOIN sales_data.order_items oi ON p.product_id = oi.product_id
GROUP BY p.product_id, p.product_name, p.category;

-- View referencing another view (tests dependency handling)
CREATE VIEW sales_data.v_top_customers AS
SELECT
    vs.customer_name,
    COUNT(*) AS order_count,
    SUM(vs.total_amount) AS lifetime_value
FROM sales_data.v_order_summary vs
GROUP BY vs.customer_name
ORDER BY lifetime_value DESC;

-- ============================================================
-- 6. MATERIALIZED VIEW (tests 04_migrate_views.sh + 05_refresh)
-- ============================================================

CREATE MATERIALIZED VIEW sales_data.mv_daily_sales AS
SELECT
    o.order_date,
    COUNT(DISTINCT o.order_id) AS order_count,
    COUNT(DISTINCT o.customer_id) AS unique_customers,
    SUM(o.total_amount) AS daily_revenue
FROM sales_data.orders o
GROUP BY o.order_date;

-- ============================================================
-- 7. FUNCTIONS (tests 02_migrate_ddl.sh create_function)
-- ============================================================

CREATE FUNCTION sales_data.fn_calculate_discount(
    DECIMAL(10,2),
    DECIMAL(5,2)
)
RETURNS DECIMAL(10,2)
STABLE
AS $$
    SELECT $1 * (1 - $2 / 100.0)
$$ LANGUAGE sql;

CREATE FUNCTION sales_data.fn_get_order_total(
    DECIMAL(12,2),
    INT
)
RETURNS DECIMAL(12,2)
IMMUTABLE
AS $$
    SELECT $1 * $2
$$ LANGUAGE sql;

-- ============================================================
-- 8. STORED PROCEDURE (tests 02_migrate_ddl.sh create_procedure)
-- ============================================================

CREATE OR REPLACE PROCEDURE sales_data.sp_update_order_status(
    IN p_order_id INT,
    IN p_new_status VARCHAR(20)
)
AS $$
BEGIN
    UPDATE sales_data.orders
    SET status = p_new_status
    WHERE order_id = p_order_id;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER;

CREATE OR REPLACE PROCEDURE sales_data.sp_archive_old_orders(
    IN p_before_date DATE
)
AS $$
BEGIN
    DELETE FROM sales_data.order_items
    WHERE order_id IN (
        SELECT order_id FROM sales_data.orders WHERE order_date < p_before_date
    );
    DELETE FROM sales_data.orders WHERE order_date < p_before_date;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 9. PERMISSIONS (tests 03_migrate_permissions.sh)
-- ============================================================

-- Schema-level grants
GRANT USAGE ON SCHEMA sales_data TO sales_data_reader;
GRANT USAGE ON SCHEMA sales_data TO sales_data_writer;
GRANT USAGE, CREATE ON SCHEMA sales_data TO sales_data_admin;
GRANT USAGE ON SCHEMA sales_data TO sales_data_analyst;

-- Table-level grants
GRANT SELECT ON ALL TABLES IN SCHEMA sales_data TO sales_data_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA sales_data TO sales_data_analyst;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA sales_data TO sales_data_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sales_data TO sales_data_admin;

-- Individual table grants (tests per-table grant path)
GRANT SELECT ON sales_data.audit_log TO sales_data_reader;
REVOKE INSERT, UPDATE ON sales_data.audit_log FROM sales_data_writer;

-- Function/procedure grants
GRANT EXECUTE ON FUNCTION sales_data.fn_calculate_discount(DECIMAL(10,2), DECIMAL(5,2)) TO sales_data_reader;
GRANT EXECUTE ON FUNCTION sales_data.fn_get_order_total(DECIMAL(12,2), INT) TO sales_data_analyst;
GRANT EXECUTE ON PROCEDURE sales_data.sp_update_order_status(INT, VARCHAR) TO sales_data_writer;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA sales_data TO sales_data_admin;

-- Group-level grants
GRANT SELECT ON ALL TABLES IN SCHEMA sales_data TO GROUP sales_data_readers;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA sales_data TO GROUP sales_data_writers;

-- ============================================================
-- 10. VERIFICATION QUERIES (run after setup to confirm)
-- ============================================================

-- Check tables
SELECT schemaname, tablename FROM pg_tables WHERE schemaname = 'sales_data' ORDER BY tablename;

-- Check views
SELECT n.nspname, c.relname, c.relkind
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = 'sales_data' AND c.relkind = 'v'
ORDER BY c.relname;

-- Check users
SELECT usename FROM pg_user_info WHERE usename LIKE '%sales_data%' ORDER BY usename;

-- Check groups
SELECT groname FROM pg_group WHERE groname LIKE '%sales_data%' ORDER BY groname;

-- Check row counts
SELECT 'customers' AS tbl, COUNT(*) FROM sales_data.customers
UNION ALL SELECT 'orders', COUNT(*) FROM sales_data.orders
UNION ALL SELECT 'products', COUNT(*) FROM sales_data.products
UNION ALL SELECT 'order_items', COUNT(*) FROM sales_data.order_items
UNION ALL SELECT 'audit_log', COUNT(*) FROM sales_data.audit_log;

-- Check functions
SELECT n.nspname, p.proname, p.prokind
FROM pg_proc_info p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'sales_data'
ORDER BY p.proname;

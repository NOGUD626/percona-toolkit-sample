-- ダミーデータ投入
-- users: 1000件 / products: 200件 / orders: 3000件 / order_items: ~9000件 / access_log: 5000件
-- 再現性のため決定的な式で生成する (RAND() 不使用)
-- 再帰 CTE のデフォルト上限 (1000) を引き上げないと orders/order_items/access_log が
-- 黙って欠損するので注意。
USE shop;
SET SESSION cte_max_recursion_depth = 100000;

-- 1. 再帰 CTE で連番を生成して 1000 件投入
INSERT INTO users (email, name, status, created_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 1000
)
SELECT
    CONCAT('user', LPAD(n, 4, '0'), '@example.com'),
    CONCAT('User ', LPAD(n, 4, '0')),
    ELT(1 + (n % 3), 'active', 'pending', 'deleted'),
    DATE_SUB(NOW(), INTERVAL n MINUTE)
FROM seq;

-- 2. products 200 件
INSERT INTO products (sku, name, price_jpy)
WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 200
)
SELECT
    CONCAT('SKU-', LPAD(n, 5, '0')),
    CONCAT('Product ', LPAD(n, 4, '0')),
    1000 + (n * 37) % 9000
FROM seq;

-- 3. orders 3000 件
INSERT INTO orders (user_id, total_jpy, ordered_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 3000
)
SELECT
    1 + (n * 7) % 1000,
    500 + (n * 113) % 50000,
    DATE_SUB(NOW(), INTERVAL n HOUR)
FROM seq;

-- 4. order_items 9000 件 (3 件 / order)
INSERT INTO order_items (order_id, product_id, qty)
WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 9000
)
SELECT
    1 + ((n - 1) / 3),
    1 + (n * 17 + (n / 3)) % 200,
    1 + (n % 5)
FROM seq
ON DUPLICATE KEY UPDATE qty = VALUES(qty);

-- 5. access_log 5000 件 (主キーなし)
INSERT INTO access_log (user_id, path, accessed_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 5000
)
SELECT
    1 + (n * 11) % 1000,
    ELT(1 + (n % 5), '/top', '/items', '/cart', '/checkout', '/mypage'),
    DATE_SUB(NOW(), INTERVAL n SECOND)
FROM seq;

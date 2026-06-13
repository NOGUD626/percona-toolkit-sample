#!/usr/bin/env bash
# replica にだけ差分を注入する。root (SUPER) なので read_only=ON でも書ける。
# sql_log_bin=0 で binlog にも残さず、source と本当に「ズレた」状態を作る。
set -euo pipefail

docker compose exec -T replica mysql -uroot -prootpass <<'SQL' 2>&1 | grep -v Warning
SET SESSION sql_log_bin = 0;
USE shop;

-- 1. UPDATE: id=1 のユーザー名を別物に書き換える
UPDATE users SET name = 'DRIFTED-USER-0001' WHERE id = 1;

-- 2. DELETE: id=2 のユーザーを replica からだけ消す
DELETE FROM users WHERE id = 2;

-- 3. INSERT: replica にだけ存在する余計な行
DELETE FROM users WHERE id = 99999 OR email = 'ghost@replica.local';
INSERT INTO users (id, email, name) VALUES (99999, 'ghost@replica.local', 'GhostOnReplica');

-- 4. products: 価格をズラす
UPDATE products SET price_jpy = 999999 WHERE id = 10;

SELECT 'users' tbl, COUNT(*) cnt FROM users
UNION ALL SELECT 'products', COUNT(*) FROM products;
SQL

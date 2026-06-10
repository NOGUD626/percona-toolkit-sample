-- 検証用スキーマ定義
-- 主キーあり (users / products) と、複合主キーや FK 持ち (orders / order_items) を混在させて
-- pt-table-sync のチャンク戦略 (Chunk / Nibble / GroupBy) を切り替え可能にする
CREATE DATABASE IF NOT EXISTS shop CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE shop;

CREATE TABLE users (
    id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    email       VARCHAR(128) NOT NULL,
    name        VARCHAR(64)  NOT NULL,
    status      ENUM('active','pending','deleted') NOT NULL DEFAULT 'active',
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_users_email (email)
) ENGINE=InnoDB;

CREATE TABLE products (
    id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    sku         VARCHAR(32)  NOT NULL,
    name        VARCHAR(128) NOT NULL,
    price_jpy   INT UNSIGNED NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_products_sku (sku)
) ENGINE=InnoDB;

CREATE TABLE orders (
    id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id     INT UNSIGNED    NOT NULL,
    total_jpy   INT UNSIGNED    NOT NULL,
    ordered_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_orders_user_id (user_id)
) ENGINE=InnoDB;

CREATE TABLE order_items (
    order_id    BIGINT UNSIGNED NOT NULL,
    product_id  INT UNSIGNED    NOT NULL,
    qty         INT UNSIGNED    NOT NULL,
    PRIMARY KEY (order_id, product_id)
) ENGINE=InnoDB;

-- pt-table-sync の GroupBy アルゴリズム検証用: 主キーなしテーブル
CREATE TABLE access_log (
    user_id     INT UNSIGNED NOT NULL,
    path        VARCHAR(128) NOT NULL,
    accessed_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

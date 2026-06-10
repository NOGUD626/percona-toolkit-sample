---
title: "Percona Toolkit を Docker で一通り動かして挙動を確かめる (pt-table-checksum / sync / online-schema-change / query-digest)"
emoji: "🐬"
type: "tech"
topics: ["mysql", "percona", "docker", "replication", "perconatoolkit"]
published: false
---

## はじめに

MySQL の運用で **「pt-table-sync で揃える」「pt-online-schema-change で alter する」** という言い回しは、もはやコマンドそのものより「やる事の名前」として通用している。`pt-*` ツール群は MySQL 公式には含まれない Percona Toolkit という別パッケージだが、ドキュメントは充実していて挙動も追いやすい。とはいえ、例えば「pt-table-sync は replica に直接書き込まない」「pt-online-schema-change は shadow テーブルとトリガで継続書き込みを吸収する」といった内部の作りは、実際に動かして観察すると一段理解が進む種類のものなので、この記事では:

- Percona Server 8.0 を **source / replica** の 2 ノードで Docker Compose に立て
- `STATEMENT` フォーマットの binlog で素直にレプリを張り
- `perconalab/percona-toolkit` イメージから 4 つのツールを順に叩く

という構成で、`pt-table-checksum` / `pt-table-sync` / `pt-online-schema-change` / `pt-query-digest` の出力を見ながら挙動を確認していく。記事中で出てくるスクリプトはすべて [percona-toolkit-sample](https://github.com/NOGUD626/percona-toolkit-sample) に置いてある。`docker compose up -d` から各 `scripts/*.sh` を順に実行すれば、本記事と同じ出力が再現できる構成にしている。

## 構成

```
                                 binlog (STATEMENT)
        ┌──────────────┐ ─────────────────────────▶ ┌──────────────┐
        │ pt-source    │                            │ pt-replica   │
        │ Percona 8.0  │                            │ Percona 8.0  │
        │ server-id=1  │                            │ server-id=2  │
        │ port: 13306  │                            │ port: 13307  │
        └──────┬───────┘                            └──────┬───────┘
               │                                           │
               │ ┌──── docker compose exec ──────────────┐ │
               │ │                                       │ │
               └─┤     pt-toolkit  (Perl + pt-* 群)      ├─┘
                 │     entrypoint: sleep infinity        │
                 └───────────────────────────────────────┘
```

ポイントは 3 点:

- レプリ形式は `STATEMENT`。これは `pt-table-sync --sync-to-source` が前提とするフォーマットに合わせている (後述)
- ツール実行用に DB とは別のコンテナとして `perconalab/percona-toolkit` を常駐させている。`pt-*` ツールは MySQL と同居しなくても動作するので、その構成上の自由度をそのまま図に反映した
- replica には `--report-host=replica` を渡し、source の `SHOW REPLICAS` に登場するようにしてある。これは `pt-table-checksum --recursion-method=hosts` が replica を発見するのに使われる

`compose.yaml` の重要箇所だけ:

```yaml
services:
  source:
    image: percona/percona-server:8.0
    command: >
      --server-id=1
      --log-bin=/var/lib/mysql/mysql-bin
      --binlog-format=STATEMENT
      --slow-query-log=ON
      --slow-query-log-file=/var/lib/mysql/slow.log
      --long-query-time=0          # 全クエリ slowlog
  replica:
    image: percona/percona-server:8.0
    command: >
      --server-id=2
      --log-bin=/var/lib/mysql/mysql-bin
      --binlog-format=STATEMENT
      --read-only=ON
      --report-host=replica
      --report-port=3306
  toolkit:
    image: perconalab/percona-toolkit:latest
    entrypoint: ["sleep", "infinity"]
```

binlog / slowlog は datadir 配下に置いている。`/var/log/mysql/` を別ボリュームに切ると、初期化時に作られるディレクトリの所有権 (root) と mysqld の実行ユーザ (mysql) が一致せず、起動に失敗することがあるためで、datadir 内に集めると entrypoint が一括で所有権を整えてくれる。

## テストデータ

`init/` 配下の SQL で 5 テーブルを投入する。再帰 CTE で決定的に生成しているため、何度立て直しても同じ行が並ぶ。

| テーブル | 件数 | 構造 | この記事での役どころ |
|---------|------|------|---------------------|
| `users` | 1,000 | 単一 PK + UNIQUE email | pt-table-sync のメイン舞台、pt-OSC の ALTER 対象 |
| `products` | 200 | 単一 PK + UNIQUE sku | 1 件 UPDATE で 1 チャンク差分を作る |
| `orders` | 3,000 | 単一 PK + index(user_id) | チャンク分割確認 |
| `order_items` | 9,000 | 複合 PK | Nibble アルゴリズム検証 |
| `access_log` | 5,000 | **主キーなし** | GroupBy / Stream の検証 |

ここで一点、環境依存の挙動に注意したい点がある。`02-seed.sql` で連番生成に使う再帰 CTE は **MySQL 8.0 のデフォルト `cte_max_recursion_depth=1000` に当たる** ため、orders (3000 行) を入れる時点で `ERROR 3636 (HY000): Recursive query aborted after 1001 iterations` が返る。docker-entrypoint-initdb.d は SQL ファイルがエラー終了するとそこで初期化を打ち切るため、後続の `03-users.sql` (`repl` / `toolkit` ユーザ作成) が実行されないまま起動完了状態になる。表面的には `up -d` も `Healthy` も通っていて、後段で `pt-table-checksum` が `Access denied` を返して初めて気付くタイプの状態なので、SQL の先頭で:

```sql
SET SESSION cte_max_recursion_depth = 100000;
```

を明示しておくのが安全。

## 1. レプリ構築 — ダンプベースの初期コピー

`docker compose up -d` で 2 ノードは立ち上がるが、source の init が終わってから replica が起動するため、replica は source に既に投入されたデータを持っていない状態で始まる。そこで `mysqldump --source-data=2` で現在の binlog 位置をコメントに刻んだ論理ダンプを取り、それを replica にロードしてから `CHANGE REPLICATION SOURCE TO` を実行する。

```bash
# scripts/00-setup-replication.sh の核心部分
docker compose exec source mysqldump -uroot -prootpass \
  --source-data=2 --single-transaction --routines --triggers \
  --databases shop > /tmp/source-dump.sql

# ダンプヘッダのコメントから位置を抽出
POS_LINE=$(grep -m1 'CHANGE MASTER TO' /tmp/source-dump.sql)
FILE=$(echo "$POS_LINE" | sed -E "s/.*MASTER_LOG_FILE='([^']+)'.*/\1/")
POS=$(echo  "$POS_LINE" | sed -E "s/.*MASTER_LOG_POS=([0-9]+).*/\1/")

# replica にダンプをロード → CHANGE REPLICATION SOURCE TO → START REPLICA
docker compose exec replica mysql < /tmp/source-dump.sql
docker compose exec replica mysql -e "
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='source', SOURCE_USER='repl', SOURCE_PASSWORD='replpass',
    SOURCE_LOG_FILE='${FILE}', SOURCE_LOG_POS=${POS},
    GET_SOURCE_PUBLIC_KEY=1;
  START REPLICA;"
```

ここでもう一点、初期化時に補足が必要な箇所がある。`mysqldump --databases shop` は **`mysql.user` を含まない** ので、replica は `shop` データベースは持つが `repl` / `toolkit` ユーザは持たない状態になる。replica 側で `START REPLICA` した直後に `Last_IO_Error: Access denied for user 'repl'@'172.18.0.3'` が返るので、setup スクリプトの末尾で replica にもユーザを別途 CREATE しておく:

```sql
CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED WITH mysql_native_password BY 'replpass';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
CREATE USER IF NOT EXISTS 'toolkit'@'%' IDENTIFIED WITH mysql_native_password BY 'toolkitpass';
GRANT ALL PRIVILEGES ON *.* TO 'toolkit'@'%';
```

`mysql_native_password` の明示は必要になる。`perconalab/percona-toolkit` イメージに同梱されている Perl DBD::mysql のバージョンは MySQL 8.0 デフォルトの `caching_sha2_password` に対応していないため、`mysql_native_password` を指定しておくと pt-* ツールから接続できる。

セットアップ完了時の状態:

```
== replica の状態 ==
              Source_Log_File: mysql-bin.000003
          Read_Source_Log_Pos: 157
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
        Seconds_Behind_Source: 0
== source からの SHOW REPLICAS で replica が見えるか確認 (report-host の効果) ==
Server_Id  Host     Port  Source_Id  Replica_UUID
2          replica  3306  1          a8cc66fc-...
```

`report-host` が反映され `Host=replica` で見えている。これが後段の `pt-table-checksum --recursion-method=hosts` の動作条件になる。

## 2. pt-table-checksum — 差分検出

ベースライン取得から始める。

```bash
docker compose exec toolkit pt-table-checksum \
    h=source,u=toolkit,p=toolkitpass,P=3306 \
    --databases shop \
    --recursion-method=hosts \
    --chunk-size=500 \
    --chunk-size-limit=20 \
    --no-check-binlog-format
```

出力:

```
            TS ERRORS  DIFFS     ROWS  DIFF_ROWS  CHUNKS SKIPPED    TIME TABLE
06-10T14:45:08      0      0     5000          0       1       0   0.313 shop.access_log
06-10T14:45:08      0      0     9000          0       1       0   0.322 shop.order_items
06-10T14:45:08      0      0     3000          0       1       0   0.328 shop.orders
06-10T14:45:09      0      0      200          0       1       0   0.320 shop.products
06-10T14:45:09      0      0     1001          0       1       0   0.323 shop.users
```

`DIFFS=0` で全テーブル差分なし。

`--chunk-size-limit` をデフォルトの 2.0 のままにすると、**「source 側ではチャンク 1 つで処理する見積もりだが replica の行数が想定より多い」と判定されたテーブルがスキップされる** ことがある。これは pt-table-checksum がチャンクサイズを `EXPLAIN` の rows 推定で決める設計で、推定値が 0〜1 行に丸まる小テーブルでも実行時には数千行ある場合、ツールから見ると安全側に倒してスキップするためで、`--chunk-size-limit=20` のように比率を大きく取れば対象に含まれる。

ここで replica にだけ差分を入れる。`sql_log_bin=0` で binlog への書き出しを止めれば、source からは見えない片側だけの変更を作れる。

```sql
SET SESSION sql_log_bin = 0;
USE shop;
UPDATE users SET name = 'DRIFTED-USER-0001' WHERE id = 1;
DELETE FROM users WHERE id = 2;
INSERT INTO users (id, email, name) VALUES (99999, 'ghost@replica.local', 'GhostOnReplica');
UPDATE products SET price_jpy = 999999 WHERE id = 10;
```

もう一度 `pt-table-checksum` を実行すると:

```
            TS ERRORS  DIFFS     ROWS  DIFF_ROWS  CHUNKS SKIPPED    TIME TABLE
06-10T14:46:13      0      1      200          0       1       0   0.320 shop.products
06-10T14:46:14      0      1     1001          0       1       0   0.323 shop.users
```

`shop.products` と `shop.users` で `DIFFS=1`。`percona.checksums` テーブルを直接見ると、各チャンクの「source 側 CRC vs replica 側 CRC」が記録されている:

```sql
mysql> SELECT db, tbl, chunk, this_cnt, source_cnt,
       LEFT(this_crc,12) tc, LEFT(source_crc,12) sc
       FROM percona.checksums;
+------+-------------+-------+----------+------------+--------------+--------------+
| db   | tbl         | chunk | this_cnt | source_cnt | tc           | sc           |
+------+-------------+-------+----------+------------+--------------+--------------+
| shop | access_log  |     1 |     5000 |       5000 | 30b56214...  | 30b56214...  |
| shop | orders      |     1 |     3000 |       3000 | 237db476...  | 237db476...  |
| shop | order_items |     1 |     9000 |       9000 | abcb4b6c...  | abcb4b6c...  |
| shop | products    |     1 |      200 |        200 | fd50923e...  | 678597c2...  |  ← 差分
| shop | users       |     1 |     1001 |       1001 | ea365b7a...  | 6d5f81fa...  |  ← 差分
+------+-------------+-------+----------+------------+--------------+--------------+
```

行数は一致しているが CRC が異なる。これが「内容のズレ」を表すシグナルになる。

なお `pt-table-checksum` のプロセス終了コードはビットフラグで、差分があると `2` ビットが立つ仕様になっている。シェルスクリプトで `set -e` していると差分検出時の正常終了 (exit=2) が異常扱いで途中終了してしまうため、`|| true` で受けるか `$?` を見て分岐する形で受けるのが扱いやすい。

## 3. pt-table-sync — 修復

差分の場所が分かったので埋めにいく。`pt-table-sync` には 2 つの戦略がある:

- **`--sync-to-source`**: replica を DSN で指定すると、pt-table-sync は対応する source を自動で探し、**source 側に `REPLACE` / `DELETE` / `INSERT` を発行する**。それが binlog を経由して replica に伝播し、結果的に両側が揃う
- **直接書き込み**: source / replica の 2 つの DSN を渡し、片方の内容で片方を上書きする。replica に直接書き込むためレプリの整合状態に影響しうる。レプリを張っていない 2 台の同期向き

レプリ構成では `--sync-to-source` を使う。まずは `--print` で出力される SQL だけを確認する:

```bash
docker compose exec toolkit pt-table-sync \
    --print \
    --replicate percona.checksums \
    --sync-to-source \
    h=replica,u=toolkit,p=toolkitpass,P=3306
```

出力 (一部):

```sql
REPLACE INTO `shop`.`products`(`id`, `sku`, `name`, `price_jpy`)
  VALUES ('10', 'SKU-00010', 'Product 0010', '1370') /*percona-toolkit ... lock:1 transaction:1 ...*/;

DELETE FROM `shop`.`users` WHERE `id`='99999' LIMIT 1 /*percona-toolkit ...*/;

REPLACE INTO `shop`.`users`(`id`, `email`, `name`, `status`, `created_at`)
  VALUES ('1', 'user0001@example.com', 'User 0001', 'pending', '2026-06-10 14:41:45') /*...*/;

REPLACE INTO `shop`.`users`(`id`, `email`, `name`, `status`, `created_at`)
  VALUES ('2', 'user0002@example.com', 'User 0002', 'deleted', '2026-06-10 14:40:45') /*...*/;
```

- replica にだけあった `id=99999` は `DELETE`
- replica が消した `id=2` は `REPLACE INTO` で再投入
- replica が書き換えた `id=1` の `name` は `REPLACE INTO` で source の値に戻す
- replica が変えた `products.id=10` の価格も同様に `REPLACE`

`--print` で SQL を確認してから `--execute` に切り替える流れは、本番作業の作法としても運用しやすい。

```bash
docker compose exec toolkit pt-table-sync \
    --execute --verbose \
    --replicate percona.checksums \
    --sync-to-source \
    h=replica,u=toolkit,p=toolkitpass,P=3306
```

出力:

```
# Syncing via replication P=3306,h=replica,p=...,u=toolkit
# DELETE REPLACE INSERT UPDATE ALGORITHM START    END      EXIT DATABASE.TABLE
#      0       1      0      0 Chunk     14:48:01 14:48:01 2    shop.products
#      1       2      0      0 Chunk     14:48:01 14:48:02 2    shop.users
```

products に REPLACE 1 件、users に DELETE 1 件 + REPLACE 2 件。EXIT カラムが `2` なのは pt-table-checksum と同じビットフラグの意味で「差分があった (= 同期した)」を表す。

再度 checksum を実行すると:

```
            TS ERRORS  DIFFS     ROWS  DIFF_ROWS  CHUNKS SKIPPED    TIME TABLE
06-10T14:48:02      0      0     5000          0       1       0   0.315 shop.access_log
06-10T14:48:03      0      0     9000          0       1       0   0.333 shop.order_items
06-10T14:48:03      0      0     3000          0       1       0   0.327 shop.orders
06-10T14:48:03      0      0      200          0       1       0   0.320 shop.products
06-10T14:48:04      0      0     1001          0       1       0   0.323 shop.users
```

全テーブル `DIFFS=0` に戻った。

## 4. pt-online-schema-change — 無停止 ALTER

`users` テーブルに `phone VARCHAR(20)` を追加する。同時並行で 20 回 `INSERT` を流し、**ALTER 中も書き込みが受け付けられている**ことを確認する。

```bash
# 裏で 0.5 秒間隔の INSERT を 20 回
(
  for i in $(seq 1 20); do
    docker compose exec -T source mysql -uroot -prootpass \
      -e "INSERT INTO shop.users (email, name) VALUES ('osc-$i@example.com','OSC user $i');"
    sleep 0.5
  done
) &

# 本命
docker compose exec toolkit pt-online-schema-change \
    --execute \
    --alter "ADD COLUMN phone VARCHAR(20) NULL" \
    --no-check-replication-filters \
    --recursion-method=hosts \
    --print \
    h=source,u=toolkit,p=toolkitpass,P=3306,D=shop,t=users
```

`--print` を付けるとツールが内部で発行している SQL がすべて標準出力に出る。要約するとこういう順序になる:

```mermaid
sequenceDiagram
    autonumber
    participant App  as アプリ (継続書き込み)
    participant U    as shop.users (元テーブル)
    participant N    as shop._users_new (shadow)
    participant Trg  as 3 トリガ INS/UPD/DEL
    participant pt   as pt-online-schema-change

    pt->>N: CREATE TABLE _users_new (新スキーマ)
    pt->>N: ALTER TABLE _users_new ADD COLUMN phone ...
    pt->>Trg: CREATE TRIGGER × 3 (AFTER INS/UPD/DEL ON users)
    App->>U:  INSERT / UPDATE / DELETE
    U->>Trg:  AFTER 行
    Trg->>N:  同じ変更を _users_new にも適用
    pt->>U:   chunk 単位で SELECT
    pt->>N:   INSERT LOW_PRIORITY IGNORE でコピー
    pt->>U:   RENAME users → _users_old, _users_new → users (アトミック)
    pt->>U:   DROP _users_old
    pt->>Trg: DROP TRIGGER × 3
```

トリガが興味深い。例えば AFTER INSERT のトリガは:

```sql
CREATE TRIGGER `pt_osc_shop_users_ins` AFTER INSERT ON `shop`.`users`
FOR EACH ROW
BEGIN
  DECLARE CONTINUE HANDLER FOR 1146 begin end;
  REPLACE INTO `shop`.`_users_new` (`id`, `email`, `name`, `status`, `created_at`)
    VALUES (NEW.`id`, NEW.`email`, NEW.`name`, NEW.`status`, NEW.`created_at`);
END
```

- `REPLACE INTO` を使っているため、chunk コピーと新規 INSERT が同じ PK で衝突した場合も新しい行で上書きされ、結果整合の問題が起こらない設計になっている
- `CONTINUE HANDLER FOR 1146` (Table doesn't exist) は、`RENAME` の瞬間に shadow テーブルが一瞬存在しなくなる時間帯に対する保険として置かれている

コピー完了後の `RENAME TABLE users TO _users_old, _users_new TO users` は **1 ステートメントでアトミックに行われる**。クライアントから見るとテーブル名は変わらないまま、次のクエリでカラムが増えているだけに見える。

実行ログ:

```
Created new table shop._users_new OK.
Altered `shop`.`_users_new` OK.
Creating triggers...
Created triggers OK.
Copying approximately 1001 rows...
Copied rows OK.
Swapping tables...
RENAME TABLE `shop`.`users` TO `shop`.`_users_old`, `shop`.`_users_new` TO `shop`.`users`
Swapped original and new tables OK.
Dropping old table...
Dropped old table `shop`.`_users_old` OK.
Dropping triggers...
Dropped triggers OK.
Successfully altered `shop`.`users`.
```

ALTER 後のスキーマ:

```
Field      Type                                Null Key Default Extra
id         int unsigned                        NO   PRI NULL    auto_increment
email      varchar(128)                        NO   UNI NULL
name       varchar(64)                         NO       NULL
status     enum('active','pending','deleted')  NO       active
created_at datetime                            NO       CURRENT_TIMESTAMP
phone      varchar(20)                         YES      NULL              ← 追加された
```

裏で打った 20 件の INSERT:

```
mysql> SELECT COUNT(*) FROM shop.users WHERE email LIKE 'osc-%';
+-------+
| count |
+-------+
|    20 |   ← source
+-------+
|    20 |   ← replica にも全件伝播
+-------+
```

ALTER と並走した書き込みが両ノードに残っていることが確認できた。

## 5. pt-query-digest — slowlog 集計

`compose.yaml` で `long_query_time=0` を指定しているため、**source が受けたすべてのクエリが slowlog に書き出される** 状態になっている。`pt-query-digest` でそれを集計する。

意図的に重めのワークロードを流したあと:

```bash
# 軽い SELECT 200 回
for i in $(seq 1 200); do
  mysql -e "SELECT COUNT(*) FROM shop.users WHERE status='active';"
done

# JOIN + GROUP BY 30 回
for i in $(seq 1 30); do
  mysql -e "SELECT u.id, u.name, COUNT(o.id) AS orders_cnt
            FROM shop.users u LEFT JOIN shop.orders o ON o.user_id=u.id
            GROUP BY u.id, u.name ORDER BY orders_cnt DESC LIMIT 10;"
done

# 全件 LIKE の full scan を 5 回
for i in $(seq 1 5); do
  mysql -e "SELECT COUNT(*) FROM shop.access_log WHERE path LIKE '%items%';"
done

# slowlog を toolkit コンテナへコピーして集計
docker cp pt-source:/var/lib/mysql/slow.log /tmp/slow.log
docker cp /tmp/slow.log pt-toolkit:/tmp/slow.log
docker compose exec toolkit pt-query-digest --limit 3 /tmp/slow.log
```

`pt-query-digest` の出力は 3 つのブロックで構成される:

1. **Overall** — 集計全体のサマリ。クエリ総数、Exec time / Lock time / Rows sent / Rows examine の合計と分布
2. **Profile** — クエリを「同じ抽象形」でグルーピングし、Response time 合計の TOP N を一覧表で出力
3. **Detailed report** — 各 TOP クエリの個別レポート: フィンガープリント (パラメータを `?` 化したテンプレ)、Query_time 分布、サンプル SQL、`EXPLAIN` 用クエリ

実出力の Overall / Profile 抜粋:

```
# Overall: 13.72k total, 215 unique, 10.09 QPS, 0.00x concurrency
# Exec time             2s     1us    27ms   143us   445us   721us    13us
# Rows examine      22.25M       0 199.41k   1.66k 1012.63  13.91k       0

# Profile
# Rank Query ID                            Response time Calls R/Call V/M
# ==== =================================== ============= ===== ====== ====
#    1 0xE77769C62EF669AA7DD5F6760F2D2EBB   0.2349 12.0%   467 0.0005  0.00 SHOW VARIABLES
#    2 0x65EACCB81E5CE21F99E369F100E2BE04   0.1933  9.8%   480 0.0004  0.00 SELECT shop.users
#    3 0x7DFA2D5D9DBC803F79DB97773EC5447B   0.1732  8.8%  1705 0.0001  0.00 INSERT time_zone_transition
# MISC 0xMISC                               1.3618 69.4% 11072 0.0001   0.0 <212 ITEMS>
```

`long_query_time=0` を起動時から有効にしていると、ベンチで流した `SELECT COUNT(*) FROM shop.users` (Rank 2: 480 calls) と並んで、

- Rank 1: `SHOW VARIABLES LIKE 'character_set_server'` (Percona Toolkit が接続時に発行する設定確認)
- Rank 3: `INSERT INTO time_zone_transition` (Percona Server 起動時の tzinfo 投入)

など、**測定したい範囲の外で発生したクエリ** も上位に並ぶ。これは「pt-query-digest の出力は時刻範囲を絞って読むものだ」という運用上の常識の出どころで、本番では `FLUSH LOGS` で slowlog を切ってから、測定したい期間だけ集計対象にするのが標準的な使い方になる。

Rank 2 の `SELECT COUNT(*) FROM shop.users WHERE status='active'` を Detail で開くと:

```
# Query 2: 0.58 QPS, 0.00x concurrency
# Count          3     480       ← この種類のクエリ 480 件、全体の 3%
# Exec time      9   193ms       ← 合計 193ms、全体の 9%
# Rows examine   2 478.59k       ← 1 件あたり 1021 行スキャン × 480 = 480k 行
# Tables
#    SHOW TABLE STATUS FROM `shop` LIKE 'users'\G
#    SHOW CREATE TABLE `shop`.`users`\G
# EXPLAIN /*!50100 PARTITIONS*/
SELECT COUNT(*) FROM shop.users WHERE status='active'\G
```

- フィンガープリント (パラメータが `?` 化された抽象形) ではなく **実際に発行された具体的な SQL** をサンプルとして出力する
- `EXPLAIN` 用のクエリと `SHOW TABLE STATUS` / `SHOW CREATE TABLE` を整形済みで一緒に出力してくれるため、そのままコピーして分析に進める
- `Query_time distribution` で µs 〜 ms のレンジを文字ヒストグラムで描画する (`100us` の位置に `#` が並ぶ形)

pt-query-digest はこの他にも、

- `--filter='$event->{db} eq "shop"'` のように Perl 式で絞り込み
- `--review h=...,t=...` で「過去に見たクエリ」をテーブルに記録して差分管理
- `--type tcpdump` でパケットキャプチャを集計

など多機能だが、まずは **「`long_query_time=0` で全クエリを slowlog に出して → 集計」** という基本の流れを手で動かすところから始めると、各機能の位置付けが把握しやすい。

## まとめ

| ツール | 何をした |
|--------|----------|
| pt-table-checksum | チャンク単位の CRC で差分検出。replica に差分を注入し、CRC のズレを `percona.checksums` で観察 |
| pt-table-sync | `--sync-to-source` で source 側に SQL を発行し、binlog で replica に伝播させる形で修復 |
| pt-online-schema-change | shadow テーブル + INS/UPD/DEL の 3 トリガ + アトミック RENAME で、書き込みを止めずに `phone` カラムを追加 |
| pt-query-digest | `long_query_time=0` の slowlog から、コール数 / 合計時間 / サンプル SQL を抽出 |

実装に踏み込むと、4 つのツールはそれぞれ独立した小さな設計判断の集合体になっているのが分かる。例えば「`pt-table-sync --sync-to-source` は STATEMENT 必須だが他はそうでもない」「pt-online-schema-change のトリガは `REPLACE` で構成されており、chunk コピーと並走書き込みが衝突しても結果が安定する」など、Docker で 1 セット立てて個別に実行すると、それぞれの設計判断の背景が動作から見えてくる。

本記事で使った compose / scripts は [percona-toolkit-sample](https://github.com/NOGUD626/percona-toolkit-sample) に置いてある。手元で `docker compose up -d && bash scripts/00-setup-replication.sh` を実行すると、同じ状態が再現できるはず。

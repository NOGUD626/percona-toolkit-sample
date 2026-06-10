# pt-query-digest — スロークエリ集計

## 概念

slowlog (general log や tcpdump も可) を読み、同じ抽象形のクエリをグルーピングして合計時間 / コール数 / サンプル SQL で集計する。**「呼び出し回数の多さ ≠ 重さ」** を可視化するのが本来の用途。

```
                 long_query_time = 0
   全クエリ ───────────────────────▶  /var/lib/mysql/slow.log
                                            │
                                            │ pt-query-digest
                                            ▼
                          ┌──────────────────────────────────┐
                          │ Overall (合計サマリ)              │
                          │ Profile (TOP N クエリ一覧)        │
                          │ Detailed report (各クエリの分布)  │
                          └──────────────────────────────────┘
```

## このリポジトリで使ったコマンド

```bash
# slowlog を toolkit コンテナへコピー
docker cp pt-source:/var/lib/mysql/slow.log /tmp/slow.log
docker cp /tmp/slow.log pt-toolkit:/tmp/slow.log

docker compose exec toolkit pt-query-digest --limit 3 /tmp/slow.log
```

| オプション | 意味 |
|-----------|------|
| `--limit 3` | TOP 3 クエリだけ詳細レポートを出す |
| `--filter '$event->{db} eq "shop"'` | Perl 式で絞り込み (DB / user / fingerprint 等) |
| `--review h=...,t=...` | 過去に見たクエリを記録、差分管理 |
| `--type tcpdump` | slowlog ではなくパケットキャプチャを解析 |

## ワークロード設定

`compose.yaml` で `long_query_time=0` を指定し、source が受けたすべてのクエリを slowlog に流すようにしている:

```yaml
command: >
  --slow-query-log=ON
  --slow-query-log-file=/var/lib/mysql/slow.log
  --long-query-time=0
```

実演では:

- 軽い SELECT を 200 回 (`SELECT COUNT(*) FROM users WHERE status='active'`)
- JOIN + GROUP BY を 30 回 (`users LEFT JOIN orders GROUP BY ORDER BY LIMIT 10`)
- index 未使用な LIKE スキャンを 5 回 (`access_log WHERE path LIKE '%items%'`)

を順に流して slowlog を作る。

## 出力構造

3 つのブロック:

1. **Overall** — 集計対象のクエリ総数、Exec time / Lock time / Rows sent / Rows examined の合計と分布
2. **Profile** — クエリを「同じ抽象形」でグルーピングし、Response time 合計の TOP N を一覧表で
3. **Detailed report (1...N)** — 各 TOP クエリの個別レポート: フィンガープリント、Query_time 分布、サンプル SQL、`EXPLAIN` ヒント、Tables / Hosts

例 (Profile セクション):

```
# Profile
# Rank Query ID                           Response time   Calls R/Call V/M
# ==== ================================== =============== ===== ====== ====
#    1 0x7F7D57ACDD8A346E594A8C3D85052623  ... ...% ... ...   30 0.0xxx  0.xx  SELECT users orders
#    2 0xB3D6F627A91D9D24C19E63F87C58D9A8  ... ...% ... ...  200 0.0xxx  0.xx  SELECT users
#    3 0x8F2A7B... (アクセスログ full scan) ...               5 0.0xxx  0.xx  SELECT access_log
```

- `Calls=30` の JOIN クエリが合計時間トップになりがち (1 回が重い)
- `Calls=200` の単純 COUNT(*) は単発は軽いが合計時間で 2 位に来る (積み上げが効く)
- `Calls=5` の LIKE フルスキャンは V/M (分散) が大きく、個別問題として浮かぶ

このように **「コール数」「単発の重さ」「合計時間」** の 3 軸で別々の問題が浮かぶのが pt-query-digest の旨み。

## 注意点

- **slowlog の rotate**: 本番では `mysqladmin flush-logs` で切ってから集計するのが安全。集計中に書き込みが続くと end-of-file 判定でズレる
- **`long_query_time=0` は I/O 負荷**: 本番で常時有効にするのは避け、サンプリング期間だけ有効にする
- **個人情報を含むクエリ**: ログには WHERE 句の値が生で記録される。フィンガープリント (`?` 化) は集計時の処理なので、生ログそのものは別途取り扱いに注意
- **tcpdump 解析**: slowlog を有効化できない環境 (マネージド MySQL 等) では `--type tcpdump` でパケキャプから集計できる

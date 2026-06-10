# pt-table-checksum — 差分検出

## 概念

各テーブルをチャンクに分割し、source 側で `SELECT ... CRC32` 的なクエリを発行する。同じクエリが binlog 経由で replica 側でも実行される。両側が結果を `percona.checksums` テーブルに書き込み、後で「source 行 vs replica 行」を見比べる事で差分の有無を判定する。

```
source                                        replica
  │                                              │
  │ pt-table-checksum (SELECT ... CRC32)         │
  ├──────────► percona.checksums                 │
  │                  │                           │
  │            binlog で SQL が伝播               │
  │                  ▼                           │
  │           replica でも同じ SELECT 実行        │
  │           結果を percona.checksums へ書く ───▶│
  │                                              │
  │  SELECT ... FROM percona.checksums           │
  │  WHERE this_crc <> source_crc                │
  └─◀────── 差分のあるチャンクが返る ─────────────┘
```

## このリポジトリで使ったコマンド

```bash
docker compose exec toolkit pt-table-checksum \
    h=source,u=toolkit,p=toolkitpass,P=3306 \
    --databases shop \
    --recursion-method=hosts \
    --chunk-size=500 \
    --chunk-size-limit=20 \
    --no-check-binlog-format
```

| オプション | 意味 |
|-----------|------|
| `h=source,u=toolkit,p=...` | DSN (host=source, user=toolkit, password=...) |
| `--databases shop` | 対象 DB を絞る |
| `--recursion-method=hosts` | `SHOW REPLICAS` で replica を発見 (replica に `--report-host` が必要) |
| `--chunk-size=500` | 1 チャンク 500 行を目安に分割 |
| `--chunk-size-limit=20` | 「想定の 20 倍まで行数がブレても OK」と緩めの設定 |
| `--no-check-binlog-format` | STATEMENT 以外でも止めない (今回は STATEMENT なので冗長だが付けておく) |

## 出力

```
            TS ERRORS  DIFFS     ROWS  DIFF_ROWS  CHUNKS SKIPPED    TIME TABLE
06-10T14:46:13      0      0     5000          0       1       0   0.318 shop.access_log
06-10T14:46:13      0      0     9000          0       1       0   0.340 shop.order_items
06-10T14:46:13      0      0     3000          0       1       0   0.331 shop.orders
06-10T14:46:14      0      1      200          0       1       0   0.321 shop.products
06-10T14:46:14      0      1     1001          0       1       0   0.327 shop.users
```

`DIFFS` 列が 1 以上なら差分あり。`DIFF_ROWS` は 0 のままなのは、Chunk 単位の判定では「行数は一致するが内容が違う」を 1 チャンク差分として数えるため。

## 終了コード (ビットフラグ)

| ビット | 意味 |
|--------|------|
| 1 | エラー or 警告 |
| 2 | 差分あり |
| 4 | 既知の問題でスキップ |

`set -e` 中だと差分検出時 (exit=2 等) で誤って異常終了扱いになる。`|| true` で受ける。

## ハマりどころ

- **小テーブルで Skip される**: `EXPLAIN` の rows 推定が 0 〜 1 行に丸まる小テーブルでも実際は数千行ある事がある。`--chunk-size-limit` を 20 以上にすると通る
- **replica が見えない**: `--report-host` を replica に渡しておかないと `SHOW REPLICAS` の Host 列が空になり、`--recursion-method=hosts` が失敗する
- **caching_sha2_password で繋がらない**: `IDENTIFIED WITH mysql_native_password` を明示する

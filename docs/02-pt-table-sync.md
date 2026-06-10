# pt-table-sync — 差分修復

## 概念

`pt-table-checksum` が `percona.checksums` に残した差分情報を読み、source 側に `REPLACE` / `DELETE` / `INSERT` を発行する。binlog 経由で replica に伝播するので、結果として replica が source に揃う。**replica に直接書かない**点が「安全設計」と呼ばれる所以。

```
                       ┌────────────────────┐
                       │ percona.checksums  │
                       │ どのチャンクがズレてる │
                       └─────────┬──────────┘
                                 │ 参照
                                 ▼
   pt-table-sync ─── REPLACE / DELETE / INSERT ──▶  source
                                                    │
                                            binlog 伝播
                                                    ▼
                                                  replica (揃う)
```

## このリポジトリで使ったコマンド

`--print` で SQL を目視確認:

```bash
docker compose exec toolkit pt-table-sync \
    --print \
    --replicate percona.checksums \
    --sync-to-source \
    h=replica,u=toolkit,p=toolkitpass,P=3306
```

問題なければ `--execute`:

```bash
docker compose exec toolkit pt-table-sync \
    --execute --verbose \
    --replicate percona.checksums \
    --sync-to-source \
    h=replica,u=toolkit,p=toolkitpass,P=3306
```

| オプション | 意味 |
|-----------|------|
| `--print` | 修復 SQL を表示するだけ。書き込まない |
| `--execute` | 実行 |
| `--replicate percona.checksums` | このテーブルを見て差分箇所を判断 |
| `--sync-to-source` | replica 側 DSN を渡し、source を自動検出して修復はそちらに発行 |
| `h=replica,...` | 「ズレてる側」を指す。`--sync-to-source` の挙動上、ここに replica を指定するのが正解 |

## 出力 (`--execute`)

```
# Syncing via replication P=3306,h=replica,p=...,u=toolkit
# DELETE REPLACE INSERT UPDATE ALGORITHM START    END      EXIT DATABASE.TABLE
#      0       1      0      0 Chunk     14:48:01 14:48:01 2    shop.products
#      1       2      0      0 Chunk     14:48:01 14:48:02 2    shop.users
```

`DELETE / REPLACE / INSERT / UPDATE` の各カウントが、source に投入したクエリの種類別の件数。EXIT カラム `2` は「差分があった → 同期した」を意味する。

## 差分検出アルゴリズム (自動選択)

| 方式 | 中身 | 使う場面 |
|------|------|----------|
| **Chunk** | 数値インデックスを ~1000 行ごとに区切り、チャンク単位でチェックサム比較 | 主キー/数値インデックスあり |
| **Nibble** | `LIMIT` で固定サイズに区切りながら走査 | Chunk が使いづらい時 |
| **GroupBy** | 全カラムで `GROUP BY` + `COUNT(*)` 比較 | 主キーが無いテーブル |
| **Stream** | テーブル全体を一気に読んで比較 | 適切なインデックスが無い最終手段 |

## ハマりどころ

- **`--sync-to-source` は STATEMENT 必須**: source で実行した SQL を replica で再実行する仕組みに乗るため、ROW フォーマットではトリガが意図通りに動かないケースがある
- **`--bidirectional` (双方向)** は制約が厳しい: 独立サーバ間のみ・Chunk 必須・2 台限定・**DELETE 非対応**。基本は片方向
- **データを書き換える破壊的ツール**: 本番は必ず `--print` で目視確認してから `--execute`
- **外部キーのある子テーブルへの意図しない DELETE に注意**

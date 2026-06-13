#!/usr/bin/env bash
# pt-table-checksum: ベースライン取得 (差分ゼロの確認)
#
# - source に対して実行する。チャンクごとに source 側で MD5 を計算し、
#   percona.checksums テーブルに書き込む。
# - そのチェックサム計算 SQL を binlog 経由で replica にも適用させて、
#   replica 側でも同じテーブルに自分のチェックサムを書く。
# - 後で percona.checksums を「source 側 vs replica 側」で見比べて差分を判定する仕組み。
#
# オプション:
#   --recursion-method=hosts : SHOW REPLICAS で replica を見つける (replica に
#                              report-host が必要)
#   --chunk-size-limit=20    : 行数推定がブレてもチャンク分割をスキップさせにくくする
#   --no-check-binlog-format : STATEMENT 以外でも警告で止めない
set -euo pipefail

docker compose exec -T toolkit pt-table-checksum \
    h=source,u=toolkit,p=toolkitpass,P=3306 \
    --databases shop \
    --recursion-method=hosts \
    --chunk-size=500 \
    --chunk-size-limit=20 \
    --no-check-binlog-format

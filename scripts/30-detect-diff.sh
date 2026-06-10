#!/usr/bin/env bash
# pt-table-checksum を実行 → percona.checksums を見て差分のあるチャンクを表示
#
# 各行 1 チャンク。this_crc/this_cnt が replica 側、source_crc/source_cnt が source 側。
# どちらかが食い違っていれば差分あり。
set -uo pipefail

echo "== pt-table-checksum 実行 (差分あれば非ゼロ終了するので || true) =="
bash "$(dirname "$0")/10-checksum-clean.sh" | tail -10 || true

echo
echo "== 差分チャンクを抽出 (replica から見る) =="
docker compose exec -T replica mysql -uroot -prootpass -e "
SELECT db, tbl, chunk,
       this_cnt, source_cnt,
       LEFT(this_crc, 12)   AS this_crc,
       LEFT(source_crc, 12) AS source_crc
FROM percona.checksums
WHERE COALESCE(this_crc <> source_crc, 1)
   OR COALESCE(this_cnt <> source_cnt, 1)
ORDER BY db, tbl, chunk;" 2>&1 | grep -v Warning

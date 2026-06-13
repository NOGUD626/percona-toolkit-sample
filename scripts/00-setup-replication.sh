#!/usr/bin/env bash
# 初期コピー + バイナリログ位置の記録 + replica への CHANGE REPLICATION SOURCE TO
#
# 流れ:
#   1) source で mysqldump --source-data=2 --single-transaction で論理ダンプ
#      (ダンプヘッダに CHANGE MASTER TO のコメントで位置が刻まれる)
#   2) ダンプを replica にロード
#   3) ダンプから位置を抜いて replica に CHANGE REPLICATION SOURCE TO
#   4) START REPLICA
set -euo pipefail

SOURCE="docker compose exec -T source mysql -uroot -prootpass"
REPLICA="docker compose exec -T replica mysql -uroot -prootpass"
HOST_DUMP=$(mktemp "${TMPDIR:-/tmp}/pt-source-dump.XXXXXX.sql")
trap 'rm -f "$HOST_DUMP"' EXIT

echo "== source -> dump 取得 =="
docker compose exec -T source bash -lc "mysqldump -uroot -prootpass \
  --source-data=2 --single-transaction --routines --triggers \
  --databases shop > /tmp/source-dump.sql && wc -l /tmp/source-dump.sql"

echo "== dump から binlog 位置を抽出 =="
POS_LINE=$(docker compose exec -T source bash -lc "grep -m1 'CHANGE MASTER TO' /tmp/source-dump.sql")
FILE=$(echo "$POS_LINE" | sed -E "s/.*MASTER_LOG_FILE='([^']+)'.*/\1/")
POS=$(echo  "$POS_LINE" | sed -E "s/.*MASTER_LOG_POS=([0-9]+).*/\1/")
echo "file=${FILE} pos=${POS}"

echo "== replica の既存レプリケーション設定と shop DB をリセット =="
$REPLICA -e "STOP REPLICA;" 2>/dev/null || true
$REPLICA -e "RESET REPLICA ALL;" 2>/dev/null || true
$REPLICA <<'SQL'
SET SESSION sql_log_bin = 0;
DROP DATABASE IF EXISTS shop;
SQL

echo "== dump を replica にコピーしてロード =="
docker cp pt-source:/tmp/source-dump.sql "$HOST_DUMP"
docker cp "$HOST_DUMP" pt-replica:/tmp/source-dump.sql
docker compose exec -T replica bash -lc "mysql -uroot -prootpass < /tmp/source-dump.sql"

echo "== replica にレプリケーション設定を投入 =="
$REPLICA <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='source',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='replpass',
  SOURCE_LOG_FILE='${FILE}',
  SOURCE_LOG_POS=${POS},
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL

sleep 3
echo "== replica の状態 =="
$REPLICA -e "SHOW REPLICA STATUS\G" 2>/dev/null \
  | grep -E "Replica_(IO|SQL)_Running|Seconds_Behind|Last_(IO|SQL)_Error|Source_Log_File|Read_Source_Log_Pos" || true

echo "== replica にも toolkit ユーザーを作成 (pt-table-sync が replica に接続するため) =="
$REPLICA <<'SQL' 2>/dev/null
CREATE USER IF NOT EXISTS 'toolkit'@'%' IDENTIFIED WITH mysql_native_password BY 'toolkitpass';
GRANT ALL PRIVILEGES ON *.* TO 'toolkit'@'%';
FLUSH PRIVILEGES;
SQL

echo "== source で INSERT してレプリ反映を確認 =="
REPL_TEST_EMAIL="repltest-$(date +%s)@example.com"
$SOURCE -e "USE shop; INSERT INTO users (email, name) VALUES ('${REPL_TEST_EMAIL}','ReplTest');" 2>/dev/null
sleep 1
$REPLICA -e "USE shop; SELECT id, email, name FROM users WHERE email='${REPL_TEST_EMAIL}';" 2>/dev/null

echo "== source からの SHOW REPLICAS で replica が見えるか確認 (report-host の効果) =="
$SOURCE -e "SHOW REPLICAS;" 2>/dev/null

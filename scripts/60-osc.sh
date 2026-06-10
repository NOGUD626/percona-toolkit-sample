#!/usr/bin/env bash
# pt-online-schema-change: 無停止 ALTER の実演
#
# 1) shop.users に新カラム phone を ADD する
# 2) ツールは内部で
#    - shadow テーブル `_users_new` を CREATE (構造を新スキーマで作る)
#    - source トリガを 3 種類 (INSERT/UPDATE/DELETE) 付けて新規書き込みを両方に流す
#    - 既存行を chunk 単位で shadow にコピー
#    - RENAME で _users_new ↔ users をアトミックに入れ替え
#    - 旧テーブルを drop (--drop-old-table=yes デフォルト)
# 3) その間、書き込みは止まらない (= 無停止)
#
# 検証として裏で INSERT を流しっぱなしにしておく
set -uo pipefail

SOURCE="docker compose exec -T source mysql -uroot -prootpass"

echo "== ALTER 前のスキーマ =="
$SOURCE -e "DESCRIBE shop.users;" 2>/dev/null

echo
echo "== 裏で INSERT を流す (ALTER 中も止まらないことを確認) =="
(
  for i in $(seq 1 20); do
    $SOURCE -e "INSERT INTO shop.users (email, name) VALUES ('osc-$i@example.com','OSC user $i');" 2>/dev/null
    sleep 0.5
  done
) &
BG_PID=$!

echo
echo "== pt-online-schema-change で phone カラムを追加 (--execute) =="
docker compose exec -T toolkit pt-online-schema-change \
    --execute \
    --alter "ADD COLUMN phone VARCHAR(20) NULL" \
    --no-check-replication-filters \
    --recursion-method=hosts \
    --print \
    h=source,u=toolkit,p=toolkitpass,P=3306,D=shop,t=users

wait $BG_PID || true

echo
echo "== ALTER 後のスキーマ =="
$SOURCE -e "DESCRIBE shop.users;" 2>/dev/null

echo
echo "== 裏で入れた INSERT が users / replica 両方に乗ったか =="
$SOURCE -e "SELECT COUNT(*) AS cnt_with_osc_email FROM shop.users WHERE email LIKE 'osc-%';" 2>/dev/null
docker compose exec -T replica mysql -uroot -prootpass -e "SELECT COUNT(*) AS cnt_with_osc_email FROM shop.users WHERE email LIKE 'osc-%';" 2>/dev/null

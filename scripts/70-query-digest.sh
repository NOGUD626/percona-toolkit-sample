#!/usr/bin/env bash
# pt-query-digest: slowlog の集計
#
# compose.yaml の command で long_query_time=0 にしているため、source が受けたすべてのクエリが
# /var/lib/mysql/slow.log に流れている。
# このスクリプトでは
#   1) 重めのワークロードを source 内部で 1 セッションで投げる
#      (docker compose exec のオーバーヘッドを避けるため heredoc で一気に流す)
#   2) slowlog を pt-query-digest に通して TOP クエリを抽出
set -euo pipefail

SOURCE="docker compose exec -T source mysql -uroot -prootpass"

echo "== slowlog を空にする =="
docker compose exec -T source bash -lc "truncate -s 0 /var/lib/mysql/slow.log"

echo "== ワークロードを 1 セッションで流す =="
$SOURCE >/dev/null 2>/dev/null <<'SQL'
USE shop;
SET SESSION cte_max_recursion_depth = 100000;

-- 軽い SELECT を 200 回 (procedure で回す)
DROP PROCEDURE IF EXISTS bench_light;
DELIMITER //
CREATE PROCEDURE bench_light()
BEGIN
  DECLARE i INT DEFAULT 0;
  WHILE i < 200 DO
    SELECT COUNT(*) AS c FROM users WHERE status='active';
    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;
CALL bench_light();

-- JOIN + GROUP BY を 30 回
DROP PROCEDURE IF EXISTS bench_join;
DELIMITER //
CREATE PROCEDURE bench_join()
BEGIN
  DECLARE i INT DEFAULT 0;
  WHILE i < 30 DO
    SELECT u.id, u.name, COUNT(o.id) AS orders_cnt
    FROM users u LEFT JOIN orders o ON o.user_id=u.id
    GROUP BY u.id, u.name ORDER BY orders_cnt DESC LIMIT 10;
    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;
CALL bench_join();

-- index 未使用な full scan を 20 回
DROP PROCEDURE IF EXISTS bench_scan;
DELIMITER //
CREATE PROCEDURE bench_scan()
BEGIN
  DECLARE i INT DEFAULT 0;
  WHILE i < 20 DO
    SELECT COUNT(*) AS c FROM access_log WHERE path LIKE '%items%';
    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;
CALL bench_scan();

DROP PROCEDURE bench_light;
DROP PROCEDURE bench_join;
DROP PROCEDURE bench_scan;
SQL

echo "== slowlog のサイズ =="
docker compose exec -T source ls -lh /var/lib/mysql/slow.log

echo
echo "== slowlog を toolkit に渡す =="
docker cp pt-source:/var/lib/mysql/slow.log /tmp/slow.log
docker cp /tmp/slow.log pt-toolkit:/tmp/slow.log

echo
echo "== pt-query-digest --limit 3 =="
docker compose exec -T toolkit sh -lc "pt-query-digest --limit 3 /tmp/slow.log 2>&1 | sed -n '1,120p'"

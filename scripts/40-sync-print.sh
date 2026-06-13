#!/usr/bin/env bash
# pt-table-sync --print
# percona.checksums の差分情報を元に、source 側で実行すべき修復 SQL を「表示するだけ」。
# binlog 経由で replica に伝播させる前提なので --sync-to-source で source を指す。
#
# 通常運用ではまず --print で SQL を目視確認 → 問題なければ --execute する。
set -euo pipefail

set +e
docker compose exec -T toolkit pt-table-sync \
    --print \
    --replicate percona.checksums \
    --sync-to-source \
    h=replica,u=toolkit,p=toolkitpass,P=3306
status=$?
set -e

if [[ "$status" -ne 0 && "$status" -ne 2 ]]; then
    exit "$status"
fi

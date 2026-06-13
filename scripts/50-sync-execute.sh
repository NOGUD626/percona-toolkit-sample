#!/usr/bin/env bash
# pt-table-sync --execute
# percona.checksums の差分を、source 側で REPLACE / DELETE / INSERT を発行して埋める。
# binlog で replica に伝播するので、結果として replica が source に揃う。
set -euo pipefail

set +e
docker compose exec -T toolkit pt-table-sync \
    --execute \
    --verbose \
    --replicate percona.checksums \
    --sync-to-source \
    h=replica,u=toolkit,p=toolkitpass,P=3306
status=$?
set -e

if [[ "$status" -ne 0 && "$status" -ne 2 ]]; then
    exit "$status"
fi

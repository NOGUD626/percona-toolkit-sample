#!/usr/bin/env bash
# pt-table-sync --execute
# percona.checksums の差分を、source 側で REPLACE / DELETE / INSERT を発行して埋める。
# binlog で replica に伝播するので、結果として replica が source に揃う。
set -uo pipefail

docker compose exec -T toolkit pt-table-sync \
    --execute \
    --verbose \
    --replicate percona.checksums \
    --sync-to-source \
    h=replica,u=toolkit,p=toolkitpass,P=3306

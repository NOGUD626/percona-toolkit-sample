-- ユーザー作成
-- repl: レプリケーション用 (REPLICATION SLAVE)
-- toolkit: Percona Toolkit 実行用 (SELECT / INSERT / UPDATE / DELETE / PROCESS / REPLICATION CLIENT / SUPER)
-- Percona Toolkit (Perl DBD::mysql 同梱版) は caching_sha2_password 非対応のため
-- repl / toolkit ともに mysql_native_password を明示する
CREATE USER 'repl'@'%' IDENTIFIED WITH mysql_native_password BY 'replpass';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';

CREATE USER 'toolkit'@'%' IDENTIFIED WITH mysql_native_password BY 'toolkitpass';
GRANT ALL PRIVILEGES ON *.* TO 'toolkit'@'%';

FLUSH PRIVILEGES;

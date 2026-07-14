#!/bin/sh
set -eu

psql \
  --set=ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=obelisk_password="$OBELISK_DATABASE_PASSWORD" \
  --set=powersync_password="$POWERSYNC_DATABASE_PASSWORD" \
  --set=storage_password="$POWERSYNC_STORAGE_PASSWORD" <<'SQL'
CREATE ROLE obelisk_api LOGIN PASSWORD :'obelisk_password';
CREATE ROLE powersync_role REPLICATION BYPASSRLS LOGIN PASSWORD :'powersync_password';
CREATE ROLE powersync_storage LOGIN PASSWORD :'storage_password';
CREATE DATABASE obelisk OWNER obelisk_api;
CREATE DATABASE powersync_storage OWNER powersync_storage;
SQL

psql \
  --set=ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname obelisk <<'SQL'
GRANT CONNECT ON DATABASE obelisk TO powersync_role;
GRANT USAGE ON SCHEMA public TO powersync_role;
ALTER DEFAULT PRIVILEGES FOR ROLE obelisk_api IN SCHEMA public
  GRANT SELECT ON TABLES TO powersync_role;
SQL

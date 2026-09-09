#!/bin/bash
# DESTRUCTIVE: DROP SCHEMA public on UA+WFE DBs and reset ism
set -euo pipefail
JRE="${IDM_JRE_HOME:-/opt/netiq/common/jre}"
PGJAR=$(ls /opt/netiq/idm/apps/tomcat/lib/postgresql-*.jar | head -1)
PG_HOST="${PG_HOST:?PG_HOST required}"
UA_USER="${UA_WFE_DATABASE_USER:-idmadmin}"
: "${UA_WFE_DATABASE_PWD:?}"
SHARED="${SHARED_CONFIG:-/config}"
LIB="${LIFECYCLE_LIB:-/lifecycle/lib/idm-lifecycle-lib.jar}"
"${JRE}/bin/java" -cp "${LIB}:${PGJAR}" Wipe "$PG_HOST" "$UA_USER" "$UA_WFE_DATABASE_PWD"
ISM="${SHARED}/userapp/tomcat/conf/ism-configuration.properties"
mkdir -p "$(dirname "$ISM")"
[ -f "$ISM" ] && cp -a "$ISM" "${ISM}.bak-wipe-$(date +%Y%m%d%H%M%S)"
: > "$ISM"
rm -f "${SHARED}/userapp/tomcat/conf/encrypt-keys.pkcs12" || true
echo "ism reset + encrypt-keys cleared (DESTRUCTIVE)"

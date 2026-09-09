#!/bin/bash
# Job 00: prereqs — LDAP, Postgres, NFS openssl, keystore secret sanity
# Image: identityapplication. Helpers: /lifecycle/lib (precompiled jar).
set -euo pipefail

ENGINE_HOST="${ENGINE_HOST:?ENGINE_HOST required}"
ENGINE_IP="${ENGINE_IP:?ENGINE_IP required}"
PG_HOST="${PG_HOST:?PG_HOST required}"
PG_PORT="${PG_PORT:-5432}"
SHARED="${SHARED_CONFIG:-/config}"
VAULT_ADMIN_DN="${VAULT_ADMIN_DN:-cn=admin,ou=sa,o=system}"
UA_USER="${UA_WFE_DATABASE_USER:-idmadmin}"
UA_DB="${UA_DATABASE_NAME:-idmuserappdb}"
WFE_DB="${WFE_DATABASE_NAME:-igaworkflowdb}"
JRE="${IDM_JRE_HOME:-/opt/netiq/common/jre}"
LIB="${LIFECYCLE_LIB:-/lifecycle/lib/idm-lifecycle-lib.jar}"
PGJAR=$(ls /opt/netiq/idm/apps/tomcat/lib/postgresql-*.jar 2>/dev/null | head -1 || true)

echo "== idm-lifecycle prereqs =="
echo "engine=${ENGINE_HOST} (${ENGINE_IP}) pg=${PG_HOST}:${PG_PORT}"

: "${ID_VAULT_PASSWORD:?ID_VAULT_PASSWORD required}"
: "${UA_WFE_DATABASE_PWD:?UA_WFE_DATABASE_PWD required}"
: "${JRE:?IDM_JRE_HOME/JRE required}"

echo "-- LDAP StartTLS bind --"
if command -v ldapsearch >/dev/null 2>&1; then
  LDAPTLS_REQCERT=never ldapsearch -x -Z -H "ldap://${ENGINE_IP}:389" \
    -D "${VAULT_ADMIN_DN}" -w "${ID_VAULT_PASSWORD}" \
    -b "o=system" -s base '(objectClass=*)' dn >/dev/null
  echo "LDAP OK (ldapsearch)"
else
  test -f "$LIB"
  "${JRE}/bin/java" -cp "${LIB}" LdapCheck "ldap://${ENGINE_IP}:389" "${VAULT_ADMIN_DN}" "${ID_VAULT_PASSWORD}"
fi

echo "-- Postgres --"
if command -v psql >/dev/null 2>&1; then
  export PGPASSWORD="${UA_WFE_DATABASE_PWD}"
  psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${UA_USER}" -d postgres -v ON_ERROR_STOP=1 -c \
    "SELECT datname FROM pg_database WHERE datname IN ('${UA_DB}','${WFE_DB}') ORDER BY 1;"
else
  : "${PGJAR:?postgresql jdbc jar required under tomcat/lib}"
  test -f "$LIB"
  "${JRE}/bin/java" -cp "${LIB}:${PGJAR}" PgCheck \
    "jdbc:postgresql://${PG_HOST}:${PG_PORT}/postgres" "${UA_USER}" "${UA_WFE_DATABASE_PWD}"
fi
echo "Postgres reachable"

echo "-- NFS shared config --"
mkdir -p "${SHARED}/bin" "${SHARED}/userapp/tomcat/conf" "${SHARED}/certificates"
if ! command -v openssl >/dev/null 2>&1 && [ ! -x "${SHARED}/bin/openssl" ]; then
  echo "WARN: install host openssl into ${SHARED}/bin/openssl (workaround for OSP/UA images)" >&2
fi
if [ -x "${SHARED}/bin/openssl" ]; then
  "${SHARED}/bin/openssl" version
elif command -v openssl >/dev/null 2>&1; then
  openssl version
fi

echo "-- Keystore secret must not be literal \$COMMON_KEYSTORE_PWD --"
if [ "${MASTER_KEYSTORE_PWD:-}" = '$COMMON_KEYSTORE_PWD' ] || [ -z "${MASTER_KEYSTORE_PWD:-}${COMMON_KEYSTORE_PWD:-}" ]; then
  echo "ERROR: MASTER_KEYSTORE_PWD / COMMON_KEYSTORE_PWD not expanded from keystore secret" >&2
  exit 1
fi
echo "Keystore pwd present (len=${#COMMON_KEYSTORE_PWD})"
echo "PREREQS OK"

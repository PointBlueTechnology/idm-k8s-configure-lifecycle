#!/bin/bash
# Job 01: Liquibase for UA + workflow DBs (mirrors ua_configure.sh)
set -euo pipefail

PG_HOST="${PG_HOST:?PG_HOST required}"
PG_PORT="${PG_PORT:-5432}"
UA_DB="${UA_DATABASE_NAME:-idmuserappdb}"
WFE_DB="${WFE_DATABASE_NAME:-igaworkflowdb}"
UA_USER="${UA_WFE_DATABASE_USER:-idmadmin}"
: "${UA_WFE_DATABASE_PWD:?UA_WFE_DATABASE_PWD required}"

JRE="${IDM_JRE_HOME:-/opt/netiq/common/jre}"
UA_HOME="${UA_HOME:-/opt/netiq/idm/apps/UserApplication}"
WFE_HOME="${WFE_HOME:-/opt/netiq/idm/apps/UserApplicationWorkflow}"
TOMCAT_LIB="${TOMCAT_LIB:-/opt/netiq/idm/apps/tomcat/lib}"
LIB="${LIFECYCLE_LIB:-/lifecycle/lib/idm-lifecycle-lib.jar}"
PGJAR=$(ls "${TOMCAT_LIB}"/postgresql-*.jar 2>/dev/null | head -1)
: "${PGJAR:?postgresql jdbc jar not found in ${TOMCAT_LIB}}"

DRIVER_DN="${UA_DRIVER_DN:-cn=User Application Driver,cn=driverset1,o=system}"
USER_CONTAINER="${USER_CONTAINER:-o=data}"
WAR_CTX="${UA_APP_CTX:-IDMProv}"
WFE_CTX="${WFE_APP_CTX:-workflow}"
CONTEXTS="${LIQUIBASE_CONTEXTS:-prov,newdb,updatedb}"

count_tables() {
  "${JRE}/bin/java" -cp "${LIB}:${PGJAR}" PgCount \
    "jdbc:postgresql://${PG_HOST}:${PG_PORT}/$1" "$UA_USER" "${UA_WFE_DATABASE_PWD}"
}

echo "== UA schema (before=$(count_tables "$UA_DB")) =="
test -d "${UA_HOME}/IDMdb"
test -d "${UA_HOME}/liquibase/lib"

cd "${UA_HOME}"
"${JRE}/bin/java" \
  -Dwar.context.name="${WAR_CTX}" \
  -Ddriver.dn="${DRIVER_DN}" \
  -Duser.container="${USER_CONTAINER}" \
  -cp "${UA_HOME}/IDMdb/*:${PGJAR}:${UA_HOME}/*:${UA_HOME}/liquibase/lib/*" \
  liquibase.integration.commandline.LiquibaseCommandLine \
  --databaseClass=liquibase.database.core.PostgresDatabase \
  --driver=org.postgresql.Driver \
  --changeLogFile=DatabaseChangeLog.xml \
  --url="jdbc:postgresql://${PG_HOST}:${PG_PORT}/${UA_DB}?compatible=true" \
  --contexts="${CONTEXTS}" \
  --logLevel=info \
  --username="${UA_USER}" \
  --password="${UA_WFE_DATABASE_PWD}" \
  update

echo "== WFE schema (before=$(count_tables "$WFE_DB")) =="
test -d "${WFE_HOME}/IDMwfdb"

cd "${UA_HOME}"
"${JRE}/bin/java" \
  -Dwar.context.name="${WFE_CTX}" \
  -Ddriver.dn="${DRIVER_DN}" \
  -Duser.container="${USER_CONTAINER}" \
  -cp "${WFE_HOME}/IDMwfdb/*:${PGJAR}:${UA_HOME}/*:${UA_HOME}/liquibase/lib/*" \
  liquibase.integration.commandline.LiquibaseCommandLine \
  --databaseClass=liquibase.database.core.PostgresDatabase \
  --driver=org.postgresql.Driver \
  --changeLogFile=DatabaseChangeLog.xml \
  --url="jdbc:postgresql://${PG_HOST}:${PG_PORT}/${WFE_DB}?compatible=true" \
  --contexts="${CONTEXTS}" \
  --logLevel=info \
  --username="${UA_USER}" \
  --password="${UA_WFE_DATABASE_PWD}" \
  update

UA_N=$(count_tables "$UA_DB")
WFE_N=$(count_tables "$WFE_DB")
echo "UA public tables=${UA_N} WFE public tables=${WFE_N}"
"${JRE}/bin/java" -cp "${LIB}:${PGJAR}" PgAssert \
  "jdbc:postgresql://${PG_HOST}:${PG_PORT}/${UA_DB}" "$UA_USER" "${UA_WFE_DATABASE_PWD}" securitypermissionmeta
test "${UA_N}" -gt 50
test "${WFE_N}" -gt 10
echo "SCHEMA OK (securitypermissionmeta present, UA tables=${UA_N}, WFE tables=${WFE_N})"

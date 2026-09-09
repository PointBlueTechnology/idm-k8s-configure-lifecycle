#!/bin/bash
# Job 02: RunConfigUpdate from full vendor template + seed authprops
# Scale UA deployment to 0 so Tomcat is not writing ism concurrently.
set -euo pipefail

SHARED="${SHARED_CONFIG:-/config}"
ISM="${SHARED}/userapp/tomcat/conf/ism-configuration.properties"
TMPL="${TMPL:-/lifecycle/configupdate.properties.tmpl}"
OUT=/tmp/configupdate.properties
JRE="${IDM_JRE_HOME:-/opt/netiq/common/jre}"
CU=/opt/netiq/idm/apps/configupdate
KS="${SHARED}/userapp/tomcat/conf/encrypt-keys.pkcs12"
[ -f "$KS" ] || KS=/opt/netiq/idm/apps/tomcat/conf/encrypt-keys.pkcs12
PG_HOST="${PG_HOST:?PG_HOST required}"
PG_PORT="${PG_PORT:-5432}"
UA_DB="${UA_DATABASE_NAME:-idmuserappdb}"
UA_USER="${UA_WFE_DATABASE_USER:-idmadmin}"
PGJAR=$(ls /opt/netiq/idm/apps/tomcat/lib/postgresql-*.jar 2>/dev/null | head -1)

: "${ID_VAULT_PASSWORD:?}"
: "${COMMON_KEYSTORE_PWD:?}"
: "${SSO_SERVICE_PWD:?}"
: "${UA_ADMIN_PWD:?}"
: "${UA_WFE_DATABASE_PWD:?}"

EXT_HOST="${EXT_HOST:?EXT_HOST / PUBLIC_HOST required}"
ENGINE_HOST="${ENGINE_HOST:?ENGINE_HOST required}"
UA_DRIVER_CN="${UA_DRIVER_CN:-User Application Driver}"
VAULT_ADMIN_DN="${VAULT_ADMIN_DN:-cn=admin,ou=sa,o=system}"
UA_ADMIN_DN="${UA_ADMIN_DN:-cn=uaadmin,ou=sa,o=data}"
DRIVERSET_DN="${DRIVERSET_DN:-cn=driverset1,o=system}"
USER_ROOT="${USER_ROOT_CONTAINER:-ou=users,o=data}"
GROUP_ROOT="${GROUP_ROOT_CONTAINER:-ou=groups,o=data}"
ROOT_CONTAINER="${USER_CONTAINER:-o=data}"
ADMIN_CONTAINER="${ADMIN_CONTAINER:-ou=sa,o=data}"
LDAP_PORT="${LDAP_PORT:-389}"
LDAPS_PORT="${LDAPS_PORT:-636}"

cp "$TMPL" "$OUT"
repl() { sed -i "s|$1|$2|g" "$OUT"; }

# Ensure ldap.admin lines are active (vendor ships commented)
sed -i 's/^#com.novell.idm.ldap.admin.user/com.novell.idm.ldap.admin.user/' "$OUT"
sed -i 's/^#com.novell.idm.ldap.admin.pass._attr_obscurity/com.novell.idm.ldap.admin.pass._attr_obscurity/' "$OUT"
sed -i 's/^#com.novell.idm.ldap.admin.pass /com.novell.idm.ldap.admin.pass /' "$OUT"
# Lab-safe: plaintext ldap.admin.pass under NONE (authprops also seeded)
sed -i 's|^\(com.novell.idm.ldap.admin.pass._attr_obscurity[[:space:]]*=[[:space:]]*\)ENCRYPT|\1NONE|' "$OUT"

repl '___UA_IP___' "${EXT_HOST}"
repl '___SSPR_IP___' "${EXT_HOST}"
repl '___RPT_IP___' "${EXT_HOST}"
repl '___ID_VAULT_HOST___' "${ENGINE_HOST}"
repl '___ID_VAULT_ADMIN___' "${VAULT_ADMIN_DN}"
repl '___ID_VAULT_PASSWORD___' "${ID_VAULT_PASSWORD}"
repl '___IDM_KEYSTORE_PATH___' "${SHARED}/userapp/tomcat/conf/idm.jks"
repl '___IDM_KEYSTORE_PWD___' "${COMMON_KEYSTORE_PWD}"
repl '___OSP_JKS_KEY_PWD___' "${COMMON_KEYSTORE_PWD}"
repl '___OSP_JKS_PWD___' "${COMMON_KEYSTORE_PWD}"
repl '___UA_ADMIN___' "${UA_ADMIN_DN}"
repl '___UA_DRIVER_NAME___' "${UA_DRIVER_CN}"
repl '___DRIVERSET_NAME___' "${DRIVERSET_DN}"
repl '___SSO_SERVICE_PWD___' "${SSO_SERVICE_PWD}"
repl '___ID_VAULT_LDAP_PORT___' "${LDAP_PORT}"
repl '___ID_VAULT_LDAPS_PORT___' "${LDAPS_PORT}"
repl '__OSP_TOMCAT_HOST__' '/opt/netiq/idm/apps/tomcat'
repl '__SSL_KEYSTORE_PASS__' "${COMMON_KEYSTORE_PWD}"
repl '__OSP_SSL_KEYSTORE_PASS__' "${COMMON_KEYSTORE_PWD}"
repl '___USER_ROOT_CONTAINER___' "${USER_ROOT}"
repl '___GROUP_ROOT_CONTAINER___' "${GROUP_ROOT}"
repl '___ROOT_CONTAINER____' "${ROOT_CONTAINER}"
repl '___ADMIN_CONTAINER___' "${ADMIN_CONTAINER}"
# Strip empty port tokens for single-domain ingress (no :port on public URLs)
sed -i -E 's|:___UA_TOMCAT_HTTPS_PORT___||g; s|:___OSP_TOMCAT_HTTPS_PORT___||g; s|:___SSPR_TOMCAT_HTTPS_PORT___||g; s|:___RPT_TOMCAT_HTTPS_PORT___||g' "$OUT"
sed -i -E 's|___UA_TOMCAT_HTTPS_PORT___||g; s|___OSP_TOMCAT_HTTPS_PORT___||g; s|___SSPR_TOMCAT_HTTPS_PORT___||g; s|___RPT_TOMCAT_HTTPS_PORT___||g' "$OUT"

if grep -qE '___|__OSP_|__SSL_' "$OUT"; then
  echo "ERROR: unresolved placeholders:" >&2
  grep -E '___|__OSP_|__SSL_' "$OUT" | head -20 >&2
  exit 1
fi

mkdir -p "$(dirname "$ISM")"
# Cold path: empty ism so ConfigUpdate rebuilds cleanly
if [ "${RESET_ISM:-1}" = "1" ]; then
  if [ -f "$ISM" ] && [ -s "$ISM" ]; then
    cp -a "$ISM" "${ISM}.bak-pre-configupdate-$(date +%Y%m%d%H%M%S)"
  fi
  : > "$ISM"
else
  touch "$ISM"
fi

# Cold ism has no master key — create one before RunConfigUpdate
ISM_DIR="$(dirname "$ISM")"
"${JRE}/bin/java" -cp "${CU}/*:${UA_HOME:-/opt/netiq/idm/apps/UserApplication}/liquibase/lib/*"   com.sssw.fw.util.crypto.SensitiveDataManagement -newmaster "${ISM_DIR}" "$(basename "$ISM")" || true
# Vault AppConfig already exists from Engine/driver install — do not auto-regen SSO PKCS12
sed -i 's/com.netiq.idm.ua.sso-configuration=auto/com.netiq.idm.ua.sso-configuration=NoChange/' "$OUT"
sed -i 's/com.netiq.idm.ua.sso-configuration = auto/com.netiq.idm.ua.sso-configuration=NoChange/' "$OUT"

# idm.jks lives on shared volume (not in image layer)
IDM_JKS="${SHARED}/userapp/tomcat/conf/idm.jks"
test -f "$IDM_JKS"
mkdir -p /opt/netiq/idm/apps/tomcat/conf
ln -sfn "$IDM_JKS" /opt/netiq/idm/apps/tomcat/conf/idm.jks
if [ -f "${SHARED}/userapp/tomcat/conf/tomcat.ks" ]; then
  ln -sfn "${SHARED}/userapp/tomcat/conf/tomcat.ks" /opt/netiq/idm/apps/tomcat/conf/tomcat.ks
fi

cd "$CU"
"${JRE}/bin/java" --add-exports java.base/sun.security.tools.keytool=ALL-UNNAMED \
  -cp "${CU}/*" com.netiq.installer.configupdate.RunConfigUpdate \
  "$OUT" "${UA_APP_CTX:-IDMProv}" "${COMMON_KEYSTORE_PWD}" \
  "$IDM_JKS" "$ISM"

# Persist encrypt-keys next to ism (CU may write under image tomcat/conf)
for cand in     /opt/netiq/idm/apps/tomcat/conf/encrypt-keys.pkcs12     "$(dirname "$ISM")/encrypt-keys.pkcs12"; do
  if [ -f "$cand" ] && [ "$cand" != "$(dirname "$ISM")/encrypt-keys.pkcs12" ]; then
    cp -a "$cand" "$(dirname "$ISM")/encrypt-keys.pkcs12"
    echo "copied encrypt-keys from $cand"
  fi
done
if [ ! -f "$(dirname "$ISM")/encrypt-keys.pkcs12" ]; then
  echo "WARN: encrypt-keys.pkcs12 missing on shared volume after ConfigUpdate" >&2
fi

LINES=$(wc -l < "$ISM")
echo "ism lines=${LINES}"
test "$LINES" -gt 100
grep -q 'com.novell.idm.ldap.admin.user' "$ISM"
grep -q 'DirectoryService/realms/jndi/params/AUTHORITY' "$ISM"
grep -q 'User Application Driver' "$ISM"

# Seed authprops (lab plaintext; production should use MasterKeyManager)
: "${PGJAR:?postgresql jdbc jar required to seed authprops}"
LIB="${LIFECYCLE_LIB:-/lifecycle/lib/idm-lifecycle-lib.jar}"
"${JRE}/bin/java" -cp "${LIB}:${PGJAR}" SeedAuth \
  "jdbc:postgresql://${PG_HOST}:${PG_PORT}/${UA_DB}" "${UA_USER}" "${UA_WFE_DATABASE_PWD}" \
  "${VAULT_ADMIN_DN}" "${ID_VAULT_PASSWORD}"

echo "CONFIGUPDATE OK"

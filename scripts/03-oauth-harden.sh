#!/bin/bash
# Job 03: force public OAuth redirects + ENCRYPT repair/audit
set -euo pipefail

SHARED="${SHARED_CONFIG:-/config}"
ISM="${SHARED}/userapp/tomcat/conf/ism-configuration.properties"
EXT="${EXT_URL:?EXT_URL / PUBLIC_BASE_URL required}"
KS="${SHARED}/userapp/tomcat/conf/encrypt-keys.pkcs12"
JRE="${IDM_JRE_HOME:-/opt/netiq/common/jre}"
CU=/opt/netiq/idm/apps/configupdate
UTIL=/idm/common/packages/utils/idm_install_utils.jar
VAULT_ADMIN_DN="${VAULT_ADMIN_DN:-cn=admin,ou=sa,o=system}"

: "${COMMON_KEYSTORE_PWD:?}"
: "${SSO_SERVICE_PWD:?}"
: "${ID_VAULT_PASSWORD:?}"

set_prop() {
  local key="$1" val="$2"
  sed -i "/^${key}[[:space:]]*=/d" "$ISM"
  echo "${key} = ${val}" >> "$ISM"
}

test -f "$ISM"
cp -a "$ISM" "${ISM}.bak-oauth-$(date +%Y%m%d%H%M%S)"

# Only accept encrypt-keys that CU wrote beside ism (or image tomcat/conf).
if [ ! -f "$KS" ] && [ -f /opt/netiq/idm/apps/tomcat/conf/encrypt-keys.pkcs12 ]; then
  cp -a /opt/netiq/idm/apps/tomcat/conf/encrypt-keys.pkcs12 "$KS"
fi

set_prop "com.netiq.idmdash.redirect.url" "${EXT}/idmdash/oauth.html"
set_prop "com.netiq.idmadmin.redirect.url" "${EXT}/idmadmin/oauth.html"
set_prop "com.netiq.rbpm.redirect.url" "${EXT}/IDMProv/oauth"
set_prop "com.netiq.sspr.redirect.url" "${EXT}/sspr/public/oauth"
set_prop "com.netiq.forms.redirect.url" "${EXT}/forms/oauth.html"
set_prop "com.netiq.rpt.rpt-web.redirect.url" "${EXT}/IDMRPT/oauth.html"
set_prop "com.netiq.idmdcs.redirect.url" "${EXT}/idmdcs/oauth.html"
set_prop "com.netiq.ualanding.redirect.url" "${EXT}/landing/com.netiq.ualanding.index/oauth.html"
set_prop "com.netiq.rpt.redirect.url" "${EXT}/IDMRPT/oauth.html"
set_prop "com.netiq.idm.osp.url.host" "${EXT}"
set_prop "com.netiq.client.authserver.url.authorize" "${EXT}/osp/a/idm/auth/oauth2/grant"
set_prop "com.netiq.client.authserver.url.token" "${EXT}/osp/a/idm/auth/oauth2/getattributes"
set_prop "com.netiq.client.authserver.url.logout" "${EXT}/osp/a/idm/auth/app/logout"
set_prop "com.netiq.client.authserver.url.revoke" "${EXT}/osp/a/idm/auth/oauth2/revoke"
set_prop "com.netiq.idm.osp.oauth.issuer" "${EXT}/osp/a/idm/auth/oauth2"
set_prop "com.microfocus.idm.application.url" "${EXT}/IDMProv"
set_prop "com.netiq.idm.forms.url.host" "${EXT}"
set_prop "com.netiq.wf.engine.url" "${EXT}/workflow"

if grep -E 'redirect.url|osp.url.host' "$ISM" | grep -q identityapplications; then
  echo "ERROR: in-cluster hostname still present in redirects" >&2
  exit 1
fi

can_decrypt() {
  local val="$1"
  [ -f "$KS" ] || return 1
  out=$("${JRE}/bin/java" -cp "${UTIL}:${CU}/*" com.netiq.installer.utils.CryptUtil decrypt "$val" \
    -keystore "$KS" -storepass "$COMMON_KEYSTORE_PWD" -keypass "$COMMON_KEYSTORE_PWD" 2>/dev/null || true)
  [ -n "$out" ] && [ "${#out}" -lt 200 ]
}

force_none() {
  local key="$1" val="$2"
  set_prop "$key" "$val"
  set_prop "${key}._attr_obscurity" "NONE"
}

echo "-- ENCRYPT repair (force known secrets to NONE plaintext when encrypt-keys may be missing) --"
force_none "com.netiq.idmdash.clientPass" "${SSO_SERVICE_PWD}"
force_none "com.netiq.idmadmin.clientPass" "${SSO_SERVICE_PWD}"
force_none "com.netiq.rbpm.clientPass" "${SSO_SERVICE_PWD}"
force_none "com.netiq.rbpmrest.clientPass" "${SSO_SERVICE_PWD}"
force_none "com.netiq.sspr.clientPass" "${SSO_SERVICE_PWD}"
force_none "com.netiq.forms.clientPass" "${SSO_SERVICE_PWD}"
force_none "com.netiq.idmdcs.clientPass" "${SSO_SERVICE_PWD}"
force_none "com.netiq.dcsdrv.clientPass" "${SSO_SERVICE_PWD}"
force_none "com.netiq.rpt.clientPass" "${SSO_SERVICE_PWD}"
force_none "com.netiq.idmengine.clientPass" "${SSO_SERVICE_PWD}"
force_none "com.novell.idm.ldap.admin.pass" "${ID_VAULT_PASSWORD}"
force_none "com.netiq.idm.osp.ldap.admin-pwd" "${ID_VAULT_PASSWORD}"
force_none "com.netiq.idm.ua.ldap.keystore-pwd" "${COMMON_KEYSTORE_PWD}"
force_none "com.netiq.idm.osp.oauth-keystore.pwd" "${COMMON_KEYSTORE_PWD}"
force_none "com.netiq.idm.osp.oauth-key.pwd" "${COMMON_KEYSTORE_PWD}"
force_none "com.netiq.idm.osp.ssl-keystore.pwd" "${COMMON_KEYSTORE_PWD}"
set_prop "com.novell.idm.ldap.admin.user" "${VAULT_ADMIN_DN}"

echo "-- ENCRYPT audit remaining --"
CHECKED=0
for key in $(grep -E '\._attr_obscurity[[:space:]]*=[[:space:]]*ENCRYPT' "$ISM" | sed 's/\._attr_obscurity.*//' | sed 's/[[:space:]]*$//' | sort -u); do
  val=$(grep -E "^${key}[[:space:]]*=" "$ISM" | tail -1 | sed 's/^[^=]*=[[:space:]]*//' || true)
  [ -n "$val" ] || continue
  CHECKED=$((CHECKED+1))
  if ! can_decrypt "$val"; then
    echo "WARN: undecryptable ENCRYPT remnant: $key (setting NONE empty)" >&2
    set_prop "${key}._attr_obscurity" "NONE"
  fi
done
echo "ENCRYPT remnant checked=${CHECKED}"
echo "OAUTH HARDEN OK"

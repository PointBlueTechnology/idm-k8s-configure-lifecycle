#!/usr/bin/env bash
# Render Job/RBAC manifests from manifests/templates using config/site.env
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="${SITE_ENV:-$ROOT/config/site.env}"
OUT="${RENDER_OUT:-$ROOT/manifests/rendered}"

if [ ! -f "$SITE" ]; then
  echo "ERROR: missing $SITE — copy config/site.env.example to config/site.env and fill values" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
# strip comments/blank for sourcing
# shellcheck source=/dev/null
source "$SITE"
set +a

: "${NAMESPACE:?}"
: "${LIFECYCLE_NAME:?}"
: "${PUBLIC_HOST:?}"
: "${PUBLIC_BASE_URL:?}"
: "${ENGINE_HOST:?}"
: "${ENGINE_IP:?}"
: "${PG_HOST:?}"
: "${SHARED_PVC_NAME:?}"
: "${IMAGE_UA:?}"
: "${UA_DEPLOYMENT_NAME:?}"
: "${COMMON_PASSWORD_SECRET:?}"
: "${KEYSTORE_SECRET:?}"

# Defaults for optional knobs
export PG_PORT="${PG_PORT:-5432}"
export INGRESS_IP="${INGRESS_IP:-}"
export IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-IfNotPresent}"
export SMOKE_IMAGE="${SMOKE_IMAGE:-curlimages/curl:8.5.0}"
export SHARED_CONFIG="${SHARED_CONFIG:-/config}"
export LIFECYCLE_LIB="${LIFECYCLE_LIB:-/lifecycle/lib/idm-lifecycle-lib.jar}"
export COMMON_PASSWORD_KEY="${COMMON_PASSWORD_KEY:-password}"
export KEYSTORE_SECRET_KEY="${KEYSTORE_SECRET_KEY:-keystore-pwd}"
export VAULT_ADMIN_DN="${VAULT_ADMIN_DN:-cn=admin,ou=sa,o=system}"
export UA_ADMIN_DN="${UA_ADMIN_DN:-cn=uaadmin,ou=sa,o=data}"
export UA_DRIVER_DN="${UA_DRIVER_DN:-cn=User Application Driver,cn=driverset1,o=system}"
export UA_DRIVER_CN="${UA_DRIVER_CN:-User Application Driver}"
export DRIVERSET_DN="${DRIVERSET_DN:-cn=driverset1,o=system}"
export USER_CONTAINER="${USER_CONTAINER:-o=data}"
export USER_ROOT_CONTAINER="${USER_ROOT_CONTAINER:-ou=users,o=data}"
export GROUP_ROOT_CONTAINER="${GROUP_ROOT_CONTAINER:-ou=groups,o=data}"
export ADMIN_CONTAINER="${ADMIN_CONTAINER:-ou=sa,o=data}"
export LDAP_PORT="${LDAP_PORT:-389}"
export LDAPS_PORT="${LDAPS_PORT:-636}"
export UA_DB_NAME="${UA_DB_NAME:-idmuserappdb}"
export WFE_DB_NAME="${WFE_DB_NAME:-igaworkflowdb}"
export UA_WFE_DATABASE_USER="${UA_WFE_DATABASE_USER:-idmadmin}"
export UA_APP_CTX="${UA_APP_CTX:-IDMProv}"
export FORMRENDERER_CONFIG_DIR="${FORMRENDERER_CONFIG_DIR:-/config/FormRenderer}"
export WFE_APP_CTX="${WFE_APP_CTX:-workflow}"
export LIQUIBASE_CONTEXTS="${LIQUIBASE_CONTEXTS:-prov,newdb,updatedb}"
export RESET_ISM="${RESET_ISM:-1}"

mkdir -p "$OUT"
VARS='$NAMESPACE $LIFECYCLE_NAME $PUBLIC_HOST $PUBLIC_BASE_URL $INGRESS_IP $ENGINE_HOST $ENGINE_IP $PG_HOST $PG_PORT $SHARED_PVC_NAME $UA_DEPLOYMENT_NAME $IMAGE_UA $IMAGE_PULL_POLICY $SMOKE_IMAGE $COMMON_PASSWORD_SECRET $COMMON_PASSWORD_KEY $KEYSTORE_SECRET $KEYSTORE_SECRET_KEY $SHARED_CONFIG $LIFECYCLE_LIB $VAULT_ADMIN_DN $UA_ADMIN_DN $UA_DRIVER_DN $UA_DRIVER_CN $DRIVERSET_DN $USER_CONTAINER $USER_ROOT_CONTAINER $GROUP_ROOT_CONTAINER $ADMIN_CONTAINER $LDAP_PORT $LDAPS_PORT $UA_DB_NAME $WFE_DB_NAME $UA_WFE_DATABASE_USER $UA_APP_CTX $WFE_APP_CTX $LIQUIBASE_CONTEXTS $RESET_ISM $FORMRENDERER_CONFIG_DIR'

for f in "$ROOT"/manifests/templates/*.yaml; do
  base="$(basename "$f")"
  envsubst "$VARS" < "$f" > "$OUT/$base"
done

echo "Rendered manifests → $OUT"
ls -1 "$OUT"

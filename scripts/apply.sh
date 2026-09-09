#!/usr/bin/env bash
# Operator wrapper for idm-lifecycle Jobs.
# Requires: config/site.env, kubectl context, pre-existing Helm IDM apps + secrets + RWX PVC.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="${SITE_ENV:-$ROOT/config/site.env}"
KUBECTL="${KUBECTL:-kubectl}"
DRY_RUN=0
STAGE=""

usage() {
  cat <<USAGE
Usage: $0 [--dry-run] (--prereqs|--schema|--configupdate|--oauth|--smoke|--all|--reset-prepare|--render-only)

  --dry-run         Print plan / client-validate manifests; do not wait on Jobs
  --render-only     Only run scripts/render.sh
  --prereqs         Job 00 only
  --schema          Job 01 only (scale UA 0 yourself first, or use --all)
  --configupdate    Job 02 only
  --oauth           Job 03 only
  --smoke           Job 04 only
  --reset-prepare   Scale UA 0, wipe UA/WFE public schemas, reset ism (keeps Engine)
  --all             prereqs → reset-prepare → schema → configupdate → oauth → scale UA 1 → smoke

Requires config/site.env (see config/site.env.example).

WARNING: --all / --reset-prepare mutate shared-volume ism and Postgres UA/WFE schemas.
Backup NFS ism + pg_dump both DBs before running.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --prereqs|--schema|--configupdate|--oauth|--smoke|--all|--reset-prepare|--render-only)
      STAGE="${1#--}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
[ -n "$STAGE" ] || { usage; exit 1; }

if [ ! -f "$SITE" ]; then
  echo "ERROR: missing $SITE — copy config/site.env.example and fill values" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$SITE"
set +a

NS="${NAMESPACE:?NAMESPACE required in site.env}"
LC="${LIFECYCLE_NAME:?LIFECYCLE_NAME required}"
UA_DEPLOY="${UA_DEPLOYMENT_NAME:-identityapplications}"
RENDERED="$ROOT/manifests/rendered"

render() {
  SITE_ENV="$SITE" RENDER_OUT="$RENDERED" "$ROOT/scripts/render.sh"
}

ensure_scripts_cm() {
  echo "Building ConfigMap ${LC}-scripts from $ROOT"
  local apply_cmd=(apply)
  if [ "$DRY_RUN" = 1 ]; then apply_cmd=(apply --dry-run=client); fi
  $KUBECTL -n "$NS" create configmap "${LC}-scripts" \
    --from-file="$ROOT/scripts/00-prereqs.sh" \
    --from-file="$ROOT/scripts/01-ua-schema.sh" \
    --from-file="$ROOT/scripts/02-configupdate.sh" \
    --from-file="$ROOT/scripts/03-oauth-harden.sh" \
    --from-file="$ROOT/scripts/04-smoke.sh" \
    --from-file="$ROOT/scripts/99-wipe-schema.sh" \
    --from-file=configupdate.properties.tmpl="$ROOT/templates/configupdate.properties.tmpl" \
    --dry-run=client -o yaml | $KUBECTL "${apply_cmd[@]}" -f -
  echo "Building ConfigMap ${LC}-lib"
  $KUBECTL -n "$NS" create configmap "${LC}-lib" \
    --from-file=idm-lifecycle-lib.jar="$ROOT/scripts/lib/idm-lifecycle-lib.jar" \
    --dry-run=client -o yaml | $KUBECTL "${apply_cmd[@]}" -f -
}

apply_rbac() {
  if [ "$DRY_RUN" = 1 ]; then
    $KUBECTL apply --dry-run=client -f "$RENDERED/rbac.yaml"
  else
    $KUBECTL apply -f "$RENDERED/rbac.yaml"
  fi
}

run_job() {
  local file="$1"
  local jname
  jname=$(awk '/^  name:/{print $2; exit}' "$file")
  echo "==== apply $jname (dry_run=$DRY_RUN) ===="
  if [ "$DRY_RUN" = 1 ]; then
    $KUBECTL apply --dry-run=client -f "$file"
    return 0
  fi
  $KUBECTL -n "$NS" delete job "$jname" --ignore-not-found
  $KUBECTL apply -f "$file"
  $KUBECTL -n "$NS" wait --for=condition=complete "job/$jname" --timeout=45m
  $KUBECTL -n "$NS" logs "job/$jname" --tail=80 || true
}

scale_ua() {
  local n="$1"
  echo "scale ${UA_DEPLOY} → $n"
  if [ "$DRY_RUN" = 1 ]; then
    echo "(dry-run) would scale deploy/${UA_DEPLOY} --replicas=$n"
    return 0
  fi
  $KUBECTL -n "$NS" scale "deploy/${UA_DEPLOY}" --replicas="$n"
  if [ "$n" != 0 ]; then
    $KUBECTL -n "$NS" rollout status "deploy/${UA_DEPLOY}" --timeout=600s
  else
    $KUBECTL -n "$NS" wait --for=delete pod -l "app.kubernetes.io/name=${UA_DEPLOY}" --timeout=180s 2>/dev/null \
      || $KUBECTL -n "$NS" wait --for=delete pod -l "app=${UA_DEPLOY}" --timeout=180s 2>/dev/null \
      || sleep 15
  fi
}

reset_prepare() {
  echo "==== reset-prepare (UA schema wipe + ism reset) — DESTRUCTIVE ===="
  if [ "$DRY_RUN" = 1 ]; then
    echo "(dry-run) would scale UA 0, DROP SCHEMA public CASCADE on UA/WFE DBs, empty ism"
    return 0
  fi
  scale_ua 0
  $KUBECTL -n "$NS" delete job "${LC}-wipe-schema" --ignore-not-found
  $KUBECTL apply -f "$RENDERED/wipe-schema.yaml"
  $KUBECTL -n "$NS" wait --for=condition=complete "job/${LC}-wipe-schema" --timeout=10m
  $KUBECTL -n "$NS" logs "job/${LC}-wipe-schema" --tail=50 || true
}

render
if [ "$STAGE" = "render-only" ]; then
  echo "DONE stage=render-only"
  exit 0
fi

ensure_scripts_cm
apply_rbac

case "$STAGE" in
  prereqs) run_job "$RENDERED/00-prereqs.yaml" ;;
  schema) run_job "$RENDERED/01-ua-schema.yaml" ;;
  configupdate) run_job "$RENDERED/02-configupdate.yaml" ;;
  oauth) run_job "$RENDERED/03-oauth-harden.yaml" ;;
  smoke) run_job "$RENDERED/04-smoke.yaml" ;;
  reset-prepare) reset_prepare ;;
  all)
    run_job "$RENDERED/00-prereqs.yaml"
    reset_prepare
    run_job "$RENDERED/01-ua-schema.yaml"
    run_job "$RENDERED/02-configupdate.yaml"
    run_job "$RENDERED/03-oauth-harden.yaml"
    scale_ua 1
    if [ "$DRY_RUN" = 0 ]; then sleep 45; fi
    run_job "$RENDERED/04-smoke.yaml"
    ;;
esac

echo "DONE stage=$STAGE dry_run=$DRY_RUN"

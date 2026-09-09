#!/bin/sh
# Job 04: HTTP smoke via ingress IP (POSIX sh — curl image has no bash)
set -eu

HOST="${EXT_HOST:?EXT_HOST / PUBLIC_HOST required}"
IP="${INGRESS_IP:?INGRESS_IP required}"

check() {
  path="$1"
  expect="$2"
  code=$(curl -sk -o /tmp/smoke.out -w '%{http_code}' \
    --resolve "${HOST}:443:${IP}" "https://${HOST}${path}" || true)
  echo "$code $path"
  echo ",$expect," | grep -q ",$code," || {
    echo "ERROR: expected one of [$expect] for $path, got $code" >&2
    exit 1
  }
}

echo "== smoke ${HOST} -> ${IP} =="
check /osp/a/idm/auth/app/login 200
check /idmdash/ 200
check /IDMProv/ "302,301,200"
check /IDMProv/rest/access "401,302,200"
check /idmdash/oauth.html 200
echo "SMOKE OK"

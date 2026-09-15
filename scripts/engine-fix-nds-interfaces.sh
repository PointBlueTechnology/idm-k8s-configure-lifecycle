#!/usr/bin/env bash
# Strip FQDNs from eDirectory n4u/http/https.server.interfaces — IPs only.
# Run on the Engine Docker host after identityengine configure.
set -euo pipefail

CONTAINER="${CONTAINER:-engine-container}"
RESTART=0
KEEP_IPS=()
CONF_IN_CONTAINER="/etc/opt/novell/eDirectory/conf/nds.conf"

usage() {
  cat <<USAGE
Usage: $0 [--container NAME] [--keep-ip IP]... [--restart]

Removes non-IP entries (e.g. engine.example.com@524) from:
  n4u.server.interfaces, http.server.interfaces, https.server.interfaces

eDirectory logs "Incorrect interface parameter: <fqdn>" when a hostname is listed.
Designer Identity Vault (NCP 524) is more reliable after this fix — prefer Engine IP as server.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="$2"; shift 2 ;;
    --keep-ip) KEEP_IPS+=("$2"); shift 2 ;;
    --restart) RESTART=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

docker exec "$CONTAINER" test -f "$CONF_IN_CONTAINER"

docker exec "$CONTAINER" bash -lc "
set -euo pipefail
CONF='$CONF_IN_CONTAINER'
cp -a \"\$CONF\" \"\${CONF}.bak.\$(date +%Y%m%d%H%M%S)\"
python3 - <<'PY'
from pathlib import Path
import re
conf = Path('$CONF_IN_CONTAINER')
text = conf.read_text()
keys = {
    'n4u.server.interfaces',
    'http.server.interfaces',
    'https.server.interfaces',
}
ip_at = re.compile(r'^\\d{1,3}(?:\\.\\d{1,3}){3}@\\d+\$')
out_lines = []
for line in text.splitlines():
    if '=' not in line:
        out_lines.append(line)
        continue
    k, _, v = line.partition('=')
    if k.strip() not in keys:
        out_lines.append(line)
        continue
    kept = [tok.strip() for tok in v.split(',') if tok.strip() and ip_at.match(tok.strip())]
    if not kept:
        raise SystemExit(f'refusing to write empty interface list for {k}')
    out_lines.append(f\"{k}={\",\".join(kept)}\")
    print(f'fixed {k} -> {\",\".join(kept)}')
conf.write_text('\\n'.join(out_lines) + '\\n')
PY
"

for ip in "${KEEP_IPS[@]:-}"; do
  [[ -z "${ip:-}" ]] && continue
  docker exec "$CONTAINER" grep -E "[=,]${ip}@" "$CONF_IN_CONTAINER" >/dev/null \
    || { echo "ERROR: required IP $ip missing from interfaces after fix" >&2; exit 1; }
done

docker exec "$CONTAINER" bash -lc '
if [ -d /config/idm/eDirectory_conf ]; then
  cp -a '"$CONF_IN_CONTAINER"' /config/idm/eDirectory_conf/nds.conf.fixed-ips-only || true
fi
' || true

if [[ "$RESTART" -eq 1 ]]; then
  echo "Restarting $CONTAINER ..."
  docker restart "$CONTAINER"
  sleep 8
  docker inspect "$CONTAINER" --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}'
  if docker logs "$CONTAINER" --since 2m 2>&1 | grep -qi 'Incorrect interface'; then
    echo "WARN: still seeing Incorrect interface in recent logs" >&2
  else
    echo "OK: no Incorrect interface in last 2m"
  fi
fi

echo "Done. Designer: tree=<TREE from nds.conf>, server=<Engine IP>, port 524, user cn=admin,ou=sa,o=system"

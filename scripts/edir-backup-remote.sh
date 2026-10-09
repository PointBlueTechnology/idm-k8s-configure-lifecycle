#!/bin/bash
# Runs inside the Identity Vault container/host. Invoked by edir-backup.sh.
# Hot full backup via dsbk. NICI is included only when the 4th arg is true
# and NICI_BACKUP_PASSWORD is set in the environment (dsbk -e). Never echo it.
set -euo pipefail

usage() {
  echo "usage: edir-backup-remote.sh STAGING CONF INCLUDE_NICI INCLUDE_STREAMS INCLUDE_NDS_CONF DSBK_BIN" >&2
  exit 2
}

[ "$#" -eq 6 ] || usage

staging=$1
conf=$2
include_nici=$3
include_streams=$4
include_nds_conf=$5
dsbk_bin=$6

export PATH="/opt/novell/eDirectory/bin:/opt/novell/eDirectory/sbin:${PATH:-/usr/bin:/bin}"
umask 077

is_true() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

if [ ! -x "$dsbk_bin" ] && [ -x /opt/novell/eDirectory/bin/dsbk ]; then
  dsbk_bin=/opt/novell/eDirectory/bin/dsbk
fi
command -v "$dsbk_bin" >/dev/null 2>&1 || [ -x "$dsbk_bin" ] || {
  echo "ERROR: dsbk not found (looked for ${dsbk_bin} and /opt/novell/eDirectory/bin/dsbk)" >&2
  exit 1
}

rm -rf "$staging"
mkdir -p "$staging"
chmod 700 "$staging"

bak="${staging}/edir.bak"
log="${staging}/edir.log"
out="${staging}/edir.out"

args=(backup -b -f "$bak" -l "$log" -w --config-file "$conf")
if is_true "$include_streams"; then
  args+=(-t)
fi
if is_true "$include_nds_conf"; then
  # dsbk include-file format: absolute paths separated by ';', no spaces.
  printf '%s;' "$conf" > "${staging}/include.txt"
  args+=(-u "${staging}/include.txt")
fi
if is_true "$include_nici"; then
  if [ -z "${NICI_BACKUP_PASSWORD:-}" ]; then
    echo "ERROR: NICI backup requested but NICI_BACKUP_PASSWORD is empty in the vault process" >&2
    exit 1
  fi
  args+=(-e "$NICI_BACKUP_PASSWORD")
fi

redact_text() {
  local file=$1 pw=$2 tmp
  [ -n "$pw" ] || return 0
  [ -f "$file" ] || return 0
  command -v awk >/dev/null 2>&1 || return 0
  tmp=$(mktemp)
  NICI_BACKUP_PASSWORD="$pw" awk '
    BEGIN { pw = ENVIRON["NICI_BACKUP_PASSWORD"]; n = length(pw) }
    {
      line = $0
      out = ""
      while (n > 0 && (i = index(line, pw)) > 0) {
        out = out substr(line, 1, i - 1) "***REDACTED***"
        line = substr(line, i + n)
      }
      print out line
    }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

show_failure_log() {
  redact_text "$out" "${NICI_BACKUP_PASSWORD:-}"
  redact_text "$log" "${NICI_BACKUP_PASSWORD:-}"
  cat "$out" >&2 || true
}

set +e
"$dsbk_bin" "${args[@]}" >"$out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "ERROR: dsbk exited ${rc}" >&2
  show_failure_log
  exit "$rc"
fi
if [ ! -s "$bak" ]; then
  echo "ERROR: dsbk exited 0 but ${bak} is missing or empty" >&2
  show_failure_log
  exit 1
fi
redact_text "$log" "${NICI_BACKUP_PASSWORD:-}"
redact_text "$out" "${NICI_BACKUP_PASSWORD:-}"
chmod 600 "$bak" "$log" "$out" 2>/dev/null || true

for f in "$staging"/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  [ "$name" = "include.txt" ] && continue
  printf 'FILE %s\n' "$name"
done
printf 'DONE\n'

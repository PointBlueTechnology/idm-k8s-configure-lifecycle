#!/bin/bash
# Local checks for the eDirectory backup script. No vault, cluster, or secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/edir-backup.sh"
REMOTE="$ROOT/scripts/edir-backup-remote.sh"
# shellcheck disable=SC1090
source "$SCRIPT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- flag summary: NICI on by default, password never printed ---
export INCLUDE_NICI=true INCLUDE_STREAMS=true INCLUDE_NDS_CONF=true
export VAULT_NDS_CONF=/etc/opt/novell/eDirectory/conf/nds.conf
export NICI_BACKUP_PASSWORD='super-secret-nici'
summary=$(dsbk_flag_summary)
printf '%s\n' "$summary" | grep -q -- '-b' || fail "missing -b"
printf '%s\n' "$summary" | grep -q -- '-t' || fail "missing -t"
printf '%s\n' "$summary" | grep -q -- '-w' || fail "missing -w"
printf '%s\n' "$summary" | grep -q -- '-e' || fail "missing -e when includeNici true"
printf '%s\n' "$summary" | grep -q -- '-u' || fail "missing -u when nds.conf included"
printf '%s\n' "$summary" | grep -q 'super-secret-nici' && fail "password leaked into flag summary"

export INCLUDE_NICI=false
summary=$(dsbk_flag_summary)
printf '%s\n' "$summary" | grep -q -- '-e' && fail "-e present when includeNici false"
printf '%s\n' "$summary" | grep -q 'super-secret-nici' && fail "password leaked when nici off"

# --- dry-run stdout redacts the password and still shows the toggle ---
export INCLUDE_NICI=true VAULT_TARGET=dry-run
export EDIR_BACKUP_REMOTE_SCRIPT="$REMOTE"
dry=$("$SCRIPT")
printf '%s\n' "$dry" | grep -q 'dsbk-flags:.* -e' || fail "dry-run missing -e"
printf '%s\n' "$dry" | grep -q 'NICI_BACKUP_PASSWORD=(set, redacted)' || fail "dry-run missing redaction marker"
printf '%s\n' "$dry" | grep -q 'super-secret-nici' && fail "dry-run printed the NICI password"
printf '%s\n' "$dry" | grep -q -- '--config-file /etc/opt/novell/eDirectory/conf/nds.conf' || fail "dry-run missing nds.conf"
# shellcheck disable=SC2016 # the remote script must contain this literal
printf '%s\n' "$dry" | grep -q 'args+=(-e "$NICI_BACKUP_PASSWORD")' || fail "remote script missing -e argv"

export INCLUDE_NICI=false
dry=$("$SCRIPT")
printf '%s\n' "$dry" | grep -q 'NICI_BACKUP_PASSWORD=(unset)' || fail "dry-run should unset NICI when disabled"
printf '%s\n' "$dry" | grep '^dsbk-flags:' | grep -q -- '-e' && fail "dry-run flags include -e when disabled"

# includeNici true with empty password must fail before any backup
export INCLUDE_NICI=true NICI_BACKUP_PASSWORD=
if "$SCRIPT" >/dev/null 2>"$tmp/err"; then
  fail "empty NICI password should fail"
fi
grep -q 'NICI_BACKUP_PASSWORD is empty' "$tmp/err" || fail "expected empty-password error"

# nds user cannot take a NICI backup
export NICI_BACKUP_PASSWORD=secret VAULT_EXEC_USER=nds
if "$SCRIPT" >/dev/null 2>"$tmp/err"; then
  fail "nds user should be rejected when includeNici is true"
fi
grep -q 'not as user nds' "$tmp/err" || fail "expected nds rejection"

# --- retention keeps newest N .bak sets and their sidecars ---
export VAULT_EXEC_USER=
dest=$tmp/backups
mkdir -p "$dest"
i=0
for stamp in 20260101T000000Z 20260102T000000Z 20260103T000000Z; do
  i=$((i + 1))
  printf 'bak%s' "$i" > "${dest}/edir-${stamp}.bak"
  printf 'log%s' "$i" > "${dest}/edir-${stamp}.log"
  printf 'part%s' "$i" > "${dest}/edir-${stamp}.bak.00001"
  # Force increasing mtimes in stamp order.
  touch -d "2026-01-0${i} 00:00:00 UTC" "${dest}/edir-${stamp}.bak" \
    "${dest}/edir-${stamp}.log" "${dest}/edir-${stamp}.bak.00001"
done
printf 'keep' > "${dest}/notes.txt"
prune_backups "$dest" edir 2 0
[ -f "${dest}/edir-20260103T000000Z.bak" ] || fail "newest bak removed"
[ -f "${dest}/edir-20260102T000000Z.bak" ] || fail "second bak removed"
[ ! -f "${dest}/edir-20260101T000000Z.bak" ] || fail "oldest bak kept"
[ ! -f "${dest}/edir-20260101T000000Z.log" ] || fail "oldest log kept"
[ ! -f "${dest}/edir-20260101T000000Z.bak.00001" ] || fail "oldest split part kept"
[ -f "${dest}/edir-20260103T000000Z.log" ] || fail "newest log removed"
[ -f "${dest}/edir-20260103T000000Z.bak.00001" ] || fail "newest split part removed"
[ -f "${dest}/notes.txt" ] || fail "unrelated file removed"

# age prune: one ancient set, one touched now so it is inside the window
touch -d "2020-01-01 00:00:00 UTC" "${dest}/edir-20260102T000000Z.bak" \
  "${dest}/edir-20260102T000000Z.log" "${dest}/edir-20260102T000000Z.bak.00001"
touch "${dest}/edir-20260103T000000Z.bak" "${dest}/edir-20260103T000000Z.log" \
  "${dest}/edir-20260103T000000Z.bak.00001"
prune_backups "$dest" edir 0 1
[ ! -f "${dest}/edir-20260102T000000Z.bak" ] || fail "old bak survived age prune"
[ ! -f "${dest}/edir-20260102T000000Z.log" ] || fail "old log survived age prune"
[ -f "${dest}/edir-20260103T000000Z.bak" ] || fail "fresh bak removed by age prune"

# --- redact only the password bytes in text sidecars ---
export NICI_BACKUP_PASSWORD='p@ss.word'
printf 'password was p@ss.word end\n' > "$tmp/log"
redact_password "$tmp/log"
grep -q 'p@ss.word' "$tmp/log" && fail "password remained in log"
grep -q '\*\*\*REDACTED\*\*\*' "$tmp/log" || fail "redaction marker missing"
grep -q 'password was \*\*\*REDACTED\*\*\* end' "$tmp/log" || fail "redaction damaged surrounding text"

# local names
[ "$(local_name_for edir.bak 20260101T000000Z edir)" = "edir-20260101T000000Z.bak" ] || fail "bak name"
[ "$(local_name_for edir.bak.00001 20260101T000000Z edir)" = "edir-20260101T000000Z.bak.00001" ] || fail "split name"
[ "$(local_name_for edir.log 20260101T000000Z edir)" = "edir-20260101T000000Z.log" ] || fail "log name"

# SSH password handoff is base64, decoded by a POSIX shell, never the raw secret.
export NICI_BACKUP_PASSWORD='p@ss word/+=!'
assign=$(nici_remote_assign)
printf '%s\n' "$assign" | grep -q 'p@ss word' && fail "raw NICI password in SSH assignment"
dash -c "${assign}; [ \"\$NICI_BACKUP_PASSWORD\" = 'p@ss word/+=!' ]" || fail "POSIX decode of NICI password failed"
printf '%s\n' "$assign" | grep -q 'super-secret-nici' && fail "previous password leaked into assignment"

# Fake ssh: record the remote command, pretend dsbk produced a backup set.
# Proves the NICI password is not placed raw on the SSH command line and that
# the copied file lands on the destination with mode 600.
bin=$tmp/bin
mkdir -p "$bin" "$tmp/sshsec" "$tmp/dest"
printf 'not-a-real-key\n' > "$tmp/sshsec/ssh-privatekey"
chmod 600 "$tmp/sshsec/ssh-privatekey"
cat > "$bin/ssh" <<'EOF'
#!/bin/bash
cmd="${*: -1}"
printf '%s\n' "$cmd" >> "${SSH_LOG:?}"
if [[ "$cmd" == *bash\ -s* ]]; then
  cat >/dev/null
  printf 'FILE edir.bak\nFILE edir.log\nFILE edir.out\nDONE\n'
elif [[ "$cmd" == *cat\ * ]]; then
  printf 'backup-bytes'
else
  exit 0
fi
EOF
chmod +x "$bin/ssh"
export SSH_LOG="$tmp/ssh-cmds"
export PATH="$bin:$PATH"
export VAULT_TARGET=ssh
export VAULT_SSH_HOST=backup.example
export VAULT_SSH_USER=backup
export VAULT_SSH_PORT=22
export VAULT_SSH_STRICT_HOST_KEY=no
export VAULT_SSH_DIR="$tmp/sshsec"
export VAULT_SSH_SECRET_KEY=ssh-privatekey
export BACKUP_DEST="$tmp/dest"
export BACKUP_RETENTION_COUNT=14
export BACKUP_RETENTION_DAYS=0
export INCLUDE_NICI=true
export INCLUDE_STREAMS=true
export INCLUDE_NDS_CONF=true
export NICI_BACKUP_PASSWORD='super-secret-nici'
export VAULT_EXEC_USER=
"$SCRIPT" >"$tmp/job.log"
grep -q 'EDIR BACKUP OK' "$tmp/job.log" || fail "mock ssh backup did not succeed: $(cat "$tmp/job.log")"
bak=$(find "$tmp/dest" -maxdepth 1 -type f -name 'edir-*.bak' | head -1)
[ -n "$bak" ] || fail "no bak written"
[ "$(cat "$bak")" = "backup-bytes" ] || fail "bak contents mismatch"
[ "$(stat -c %a "$bak")" = "600" ] || fail "bak mode is not 600"
grep -q 'super-secret-nici' "$SSH_LOG" && fail "NICI password appeared on the SSH command"
grep -q 'base64 -d' "$SSH_LOG" || fail "SSH command did not decode the NICI password"
grep -q 'bash -s' "$SSH_LOG" || fail "SSH command did not run the remote script"

[ "$(normalize_vault_target standalone)" = "standalone" ] || fail "standalone alias"
[ "$(normalize_vault_target ssh-docker)" = "standalone" ] || fail "ssh-docker should be standalone"
[ "$(normalize_vault_target k8s)" = "k8s" ] || fail "k8s alias"
[ "$(normalize_vault_target incluster)" = "k8s" ] || fail "incluster should be k8s"
[ "$(normalize_vault_target K8s)" = "k8s" ] || fail "case fold"
[ "$(workload_resource deploy)" = "deployment" ] || fail "deploy kind"
[ "$(workload_resource statefulset)" = "statefulset" ] || fail "sts kind"

if env VAULT_TARGET=k8s INCLUDE_NICI=false \
  VAULT_POD_NAME= VAULT_WORKLOAD_NAME= VAULT_POD_LABEL_SELECTOR= VAULT_SERVICE_NAME= \
  "$SCRIPT" >/dev/null 2>"$tmp/err"; then
  fail "k8s without a pod selector should fail"
fi
grep -q 'VAULT_WORKLOAD_NAME' "$tmp/err" || fail "expected k8s selector error, got: $(cat "$tmp/err")"

if env VAULT_TARGET=standalone INCLUDE_NICI=false \
  VAULT_DOCKER_CONTAINER= VAULT_SSH_HOST=backup.example VAULT_SSH_USER=backup \
  "$SCRIPT" >/dev/null 2>"$tmp/err"; then
  fail "standalone without a container name should fail"
fi
grep -q 'VAULT_DOCKER_CONTAINER' "$tmp/err" || fail "expected container-name error, got: $(cat "$tmp/err")"

# In-cluster engine: fake kubectl resolves a Deployment to one pod and one container.
kbin=$tmp/kbin
mkdir -p "$kbin" "$tmp/k8s-dest"
cat > "$kbin/kubectl" <<'EOF'
#!/bin/bash
line="$*"
if [ -n "${NICI_BACKUP_PASSWORD:-}" ]; then
  line=${line//${NICI_BACKUP_PASSWORD}/***REDACTED***}
fi
printf '%s\n' "$line" >> "${KUBECTL_LOG:?}"
if [[ "$*" == *" bash -s "* ]]; then
  cat >/dev/null
  printf 'FILE edir.bak\nFILE edir.log\nFILE edir.out\nDONE\n'
elif [[ "$*" == *" rm "* ]]; then
  exit 0
elif [[ "$*" == *" cat "* ]]; then
  printf 'k8s-backup-bytes'
elif [[ "$*" == *"matchLabels"* ]]; then
  printf 'app=identityengine,'
elif [[ "$*" == *"spec.containers"* ]]; then
  printf 'identityengine\n'
elif [[ "$*" == *"metadata.name"* ]]; then
  printf 'engine-pod-0\n'
else
  echo "unexpected kubectl: $*" >&2
  exit 1
fi
EOF
chmod +x "$kbin/kubectl"
export KUBECTL_LOG="$tmp/kubectl-cmds"
export PATH="$kbin:/usr/bin:/bin"
export VAULT_TARGET=k8s
export VAULT_POD_NAMESPACE=idm
export VAULT_WORKLOAD_KIND=deployment
export VAULT_WORKLOAD_NAME=identityengine
export VAULT_POD_NAME=
export VAULT_POD_LABEL_SELECTOR=
export VAULT_SERVICE_NAME=
export VAULT_POD_CONTAINER=
export BACKUP_DEST="$tmp/k8s-dest"
export INCLUDE_NICI=true
export NICI_BACKUP_PASSWORD='super-secret-nici'
export VAULT_EXEC_USER=
"$SCRIPT" >"$tmp/k8s-job.log"
grep -q 'EDIR BACKUP OK' "$tmp/k8s-job.log" || fail "k8s backup failed: $(cat "$tmp/k8s-job.log")"
grep -q 'k8s engine pod=engine-pod-0' "$tmp/k8s-job.log" || fail "did not log resolved pod"
grep -q 'container=identityengine' "$tmp/k8s-job.log" || fail "did not log engine container"
kbak=$(find "$tmp/k8s-dest" -maxdepth 1 -type f -name 'edir-*.bak' | head -1)
[ "$(cat "$kbak")" = "k8s-backup-bytes" ] || fail "k8s bak contents"
grep -q 'get deployment' "$KUBECTL_LOG" || fail "did not read the engine deployment"
grep -q -- '-c identityengine' "$KUBECTL_LOG" || fail "exec did not target the engine container"
grep -q 'super-secret-nici' "$KUBECTL_LOG" && fail "NICI password left in kubectl log"

echo "OK test-edir-backup"

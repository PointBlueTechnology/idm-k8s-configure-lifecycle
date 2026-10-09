#!/bin/bash
# Scheduled / on-demand Identity Vault backup.
# Takes a hot full eDirectory backup with dsbk on the vault, then copies the
# backup set onto the mounted PVC. See docs/EDIR_BACKUP.md.
set -euo pipefail
umask 077

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

BACKUP_DEST="${BACKUP_DEST:-/backups/edir}"
BACKUP_PREFIX="${BACKUP_PREFIX:-edir}"
BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-14}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-0}"
INCLUDE_NICI="${INCLUDE_NICI:-true}"
INCLUDE_STREAMS="${INCLUDE_STREAMS:-true}"
INCLUDE_NDS_CONF="${INCLUDE_NDS_CONF:-true}"
VAULT_TARGET="${VAULT_TARGET:-}"
VAULT_NDS_CONF="${VAULT_NDS_CONF:-/etc/opt/novell/eDirectory/conf/nds.conf}"
VAULT_STAGING_DIR="${VAULT_STAGING_DIR:-/tmp/idm-edir-backup}"
VAULT_DSBK_BIN="${VAULT_DSBK_BIN:-dsbk}"
VAULT_SSH_PORT="${VAULT_SSH_PORT:-22}"
VAULT_SSH_STRICT_HOST_KEY="${VAULT_SSH_STRICT_HOST_KEY:-yes}"
VAULT_DOCKER_BIN="${VAULT_DOCKER_BIN:-docker}"
VAULT_POD_NAMESPACE="${VAULT_POD_NAMESPACE:-${NAMESPACE:-}}"
BACKUP_ACTIVE_DEADLINE_SECONDS="${BACKUP_ACTIVE_DEADLINE_SECONDS:-7200}"
KUBECTL_CONTAINER_ARGS=()
SSH_CMD=()
DOCKER_REMOTE=${VAULT_DOCKER_BIN}

flag_word() { if is_true "$1"; then printf 'true'; else printf 'false'; fi; }

# Canonical targets:
#   standalone — engine container on a host outside the cluster (SSH + docker exec)
#   k8s        — engine container is a pod in this cluster (kubectl exec)
#   ssh        — eDirectory installed on the host, not in a container
# ssh-docker is an alias of standalone. incluster is an alias of k8s.
normalize_vault_target() {
  local raw
  raw=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    standalone|ssh-docker) printf 'standalone\n' ;;
    k8s|kubernetes|incluster) printf 'k8s\n' ;;
    ssh) printf 'ssh\n' ;;
    dry-run) printf 'dry-run\n' ;;
    *) return 1 ;;
  esac
}

dsbk_flag_summary() {
  local flags="-b -w --config-file ${VAULT_NDS_CONF}"
  if is_true "$INCLUDE_STREAMS"; then flags="${flags} -t"; fi
  if is_true "$INCLUDE_NDS_CONF"; then flags="${flags} -u"; fi
  if is_true "$INCLUDE_NICI"; then flags="${flags} -e"; fi
  printf '%s\n' "$flags"
}

# Drop backups beyond count (newest .bak files win) and/or older than N days.
# Split parts (name.bak.00001) and sidecars (.log/.out) are removed with the set.
# Uses ls/find flags that exist on both GNU and BusyBox.
prune_backups() {
  local dest=$1 prefix=$2 count=$3 days=$4
  local f base idx=0 part
  [ -d "$dest" ] || return 0
  if [ "${days:-0}" -gt 0 ]; then
    find "$dest" -maxdepth 1 -type f -name "${prefix}-*" -mtime "+${days}" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      rm -f "$f"
    done
  fi
  [ "${count:-0}" -gt 0 ] || return 0
  idx=0
  for f in $(ls -1t "${dest}/${prefix}-"*.bak 2>/dev/null || true); do
    case "$f" in
      *.bak.[0-9]*) continue ;;
    esac
    idx=$((idx + 1))
    [ "$idx" -le "$count" ] && continue
    base=${f%.bak}
    rm -f "${base}.bak" "${base}.log" "${base}.out"
    for part in "${base}.bak."[0-9]*; do
      [ -e "$part" ] || continue
      rm -f "$part"
    done
  done
}

redact_password() {
  local file=$1 pw tmp
  pw=${NICI_BACKUP_PASSWORD:-}
  [ -n "$pw" ] || return 0
  [ -f "$file" ] || return 0
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
  chmod 600 "$file"
}

local_name_for() {
  local remote_name=$1 ts=$2 prefix=$3
  case "$remote_name" in
    edir.bak) printf '%s-%s.bak\n' "$prefix" "$ts" ;;
    edir.bak.*) printf '%s-%s.bak.%s\n' "$prefix" "$ts" "${remote_name#edir.bak.}" ;;
    edir.log) printf '%s-%s.log\n' "$prefix" "$ts" ;;
    edir.out) printf '%s-%s.out\n' "$prefix" "$ts" ;;
    *) printf '%s-%s.%s\n' "$prefix" "$ts" "$remote_name" ;;
  esac
}

resolve_remote_script() {
  if [ -n "${EDIR_BACKUP_REMOTE_SCRIPT:-}" ]; then
    printf '%s\n' "$EDIR_BACKUP_REMOTE_SCRIPT"
    return
  fi
  if [ -f /lifecycle/edir-backup-remote.sh ]; then
    printf '%s\n' /lifecycle/edir-backup-remote.sh
    return
  fi
  printf '%s\n' "$(cd "$(dirname "$0")" && pwd)/edir-backup-remote.sh"
}

prepare_ssh() {
  local key_name known_name src dir ssh_dir
  [ -n "${VAULT_SSH_HOST:-}" ] || die "VAULT_SSH_HOST is required for ${VAULT_TARGET}"
  [ -n "${VAULT_SSH_USER:-}" ] || die "VAULT_SSH_USER is required for ${VAULT_TARGET}"
  case "$VAULT_SSH_STRICT_HOST_KEY" in
    yes|no|accept-new) ;;
    *) die "VAULT_SSH_STRICT_HOST_KEY must be yes, no, or accept-new" ;;
  esac
  key_name=${VAULT_SSH_SECRET_KEY:-ssh-privatekey}
  known_name=${VAULT_SSH_KNOWN_HOSTS_KEY:-known_hosts}
  ssh_dir=${VAULT_SSH_DIR:-/secrets/ssh}
  src=${ssh_dir}/${key_name}
  [ -f "$src" ] || die "SSH private key not mounted at ${src} (secret ${VAULT_SSH_SECRET:-idm-vault-ssh})"
  dir=$(mktemp -d)
  cp "$src" "${dir}/id_backup"
  chmod 600 "${dir}/id_backup"
  SSH_KEY_FILE=${dir}/id_backup
  if [ -f "${ssh_dir}/${known_name}" ]; then
    cp "${ssh_dir}/${known_name}" "${dir}/known_hosts"
    chmod 600 "${dir}/known_hosts"
    SSH_KNOWN_HOSTS=${dir}/known_hosts
  elif [ "$VAULT_SSH_STRICT_HOST_KEY" = "yes" ]; then
    die "StrictHostKeyChecking=yes but no known_hosts mounted at ${ssh_dir}/${known_name}"
  else
    SSH_KNOWN_HOSTS=/dev/null
  fi
  SSH_CMD=(
    ssh
    -T
    -i "$SSH_KEY_FILE"
    -p "$VAULT_SSH_PORT"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking="$VAULT_SSH_STRICT_HOST_KEY"
    -o UserKnownHostsFile="$SSH_KNOWN_HOSTS"
    -o ConnectTimeout=30
  )
}

# POSIX-safe assignment for the remote login shell. The password is base64 so
# it is not bash-$'...' quoted; the remote shell decodes it into the env var
# that docker/sudo then passes to dsbk. dsbk still sees -e <password> in its
# own argv (the vendor CLI has no password file).
nici_remote_assign() {
  local b64
  command -v base64 >/dev/null 2>&1 || die "base64 is required on the backup pod to pass the NICI password over SSH"
  b64=$(printf '%s' "$NICI_BACKUP_PASSWORD" | base64 | tr -d '\n')
  printf "NICI_BACKUP_PASSWORD=\$(printf '%%s' '%s' | base64 -d)" "$b64"
}

workload_resource() {
  case "$(printf '%s' "${1:-deployment}" | tr '[:upper:]' '[:lower:]')" in
    deployment|deploy) printf 'deployment\n' ;;
    statefulset|sts) printf 'statefulset\n' ;;
    *) die "VAULT_WORKLOAD_KIND must be deployment or statefulset (got ${1})" ;;
  esac
}

# One Running pod for the in-cluster engine container.
# Order: VAULT_POD_NAME, then VAULT_WORKLOAD_NAME (Deployment/StatefulSet selector),
# then VAULT_POD_LABEL_SELECTOR, then VAULT_SERVICE_NAME.
resolve_incluster_pod() {
  local ns pods count selector raw kind
  command -v kubectl >/dev/null 2>&1 || die "kubectl is required for VAULT_TARGET=k8s (set IMAGE_VAULT_BACKUP to an image that includes it)"
  ns=${VAULT_POD_NAMESPACE:-}
  [ -n "$ns" ] || die "VAULT_POD_NAMESPACE (or NAMESPACE) is required when the engine container runs in the cluster"
  if [ -n "${VAULT_POD_NAME:-}" ]; then
    printf '%s\n' "$VAULT_POD_NAME"
    return
  fi
  if [ -n "${VAULT_WORKLOAD_NAME:-}" ]; then
    kind=$(workload_resource "${VAULT_WORKLOAD_KIND:-deployment}")
    # shellcheck disable=SC2016 # go-template, not a shell expansion
    raw=$(kubectl get "$kind" -n "$ns" "$VAULT_WORKLOAD_NAME" \
      -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')
    selector=${raw%,}
    [ -n "$selector" ] || die "${kind}/${VAULT_WORKLOAD_NAME} in ${ns} has no pod selector"
    # Do not log here: this function's stdout is the pod name.
    WORKLOAD_SELECTOR=$selector
    WORKLOAD_KIND_RESOLVED=$kind
    pods=$(kubectl get pods -n "$ns" -l "$selector" \
      --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  elif [ -n "${VAULT_POD_LABEL_SELECTOR:-}" ]; then
    pods=$(kubectl get pods -n "$ns" -l "$VAULT_POD_LABEL_SELECTOR" \
      --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  elif [ -n "${VAULT_SERVICE_NAME:-}" ]; then
    pods=$(kubectl get endpoints -n "$ns" "$VAULT_SERVICE_NAME" \
      -o jsonpath='{range .subsets[*].addresses[*]}{.targetRef.name}{"\n"}{end}')
  else
    die "k8s target needs VAULT_WORKLOAD_NAME, VAULT_POD_NAME, VAULT_POD_LABEL_SELECTOR, or VAULT_SERVICE_NAME"
  fi
  pods=$(printf '%s\n' "$pods" | sed '/^$/d')
  count=$(printf '%s\n' "$pods" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$count" = "1" ] || die "expected exactly one running engine pod, found ${count}: ${pods:-<none>}"
  printf '%s\n' "$pods"
}

# Use VAULT_POD_CONTAINER when set. A single-container pod is used as-is.
# Several containers require the engine container name.
resolve_engine_container() {
  local names count listed
  if [ -n "${VAULT_POD_CONTAINER:-}" ]; then
    KUBECTL_CONTAINER_ARGS=(-c "$VAULT_POD_CONTAINER")
    return
  fi
  names=$(kubectl get pod -n "$VAULT_POD_NAMESPACE" "$VAULT_POD" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')
  names=$(printf '%s\n' "$names" | sed '/^$/d')
  count=$(printf '%s\n' "$names" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$count" = "1" ]; then
    VAULT_POD_CONTAINER=$names
    KUBECTL_CONTAINER_ARGS=(-c "$VAULT_POD_CONTAINER")
    return
  fi
  listed=$(printf '%s\n' "$names" | tr '\n' ',' | sed 's/,$//')
  die "engine pod ${VAULT_POD} has ${count} containers (${listed}). Set VAULT_POD_CONTAINER to the engine container."
}

docker_user_args() {
  if [ -n "${VAULT_EXEC_USER:-}" ]; then
    printf -- '-u %q ' "$VAULT_EXEC_USER"
  fi
}

# Run the remote script on the vault. Script is on stdin. Extra args are the remote script argv.
# Stdout is the remote stdout (FILE lines). Password is passed only as an env var, never logged.
quoted_remote_args() {
  printf '%q ' "$@"
}

run_in_vault() {
  local user_prefix qargs assign
  qargs=$(quoted_remote_args "$@")
  case "$VAULT_TARGET" in
    dry-run)
      printf 'dsbk-flags: %s\n' "$(dsbk_flag_summary)"
      if is_true "$INCLUDE_NICI"; then
        echo "NICI_BACKUP_PASSWORD=(set, redacted)"
      else
        echo "NICI_BACKUP_PASSWORD=(unset)"
      fi
      printf 'remote-args: %s\n' "$qargs"
      cat
      ;;
    k8s)
      command -v kubectl >/dev/null 2>&1 || die "kubectl is required for VAULT_TARGET=k8s"
      if [ -n "${VAULT_EXEC_USER:-}" ]; then
        if is_true "$INCLUDE_NICI"; then
          kubectl exec -i -n "$VAULT_POD_NAMESPACE" "$VAULT_POD" "${KUBECTL_CONTAINER_ARGS[@]}" -- \
            sudo -n -u "$VAULT_EXEC_USER" env "NICI_BACKUP_PASSWORD=${NICI_BACKUP_PASSWORD}" bash -s -- "$@"
        else
          kubectl exec -i -n "$VAULT_POD_NAMESPACE" "$VAULT_POD" "${KUBECTL_CONTAINER_ARGS[@]}" -- \
            sudo -n -u "$VAULT_EXEC_USER" bash -s -- "$@"
        fi
      elif is_true "$INCLUDE_NICI"; then
        kubectl exec -i -n "$VAULT_POD_NAMESPACE" "$VAULT_POD" "${KUBECTL_CONTAINER_ARGS[@]}" -- \
          env "NICI_BACKUP_PASSWORD=${NICI_BACKUP_PASSWORD}" bash -s -- "$@"
      else
        kubectl exec -i -n "$VAULT_POD_NAMESPACE" "$VAULT_POD" "${KUBECTL_CONTAINER_ARGS[@]}" -- \
          bash -s -- "$@"
      fi
      ;;
    standalone)
      [ -n "${VAULT_DOCKER_CONTAINER:-}" ] || die "standalone target needs VAULT_DOCKER_CONTAINER (engine container name on the host)"
      user_prefix=$(docker_user_args)
      if is_true "$INCLUDE_NICI"; then
        assign=$(nici_remote_assign)
        # Remote login shell decodes the password; docker exec -e forwards it.
        # shellcheck disable=SC2029
        "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" \
          "${assign}; ${DOCKER_REMOTE} exec -i -e NICI_BACKUP_PASSWORD=\"\$NICI_BACKUP_PASSWORD\" ${user_prefix}${VAULT_DOCKER_CONTAINER} bash -s -- ${qargs}"
      else
        # shellcheck disable=SC2029
        "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" \
          "${DOCKER_REMOTE} exec -i ${user_prefix}${VAULT_DOCKER_CONTAINER} bash -s -- ${qargs}"
      fi
      ;;
    ssh)
      if [ -n "${VAULT_EXEC_USER:-}" ]; then
        if is_true "$INCLUDE_NICI"; then
          assign=$(nici_remote_assign)
          # shellcheck disable=SC2029
          "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" \
            "${assign}; sudo -n -u $(printf '%q' "$VAULT_EXEC_USER") env NICI_BACKUP_PASSWORD=\"\$NICI_BACKUP_PASSWORD\" bash -s -- ${qargs}"
        else
          # shellcheck disable=SC2029
          "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" \
            "sudo -n -u $(printf '%q' "$VAULT_EXEC_USER") bash -s -- ${qargs}"
        fi
      elif is_true "$INCLUDE_NICI"; then
        assign=$(nici_remote_assign)
        # shellcheck disable=SC2029
        "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" \
          "${assign}; NICI_BACKUP_PASSWORD=\"\$NICI_BACKUP_PASSWORD\" bash -s -- ${qargs}"
      else
        # shellcheck disable=SC2029
        "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" \
          "bash -s -- ${qargs}"
      fi
      ;;
    *)
      die "VAULT_TARGET must be standalone, k8s, ssh, or dry-run"
      ;;
  esac
}

copy_from_vault() {
  local path=$1 quoted
  quoted=$(printf '%q' "$path")
  case "$VAULT_TARGET" in
    k8s)
      if [ -n "${VAULT_EXEC_USER:-}" ]; then
        kubectl exec -n "$VAULT_POD_NAMESPACE" "$VAULT_POD" "${KUBECTL_CONTAINER_ARGS[@]}" -- \
          sudo -n -u "$VAULT_EXEC_USER" cat "$path"
      else
        kubectl exec -n "$VAULT_POD_NAMESPACE" "$VAULT_POD" "${KUBECTL_CONTAINER_ARGS[@]}" -- \
          cat "$path"
      fi
      ;;
    standalone)
      # shellcheck disable=SC2029
      "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" \
        "${DOCKER_REMOTE} exec -i $(docker_user_args)${VAULT_DOCKER_CONTAINER} cat ${quoted}"
      ;;
    ssh)
      if [ -n "${VAULT_EXEC_USER:-}" ]; then
        # shellcheck disable=SC2029
        "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" \
          "sudo -n -u $(printf '%q' "$VAULT_EXEC_USER") cat ${quoted}"
      else
        # shellcheck disable=SC2029
        "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" "cat ${quoted}"
      fi
      ;;
    *)
      die "copy is not used for VAULT_TARGET=${VAULT_TARGET}"
      ;;
  esac
}

remove_remote_staging() {
  local path=$1 quoted
  [ -n "$path" ] || return 0
  [ "$VAULT_TARGET" = "dry-run" ] && return 0
  if [ "$VAULT_TARGET" = "k8s" ] && [ -z "${VAULT_POD:-}" ]; then
    return 0
  fi
  if [ "$VAULT_TARGET" = "ssh" ] || [ "$VAULT_TARGET" = "standalone" ]; then
    [ "${#SSH_CMD[@]}" -gt 0 ] || return 0
  fi
  quoted=$(printf '%q' "$path")
  case "$VAULT_TARGET" in
    k8s)
      if [ -n "${VAULT_EXEC_USER:-}" ]; then
        kubectl exec -n "$VAULT_POD_NAMESPACE" "$VAULT_POD" "${KUBECTL_CONTAINER_ARGS[@]}" -- \
          sudo -n -u "$VAULT_EXEC_USER" rm -rf "$path" || true
      else
        kubectl exec -n "$VAULT_POD_NAMESPACE" "$VAULT_POD" "${KUBECTL_CONTAINER_ARGS[@]}" -- \
          rm -rf "$path" || true
      fi
      ;;
    standalone)
      # shellcheck disable=SC2029
      "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" \
        "${DOCKER_REMOTE} exec -i $(docker_user_args)${VAULT_DOCKER_CONTAINER} rm -rf ${quoted}" || true
      ;;
    ssh)
      if [ -n "${VAULT_EXEC_USER:-}" ]; then
        # shellcheck disable=SC2029
        "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" \
          "sudo -n -u $(printf '%q' "$VAULT_EXEC_USER") rm -rf ${quoted}" || true
      else
        # shellcheck disable=SC2029
        "${SSH_CMD[@]}" "${VAULT_SSH_USER}@${VAULT_SSH_HOST}" "rm -rf ${quoted}" || true
      fi
      ;;
  esac
}

acquire_lock() {
  local dest=$1 deadline=$2 lockdir now started age
  lockdir=${dest}/.edir-backup.lock
  mkdir -p "$dest"
  if ! mkdir "$lockdir" 2>/dev/null; then
    now=$(date +%s)
    started=$(cat "${lockdir}/started" 2>/dev/null || echo 0)
    case "$started" in
      ''|*[!0-9]*) started=0 ;;
    esac
    age=$((now - started))
    if [ "$age" -ge "$deadline" ]; then
      log "Removing stale backup lock (age ${age}s)"
      rm -rf "$lockdir"
      mkdir "$lockdir"
    else
      die "another edir backup holds ${lockdir} (age ${age}s)"
    fi
  fi
  date +%s > "${lockdir}/started"
  LOCK_DIR=$lockdir
}

release_lock() {
  [ -n "${LOCK_DIR:-}" ] || return 0
  rm -rf "$LOCK_DIR"
  LOCK_DIR=
}

validate() {
  local canon
  [ -n "$VAULT_TARGET" ] || die "VAULT_TARGET is required: standalone (engine container on a host) or k8s (engine container in the cluster)"
  canon=$(normalize_vault_target "$VAULT_TARGET") \
    || die "VAULT_TARGET must be standalone or k8s (aliases ssh-docker and incluster). Use ssh only when eDirectory is installed on the host and not in a container."
  VAULT_TARGET=$canon
  if [ "$VAULT_TARGET" = "standalone" ]; then
    [ -n "${VAULT_DOCKER_CONTAINER:-}" ] || die "standalone target needs VAULT_DOCKER_CONTAINER (engine container name on the host)"
    [ -n "${VAULT_SSH_HOST:-}" ] || die "standalone target needs VAULT_SSH_HOST (the host running the engine container)"
    [ -n "${VAULT_SSH_USER:-}" ] || die "standalone target needs VAULT_SSH_USER"
  elif [ "$VAULT_TARGET" = "k8s" ]; then
    if [ -z "${VAULT_POD_NAME:-}${VAULT_WORKLOAD_NAME:-}${VAULT_POD_LABEL_SELECTOR:-}${VAULT_SERVICE_NAME:-}" ]; then
      die "k8s target needs VAULT_WORKLOAD_NAME, VAULT_POD_NAME, VAULT_POD_LABEL_SELECTOR, or VAULT_SERVICE_NAME"
    fi
  fi
  case "$INCLUDE_NICI" in
    1|0|true|TRUE|false|FALSE|yes|YES|no|NO|on|ON|off|OFF) ;;
    *) die "INCLUDE_NICI must be true or false" ;;
  esac
  if is_true "$INCLUDE_NICI"; then
    [ -n "${NICI_BACKUP_PASSWORD:-}" ] || die "INCLUDE_NICI=true but NICI_BACKUP_PASSWORD is empty. Create secret ${NICI_BACKUP_SECRET:-idm-nici-backup} key ${NICI_BACKUP_SECRET_KEY:-password}."
    # $(...) would swallow a newline, so compare lengths after deleting CR/LF.
    _pw_stripped=$(printf '%s' "$NICI_BACKUP_PASSWORD" | tr -d '\n\r')
    [ "${#_pw_stripped}" = "${#NICI_BACKUP_PASSWORD}" ] || die "NICI backup password must be a single line"
    if [ "${VAULT_EXEC_USER:-}" = "nds" ]; then
      die "dsbk -e (NICI) is supported only as root, not as user nds. Leave VAULT_EXEC_USER empty or set it to root."
    fi
  fi
  case "$BACKUP_RETENTION_COUNT" in
    ''|*[!0-9]*) die "BACKUP_RETENTION_COUNT must be an integer" ;;
  esac
  case "$BACKUP_RETENTION_DAYS" in
    ''|*[!0-9]*) die "BACKUP_RETENTION_DAYS must be an integer" ;;
  esac
}

main() {
  local ts staging remote_script manifest line name dest_name partial flags
  local saw_done=0 have_bak=0
  local -a files=()
  validate
  flags=$(dsbk_flag_summary)
  log "== edir backup target=${VAULT_TARGET} includeNici=$(flag_word "$INCLUDE_NICI") streams=$(flag_word "$INCLUDE_STREAMS") =="
  log "dsbk-flags: ${flags}"

  remote_script=$(resolve_remote_script)
  [ -f "$remote_script" ] || die "remote script not found at ${remote_script}"

  ts=$(date -u +%Y%m%dT%H%M%SZ)
  staging="${VAULT_STAGING_DIR%/}/${ts}"
  REMOTE_STAGING=$staging

  if [ "$VAULT_TARGET" = "dry-run" ]; then
    run_in_vault "$staging" "$VAULT_NDS_CONF" "$(flag_word "$INCLUDE_NICI")" \
      "$(flag_word "$INCLUDE_STREAMS")" "$(flag_word "$INCLUDE_NDS_CONF")" \
      "$VAULT_DSBK_BIN" <"$remote_script"
    exit 0
  fi

  command -v bash >/dev/null 2>&1 || die "bash is required in IMAGE_VAULT_BACKUP"
  acquire_lock "$BACKUP_DEST" "$BACKUP_ACTIVE_DEADLINE_SECONDS"
  trap 'remove_remote_staging "${REMOTE_STAGING:-}"; release_lock' EXIT

  KUBECTL_CONTAINER_ARGS=()
  DOCKER_REMOTE=${VAULT_DOCKER_BIN}
  if is_true "${VAULT_DOCKER_SUDO:-false}"; then
    DOCKER_REMOTE="sudo -n ${VAULT_DOCKER_BIN}"
  fi
  if [ "$VAULT_TARGET" = "k8s" ]; then
    VAULT_POD=$(resolve_incluster_pod)
    resolve_engine_container
    log "k8s engine pod=${VAULT_POD} namespace=${VAULT_POD_NAMESPACE} container=${VAULT_POD_CONTAINER} workload=${WORKLOAD_KIND_RESOLVED:-<direct>}/${VAULT_WORKLOAD_NAME:-} selector=${WORKLOAD_SELECTOR:-<none>}"
  elif [ "$VAULT_TARGET" = "standalone" ] || [ "$VAULT_TARGET" = "ssh" ]; then
    prepare_ssh
    if [ "$VAULT_TARGET" = "standalone" ]; then
      log "standalone engine host=${VAULT_SSH_USER}@${VAULT_SSH_HOST}:${VAULT_SSH_PORT} container=${VAULT_DOCKER_CONTAINER}"
    else
      log "ssh eDirectory host=${VAULT_SSH_USER}@${VAULT_SSH_HOST}:${VAULT_SSH_PORT}"
    fi
  fi

  manifest=$(mktemp)
  if ! run_in_vault "$staging" "$VAULT_NDS_CONF" "$(flag_word "$INCLUDE_NICI")" \
    "$(flag_word "$INCLUDE_STREAMS")" "$(flag_word "$INCLUDE_NDS_CONF")" \
    "$VAULT_DSBK_BIN" <"$remote_script" >"$manifest"; then
    die "dsbk on the vault failed"
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      FILE\ *) files+=("${line#FILE }") ;;
      DONE) saw_done=1 ;;
      "") ;;
      *) die "unexpected output from vault backup: ${line}" ;;
    esac
  done <"$manifest"
  rm -f "$manifest"
  [ "$saw_done" = 1 ] || die "vault backup did not report DONE"
  [ "${#files[@]}" -gt 0 ] || die "vault backup produced no files"

  for name in "${files[@]}"; do
    dest_name=$(local_name_for "$name" "$ts" "$BACKUP_PREFIX")
    partial="${BACKUP_DEST}/.partial.${dest_name}"
    log "copy ${name} -> ${BACKUP_DEST}/${dest_name}"
    if ! copy_from_vault "${staging}/${name}" >"$partial"; then
      rm -f "$partial"
      die "failed to copy ${name} from the vault"
    fi
    mv "$partial" "${BACKUP_DEST}/${dest_name}"
    chmod 600 "${BACKUP_DEST}/${dest_name}"
    case "$dest_name" in
      *.log|*.out) redact_password "${BACKUP_DEST}/${dest_name}" ;;
    esac
    case "$name" in
      edir.bak) have_bak=1 ;;
    esac
    log "wrote ${BACKUP_DEST}/${dest_name} ($(wc -c < "${BACKUP_DEST}/${dest_name}" | tr -d ' ') bytes)"
  done
  [ "$have_bak" = 1 ] || die "backup set has no edir.bak payload"
  [ -s "${BACKUP_DEST}/${BACKUP_PREFIX}-${ts}.bak" ] || die "backup file is empty"

  remove_remote_staging "$staging"
  REMOTE_STAGING=
  prune_backups "$BACKUP_DEST" "$BACKUP_PREFIX" "$BACKUP_RETENTION_COUNT" "$BACKUP_RETENTION_DAYS"
  release_lock
  trap - EXIT
  log "EDIR BACKUP OK ${BACKUP_DEST}/${BACKUP_PREFIX}-${ts}.bak includeNici=$(flag_word "$INCLUDE_NICI")"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

# eDirectory backup (Identity Vault)

Scheduled hot backup of one Identity Vault server. This is separate from the configure-job backup of the shared `ism` volume and the UA/WFE Postgres databases.

OpenText Identity Manager 25.4 ships Identity Vault as **eDirectory 25.4 (9.3.x)**. The backup tool for that generation is **`dsbk`** (the eDirectory Backup Tool). References:

- [Using DSBK](https://docs.microfocus.com/doc/40/25.4/edir_admin_bsl7jmp) (eDirectory 25.4)
- [Backing up and restoring NICI](https://docs.microfocus.com/doc/40/25.4/edir_admin_bunbduw)
- [Understanding backup and restore services](https://www.netiq.com/documentation/edirectory-9/edir_admin/data/a2n4mb7.html)

## Why `dsbk`

| Approach | Why it is or is not used |
|----------|--------------------------|
| **`dsbk backup -b`** | Hot continuous backup. ndsd stays up. The file is a consistent snapshot of this server's DIB at the moment the backup starts. This is the documented unattended mechanism, including the note that a cron invocation must put `/opt/novell/eDirectory/bin` on `PATH` because the `dsbk` script does not locate `ndstrace` itself. |
| **`dsbk -e`** | Folds NICI key material into that same backup. The DIB key is wrapped with NICI. A DIB backup taken without NICI cannot be opened on a server that does not already have those keys. |
| Legacy `ndsbackup` / TSA | Object-by-object tree backup from older eDirectory. It is not the server DIB snapshot, and it does not implement the NICI `-e` switch. |
| `ndsmanage` | Instance manager (create/start/stop/list). It does not take a consistent backup. |
| `tar` of a live DIB | Races writes. It is not a checkpoint, and it is easy to miss NICI or roll-forward state. |
| `dsbk backup -c` (cold) | Closes the database for the duration. Drivers and LDAP drop. Wrong default for a schedule. |

The CronJob runs `dsbk backup -b -w` (full, overwrite the staging file) with `--config-file` pointed at the instance `nds.conf`. Stream files (`-t`) and `nds.conf` itself (`-u`) are on by default. NICI (`-e`) follows `INCLUDE_NICI`.

The job does **not** turn roll-forward logging on. See [Roll-forward logs](#roll-forward-logs).

## What is backed up

For the one vault server the job is aimed at:

- The eDirectory DIB on that server (partitions held locally, not a tree-wide object walk)
- Stream files (login scripts and other streams) when `INCLUDE_STREAMS=true` (default)
- `nds.conf` when `INCLUDE_NDS_CONF=true` (default), via a `dsbk` include file
- NICI keys, wrapped inside the backup by `dsbk -e`, when `includeNici` / `INCLUDE_NICI` is true (default)

Files land on the backup PVC as mode `0600`:

```text
/backups/edir/edir-20261009T020000Z.bak
/backups/edir/edir-20261009T020000Z.log
/backups/edir/edir-20261009T020000Z.out
```

If the backup exceeds an internal `dsbk` size split, extra parts are `edir-<timestamp>.bak.00001` and so on. The timestamp is UTC.

Not included:

- Identity Applications `ism-configuration.properties`, `encrypt-keys.pkcs12`, or Postgres (back those up separately before `--all` / wipe)
- Driver trace logs, the container image, or other replicas' DIBs
- Roll-forward logs written after this backup (the `.bak` is the checkpoint; later transactions are not in it)

Staging inside the vault is `${VAULT_STAGING_DIR}/<timestamp>` (default `/tmp/idm-edir-backup/<timestamp>`), mode `0700`, and is removed after the copy. The PVC is the durable copy.

## `includeNici` (default **true**)

Site config:

| site.env | site.yaml | Default |
|----------|-----------|---------|
| `INCLUDE_NICI=true` | `backup.includeNici: true` | **true** |

`true` adds `dsbk -e <password>`. The password comes from Secret `${NICI_BACKUP_SECRET}` key `${NICI_BACKUP_SECRET_KEY}` (example names `idm-nici-backup` / `password`). The same password is required to restore NICI. It is not stored in git.

`false` omits `-e`. The Secret may be absent (`secretKeyRef.optional: true`). The result is still a full hot DIB backup, without NICI key material.

Vendor constraint: NICI backup is supported as **root only**, not as the `nds` user. Leave `VAULT_EXEC_USER` empty when the engine container's exec user is root (the usual `docker exec` / `kubectl exec` default). Setting `VAULT_EXEC_USER=nds` with `INCLUDE_NICI=true` fails before `dsbk` runs.

### Security

A backup with `includeNici: true` is a copy of the Identity Vault **and** the NICI keys that unwrap it. Anyone who has both the `.bak` and the NICI backup password can restore that server elsewhere and read NICI-wrapped attributes.

- Put the files on a dedicated PVC (`BACKUP_PVC_NAME`, default `idm-vault-backup`), not on the shared `ism` volume. Restrict the NFS export to the cluster. The job writes mode `0600`.
- Treat Secret `idm-nici-backup` like the vault admin password. The backup ServiceAccount cannot `get` Secrets through the API; the kubelet mounts the key into the pod. The configure-job ServiceAccount **can** read Secrets — do not point the CronJob at that account.
- `dsbk` has no password-file switch. For the duration of the backup the password is visible in `dsbk`'s argv on the vault (and, for in-cluster runs, in the `kubectl exec` argv). The job redacts it from the copied `.log` / `.out` when those files contain the same bytes. Do not turn on shell tracing (`bash -x`) around the job.
- The SSH private key is a separate Secret (`idm-vault-ssh`). It is mounted at `/secrets/ssh` and copied to a `0600` file before `ssh` runs.

`includeNici: false` avoids putting NICI keys in the backup store. It does **not** make the `.bak` harmless: the DIB still contains the tree, password hashes, and driver secrets. Protect that PVC either way.

## Where the engine container runs

One CronJob covers both layouts. Set `VAULT_TARGET`.

| `VAULT_TARGET` | Engine container | What the job does |
|----------------|------------------|-------------------|
| `standalone` | On a host outside the cluster (Docker or Podman) | SSH to `VAULT_SSH_HOST` and `docker exec` (or `VAULT_DOCKER_BIN`) into `VAULT_DOCKER_CONTAINER`. Set `VAULT_DOCKER_SUDO=true` when the SSH user must run `sudo -n docker`. |
| `k8s` | A pod in this cluster | `kubectl exec` into that pod. |

`ssh-docker` is an alias of `standalone`. `incluster` is an alias of `k8s`. `ssh` is the other case: eDirectory installed on the host, not in a container.

### Stand-alone host (`standalone`)

The host is the machine that runs the engine container. That is often the same address as `ENGINE_IP`, and it can be a different admin address. The container name in the OpenText engine examples is `engine-container`; set `VAULT_DOCKER_CONTAINER` to yours.

`dsbk` runs inside that container. The job copies the backup set back over SSH onto the PVC. The SSH key and `known_hosts` are required (below). No Kubernetes exec permission is used.

### Kubernetes (`k8s`)

The job finds exactly one Running pod, then execs into the engine container:

1. `VAULT_POD_NAME` if you set it
2. Otherwise `VAULT_WORKLOAD_NAME` plus `VAULT_WORKLOAD_KIND` (`deployment` or `statefulset`). The pod is chosen with that workload's selector.
3. Otherwise `VAULT_POD_LABEL_SELECTOR`
4. Otherwise `VAULT_SERVICE_NAME` (Endpoints `targetRef`)

`VAULT_POD_NAMESPACE` defaults to `NAMESPACE`. If the pod has one container, that container is used. If it has several, set `VAULT_POD_CONTAINER` to the engine container. More than one Running pod is an error.

The backup ServiceAccount can `get` Deployments and StatefulSets and `exec` into pods in `NAMESPACE`. If the engine is in another namespace, grant that Role there yourself. SSH is not used.

Example:

```bash
VAULT_TARGET=k8s
VAULT_WORKLOAD_KIND=deployment
VAULT_WORKLOAD_NAME=identityengine
VAULT_POD_CONTAINER=identityengine
VAULT_POD_NAMESPACE=idm
```

SSH uses Secret `${VAULT_SSH_SECRET}` (default `idm-vault-ssh`):

- key `ssh-privatekey` — private key
- key `known_hosts` — required when `VAULT_SSH_STRICT_HOST_KEY=yes` (the default)

The login shell on the SSH host must be able to run `base64 -d` (the NICI password is passed base64-encoded so the remote command stays POSIX-quoted). `docker exec` / `sudo` still place the decoded password in `dsbk`'s argv.

`VAULT_NDS_CONF` default is `/etc/opt/novell/eDirectory/conf/nds.conf`, the path `scripts/engine-fix-nds-interfaces.sh` uses inside the IDM engine container. The eDirectory-only 25.4 container image documents `/config/eDirectory/inst/conf/nds.conf` instead. Set the knob to the instance you are backing up.

## Install

Create the backup PVC out of band (same idea as `SHARED_PVC_NAME`). Example only — pick the StorageClass your site actually uses:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: idm-vault-backup
  namespace: idm
spec:
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 20Gi
  storageClassName: nfs
```

Build the job image from [`images/edir-backup/Dockerfile`](../images/edir-backup/Dockerfile) (bash, OpenSSH client, `base64`, `kubectl`) and set `IMAGE_VAULT_BACKUP`. Air-gapped labs should `docker load` / import it the same way as the IDM images. In-cluster mode needs `kubectl`. SSH modes need `ssh` and `base64`.

Secrets (placeholders, not lab values):

```bash
kubectl -n "$NAMESPACE" create secret generic idm-nici-backup \
  --from-literal=password='choose-a-long-nici-backup-password'

kubectl -n "$NAMESPACE" create secret generic idm-vault-ssh \
  --from-file=ssh-privatekey=/path/to/id_backup \
  --from-file=known_hosts=/path/to/known_hosts
```

Then:

```bash
./scripts/apply.sh --backup
```

That renders, refreshes the scripts ConfigMap, applies RBAC, and applies the CronJob. It does not take a backup. `--all` does not install this CronJob.

Default schedule is `0 2 * * *` in `BACKUP_TIMEZONE` (`UTC`): 02:00 UTC daily. `concurrencyPolicy: Forbid`. Retention keeps `BACKUP_RETENTION_COUNT` newest sets (default 14). `BACKUP_RETENTION_DAYS=0` means no age cutoff; set it to a positive number of days to also delete older files.

## Run once

```bash
./scripts/apply.sh --backup-now
```

or, after the CronJob exists:

```bash
kubectl -n "$NAMESPACE" create job \
  --from=cronjob/${LIFECYCLE_NAME}-edir-backup \
  ${LIFECYCLE_NAME}-edir-backup-manual-$(date -u +%Y%m%d%H%M%S)

kubectl -n "$NAMESPACE" logs -f job/${LIFECYCLE_NAME}-edir-backup-manual-<timestamp>
```

Success ends with `EDIR BACKUP OK` and a non-empty `.bak`. A second run while one holds `/backups/edir/.edir-backup.lock` fails until the lock is older than `BACKUP_ACTIVE_DEADLINE_SECONDS` (default 7200).

Local preview of the `dsbk` flags, with the NICI password redacted (no cluster):

```bash
VAULT_TARGET=dry-run INCLUDE_NICI=true NICI_BACKUP_PASSWORD=example \
  ./scripts/edir-backup.sh
```

## Restore

Restores are manual, on the vault, with the `.bak` copied back onto that server. These are the vendor `dsbk` steps for a backup this job produces. They were **not** executed against a live vault in this repo.

Stop readers and writers you cannot tolerate to rewind (drivers, Identity Applications) before restoring a DIB over a live tree. `dsbk restore` closes the DS agent, restores into an `RST` database, and with `-a -o` activates and opens it only if verification succeeds. The previous DIB is left on disk if verification fails.

Copy `edir-<timestamp>.bak` (and `.bak.00001`, … if present) into one directory on the server. Below, that path is `/restore/edir-20261009T020000Z.bak`. Use the same `--config-file` as the backup.

### With NICI (`includeNici: true`)

NICI is restored first, ndsd is restarted, then the DIB is restored. Use the password from the `idm-nici-backup` Secret.

```bash
# 1. NICI only (no -r). Wrong password fails here.
dsbk restore -f /restore/edir-20261009T020000Z.bak -l /restore/restore-nici.log \
  -e "$NICI_BACKUP_PASSWORD" \
  --config-file /etc/opt/novell/eDirectory/conf/nds.conf

# 2. Restart ndsd so the restored NICI is loaded.
#    Container: restart the engine container / pod.

# 3. DIB. -r restores the database, -a activates it, -o opens it.
dsbk restore -f /restore/edir-20261009T020000Z.bak -l /restore/restore-dib.log \
  -r -a -o \
  --config-file /etc/opt/novell/eDirectory/conf/nds.conf
```

This is the path that can rebuild a **replacement** server or a new container, because the DIB key travels with the backup. The new server still needs a matching eDirectory install and the `nds.conf` from the backup (included when `INCLUDE_NDS_CONF=true`). Restoring into a different tree name without aligning `nds.conf` fails later with `-601`.

### Without NICI (`includeNici: false`)

Do not pass `-e`. Restore the DIB on the **same** server, whose `/var/opt/novell/nici` (or the container's persisted NICI directory) is still the original.

```bash
dsbk restore -f /restore/edir-20261009T020000Z.bak -l /restore/restore-dib.log \
  -r -a -o \
  --config-file /etc/opt/novell/eDirectory/conf/nds.conf
```

If that NICI directory is gone, this backup cannot open the DIB. There is no second step that brings the keys back. Take a new backup with `INCLUDE_NICI=true` if you need to survive loss of the host.

### After either restore

- Confirm LDAP and that drivers start.
- A restore resets roll-forward logging to **off** and puts the log directory back at the default. If this server is in a replica ring, turn roll-forward logging back on and take a new full backup before relying on the schedule.
- Replica-ring restore verification compares transitive vectors. A full backup without roll-forward logs restores only to the backup checkpoint. If the ring has moved on, verification can fail and the old DIB stays active. See the next section.

## Roll-forward logs

eDirectory roll-forward logging is **off by default**. For a single-server Identity Vault (the usual IDM case) a full `dsbk -b` backup is the recovery point.

For a server in a replica ring, OpenText requires roll-forward logging **before** the backup. Otherwise a later restore does not match the sync state the other servers expect, and the database will not open.

This CronJob does not run `dsbk setconfig -L`. Turning it on is a persistent change: the logs grow until they fill the disk, and a full disk stops eDirectory. Enable it once, on a volume you monitor, not from the daily job:

```bash
dsbk setconfig -L -r /dedicated-rfl-volume --config-file /etc/opt/novell/eDirectory/conf/nds.conf
dsbk getconfig --config-file /etc/opt/novell/eDirectory/conf/nds.conf
```

Then take a new full backup. The `.bak` from this job still does not include the roll-forward logs created after that moment. Collect those logs yourself if you need to replay up to a crash (`dsbk restore -d <rfl-dir>`).

## Assumptions not verified here

No live Identity Vault was available while this was added. These are the points that still need a pass on a real 25.4 engine:

- `dsbk` is at `/opt/novell/eDirectory/bin/dsbk` in the IDM 25.4 `identityengine` image, and setting `PATH` to that directory is enough for the script to find `ndstrace`.
- `dsbk backup -e` succeeds as **root** inside that image. The IDM container docs say `ndstrace` / `ndsrepair` must be run as user `nds`, while the eDirectory NICI chapter says NICI backup is root-only. Both can be true; only a live `-e` backup confirms the combination.
- Default `nds.conf` for the IDM engine container is `/etc/opt/novell/eDirectory/conf/nds.conf` (the interface-fix script in this repo uses it). The standalone eDirectory 25.4 image documents `/config/eDirectory/inst/conf/nds.conf` instead.
- `dsbk` exit status is non-zero on failure. The job also requires a non-empty `.bak`. It does not parse the backup log format.
- `bash` is present in the engine container. `sudo -n` works when `VAULT_EXEC_USER` is set. The SSH user's shell can run `base64 -d`.
- Streaming the `.bak` out with `kubectl exec cat` or `docker exec cat` stays byte-exact for a multi-gigabyte DIB. No TTY is allocated.
- The CronJob manifest matches the Kubernetes 1.32 schema (`timeZone` included). It was not applied to a live apiserver. Clusters older than 1.27 reject `timeZone`; drop that field if you are on one.

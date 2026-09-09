# Implementation guide

## Prerequisites

1. **Helm Identity Applications** (and related charts) already installed in `NAMESPACE`.
2. **RWX PVC** mounted by UA at the shared config path (default `/config` in Jobs) — name in `SHARED_PVC_NAME`.
3. **Secrets** present:
   - Common password secret/key (`COMMON_PASSWORD_SECRET` / `COMMON_PASSWORD_KEY`)
   - Keystore secret/key (`KEYSTORE_SECRET` / `KEYSTORE_SECRET_KEY`) — must be real values, not literal `$COMMON_KEYSTORE_PWD`
4. **Engine / Identity Vault** reachable from cluster (or via Job `hostAliases` from `ENGINE_IP`/`ENGINE_HOST`).
5. **Postgres** with empty or wipeable `UA_DB_NAME` / `WFE_DB_NAME` and user `UA_WFE_DATABASE_USER`.
6. **`IMAGE_UA`** pullable in-cluster (`IfNotPresent` ok if already on nodes).
7. **`idm.jks`** already on the shared PVC under `userapp/tomcat/conf/idm.jks` (from prior Helm/configure or Engine tooling).
8. Workstation: `kubectl`, `envsubst` (`gettext`), bash; kubeconfig to the target cluster.

## Step-by-step

### 1. Site config

```bash
cp config/site.env.example config/site.env
# fill NAMESPACE, hosts, PVC, image, secrets, LDAP DNs, etc.
```

### 2. Render

```bash
./scripts/render.sh
# or: ./scripts/apply.sh --render-only
ls manifests/rendered/
```

Inspect rendered YAML: no leftover `${...}`; hosts match your site.

### 3. Backup (mandatory before wipe / `--all`)

- Copy PVC `ism-configuration.properties` and `encrypt-keys.pkcs12` if present
- `pg_dump` both UA and WFE databases
- Note current UA Deployment replica count

### 4. Dry-run

```bash
./scripts/apply.sh --dry-run --prereqs
```

### 5. Apply stages

Individual:

```bash
./scripts/apply.sh --prereqs
./scripts/apply.sh --reset-prepare   # DESTRUCTIVE
./scripts/apply.sh --schema
./scripts/apply.sh --configupdate
./scripts/apply.sh --oauth
# scale happens inside --all; or: kubectl -n $NS scale deploy/$UA_DEPLOYMENT_NAME --replicas=1
./scripts/apply.sh --smoke
```

Full cold path:

```bash
./scripts/apply.sh --all
```

`apply.sh` will: render → create `${LIFECYCLE_NAME}-scripts` + `-lib` ConfigMaps → apply RBAC → run Jobs in order.

### 6. Smoke expectations

| Path | Accept |
|------|--------|
| `/osp/a/idm/auth/app/login` | 200 |
| `/idmdash/` | 200 |
| `/IDMProv/` | 302/301/200 |
| `/IDMProv/rest/access` | 401/302/200 |
| `/idmdash/oauth.html` | 200 |

### 7. Rollback

- Restore ism (+ encrypt-keys) onto PVC from backup
- Restore Postgres dumps
- Scale UA Deployment back up
- Delete failed Jobs: `kubectl -n $NS delete job -l app.kubernetes.io/part-of=$LIFECYCLE_NAME`

## Destructive stages

| Stage | Effect |
|-------|--------|
| `--reset-prepare` / wipe Job | `DROP SCHEMA public CASCADE` on UA+WFE DBs; empty ism; remove encrypt-keys on PVC |
| Job 02 with `RESET_ISM=1` | Empties ism before ConfigUpdate (backs up `.bak-pre-configupdate-*`) |

Engine / eDirectory are **not** wiped by this package.

## Troubleshooting

- **Keystore secret literal**: Job 00 fails if password is the string `$COMMON_KEYSTORE_PWD`.
- **OAuth invalid request**: Job 03 must run so redirects use `PUBLIC_BASE_URL`, not Service DNS.
- **encrypt-keys missing**: Job 02 copies from container FS when possible; Job 03 may force NONE+plaintext for known secrets (lab path). Prefer persisting encrypt-keys beside ism on the shared volume.
- **Liquibase path errors**: Confirm image tag matches 4.10.2 layout (`IDMdb`, `IDMwfdb`).

# IDM Kubernetes configure lifecycle

Job-based **configure** for OpenText Identity Manager 25.4 / Identity Applications 4.10.2 containers on Kubernetes — drafted from a hybrid lab (Engine outside the cluster, apps via Helm).

> **Not an OpenText-supported product.** Reference implementation for collaboration / site adaptation. Lab-validated **2026-09-08 CT**.

## Audience

| Path | Audience |
|------|----------|
| [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md) | Site engineer implementing from this package |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Deployments run / Jobs configure |
| [`docs/PORTABILITY.md`](docs/PORTABILITY.md) | What is portable vs site-supplied |
| [`config/site.env.example`](config/site.env.example) | **Single source of truth** for site knobs |

## Principle

**Deployments run. Jobs configure.** Shared volume `ism` / keystores and Postgres schema are Job outputs with pass/fail gates — not side effects of `start.sh`.

## Quick start

```bash
cp config/site.env.example config/site.env
# edit every knob for your site (hosts, PVC, secrets, image, LDAP DNs)

./scripts/render.sh          # writes manifests/rendered/ (gitignored)
./scripts/apply.sh --dry-run --prereqs
# after backup of NFS ism + pg_dump:
./scripts/apply.sh --all     # DESTRUCTIVE reset path — see IMPLEMENTATION.md
```

Or apply the committed example overlay (fake `idm.example.com` / `192.0.2.10` only) to inspect shapes — **do not** run against a real cluster without re-rendering from your `site.env`.

## Layout

```text
config/site.env.example     # all site knobs
manifests/templates/        # Job + RBAC templates (${VAR} for envsubst)
examples/overlays/example.com/  # rendered fake-site examples
scripts/apply.sh            # operator wrapper (render → ConfigMaps → Jobs)
scripts/render.sh           # envsubst templates → manifests/rendered/
scripts/*.sh                # Job entrypoints (env-driven)
scripts/lib/idm-lifecycle-lib.jar
templates/configupdate.properties.tmpl
docs/
```

## Lab validation summary (2026-09-08)

| Job | Result |
|-----|--------|
| 00 prereqs | PASS — Java StartTLS LDAP + JDBC Postgres |
| wipe/reset | PASS — DROP SCHEMA + empty ism |
| 01 schema | PASS — Liquibase UA+WFE |
| 02 configupdate | PASS — vendor ConfigUpdate + authprops seed |
| 03 oauth-harden | PASS — public redirects + tenant.http-interfaces + FormRenderer ServiceRegistry/OSP* + ENCRYPT repair |
| 04 smoke | PASS — OSP/UA/dashboard HTTP checks |

## License / notice

See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). Provided as-is for collaboration with OpenText; no warranty.

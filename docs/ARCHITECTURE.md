# Architecture — Deployments run / Jobs configure

## Split of responsibility

| Layer | Owns | Does **not** own |
|-------|------|------------------|
| Helm / Deployments | Long-running UA, OSP, reporting, SSPR pods; Service/Ingress | One-shot schema, ism generation, OAuth URL repair |
| Lifecycle Jobs (this repo) | Prereq gates, Liquibase, ConfigUpdate, OAuth harden, smoke | Serving traffic |
| Shared RWX PVC | `ism-configuration.properties`, `idm.jks`, optional `encrypt-keys.pkcs12` | — |
| Postgres | UA + WFE schemas created by Job 01 | Engine eDirectory data |
| Engine (often hybrid/out-of-cluster) | Identity Vault, drivers | App configure |

## Job graph

```text
00-prereqs ──► (optional wipe) ──► 01-ua-schema ──► 02-configupdate ──► 03-oauth-harden ──► scale UA ──► 04-smoke
```

- **00** fails fast if LDAP/Postgres/keystore secrets/NFS layout are wrong.
- **Wipe** (`99-wipe-schema` / `--reset-prepare`) is **destructive**: `DROP SCHEMA public CASCADE` on UA+WFE DBs and empty ism. Engine/Vault retained.
- **01** runs Liquibase from classpath paths inside the `identityapplication` image (mirrors `ua_configure.sh`).
- **02** runs vendor `RunConfigUpdate` from a full `configupdate.properties` template; seeds authprops.
- **03** rewrites OAuth redirect URLs to the **public** base URL (not in-cluster Service DNS) and repairs undecryptable ENCRYPT values when encrypt-keys were not persisted.
- **04** curls public paths via `--resolve` to the ingress IP.

## Why Jobs

Container `start.sh` / first-boot configure is hard to gate, hard to re-run, and mixes “run” with “configure.” Jobs give:

- Explicit pass/fail
- Re-runnable stages
- Separation from the Deployment lifecycle
- Clear backup/rollback points (PVC ism + pg_dump)

## hostAliases

Hybrid labs often need DNS for the Engine hostname inside Job pods. `hostAliases` are **rendered from `ENGINE_IP` / `ENGINE_HOST` in site.env** — never hardcoded customer IPs in committed templates.

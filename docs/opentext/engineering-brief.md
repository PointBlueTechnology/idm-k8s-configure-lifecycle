# OpenText Identity Manager 25.4 — Kubernetes configure lifecycle proposal

**Author:** Jerry Combs, Point Blue Technology — former OpenText/NetIQ Identity Manager; consults for OpenText and large IDM customers. This is a **product recommendation**, not a one-off customer support ask.  
**Status:** Draft for OpenText engineering review  
**Lab validation:** 2026-09-08 (America/Chicago) — wipe UA schema/`ism`, then Jobs 00→04 **all PASS**; public smoke OSP `/idmdash/` 200, `/IDMProv/` 302  
**Product:** Identity Manager 25.4 / Identity Applications containers 4.10.2 (Helm chart `identity-manager` ~1.7.0)  
**Context:** Hybrid lab — Identity Vault/Engine on a Docker host; OSP, SSPR, Identity Applications, Reporting, Console via Helm on Kubernetes (k3s), shared RWX volume for `/config`  
**Intent:** Recommend that OpenText productize a **container-native Job (or Helm hook) configure lifecycle** — keep OpenText images; stop treating first-boot `configure` inside Deployments as the supported success path for Helm/hybrid installs.

---

## 1. Executive summary

Stock IDM containers still **mutate configuration on first start** (`env` → `silent.properties` → `source` → configure → write `ism` / keystores / DB). On Kubernetes that model is unreliable:

- A half-failed configure still leaves Pods **Ready**
- Operators see OSP login and an Identity Applications **shell**, while `/IDMProv` is dead
- Recovery requires undocumented manual Liquibase, `RunConfigUpdate`, encrypt repairs, and OAuth redirect fixes

**Recommendation:** Treat configure as an explicit, fail-closed **Job (or Helm hook) lifecycle**, keep Deployments immutable runners, and fix a small set of chart/image footguns that make hybrid/Helm installs brittle. I will recommend this pattern to large-customer Kubernetes designs.


---

## 1a. Lab validation (2026-09-08)

Reference Jobs in this package were run end-to-end against a hybrid lab (external Engine kept; Identity Applications schema/`ism` wiped, then rebuilt by Jobs):

| Stage | Result |
|-------|--------|
| 00 prereqs (LDAP StartTLS + JDBC) | PASS |
| Reset prepare (schema drop + empty `ism`) | PASS |
| 01 Liquibase UA + WFE | PASS (UA tables ≈69, WFE ≈19, `securitypermissionmeta` present) |
| 02 ConfigUpdate + authprops | PASS (`ism` ≈436 lines) |
| 03 OAuth public redirects + ENCRYPT audit/repair | PASS |
| 04 HTTP smoke via ingress | PASS — OSP 200, `/idmdash/` 200, `/IDMProv/` 302, protected apps 401, oauth.html 200 |

**Framing:** lab-validated **reference** Jobs recommended for OpenText to productize or certify — not a supported product path today.

**Residual for engineering:** ConfigUpdate can leave `encrypt-keys.pkcs12` off the shared RWX volume; Job 03 currently lab-repairs ENCRYPT markers when the CU keystore is not persisted beside `ism`. Prefer product behavior that writes encrypt-keys next to `ism` on shared storage.


---

## 2. Problem statement

### 2.1 Configure-on-start is not Kubernetes-native

| Concern | Observed behavior |
|---------|-------------------|
| Success signal | Pod Running / Ready ≠ schema present, `ism` complete, or OAuth usable |
| Secret handling | `startUA.sh` dumps **all** env into `silent.properties` then `source`s it |
| Shared state | Real truth lives on RWX `/config` + Postgres, not in Git/Helm values alone |
| Idempotency | Re-running configure / ConfigUpdate can rewrite public OAuth redirects to in-cluster DNS names |
| Crypto | `._attr_obscurity = ENCRYPT` with plaintext or old ciphertext crashes `EboConfig` at boot |

### 2.2 Hybrid is a supported *shape*, but the lifecycle is still appliance-like

OpenText documents Engine outside the app tier (e.g. AKS-style diagrams). Customers will run Engine on Docker/VM and apps on Kubernetes. The **entrypoint configure path** still assumes a single-node silent install, which breaks under Helm + external Engine + ingress front-door.

---

## 3. Evidence from lab (failure chain)

Ordered as hit during a 4.10.2.0200 Helm install against an external Engine/Postgres:

1. **Silent `source` abort** — Main container env values with **spaces** or **newlines** (e.g. `UA_DRIVER_NAME=User Application Driver`, `OSP_CUSTOM_NAME=Identity Access`, multiline `DATA_CONTAINERS_LDIF`) break `env > silent.properties && source`. Configure exits early; Liquibase never runs.
2. **Blank `/idmdash/` after OSP login** — Angular shell loads; UA DB has **0** application tables (`securitypermissionmeta` missing; Catalina: schema invalid).
3. **Incomplete `ism-configuration.properties` (~50 lines)** — Some OAuth client passwords present; missing `DirectoryService/realms/jndi/params/*` and `com.novell.idm.ldap.admin.user` / `.pass`.
4. **`/IDMProv` fails: admin user null** — Runtime loads LDAP admin from DB table `authprops` (`ldap.admin.user` / `ldap.admin.pwd`). Empty `authprops` falls back to framework `config.xml`, which has **no** admin DN. Symptom: *The admin user null could not be authenticated against authority myEdirServer*.
5. **`RunConfigUpdate` requires exact driver DN** — Tree object is `cn=User Application Driver,...` (spaces). Using a no-space alias only in ConfigUpdate props fails with LDAP `-601` under the driverset.
6. **Vendor `configupdate.properties` ships `com.novell.idm.ldap.admin.*` commented out** — Easy to produce an `ism` without LDAP admin entries unless uncommented.
7. **ENCRYPT mismatch** — After ConfigUpdate regenerates `encrypt-keys.pkcs12`, leftover clientPass values marked `ENCRYPT` but holding plaintext or prior `[AES/GCM/NoPadding]` ciphertext cause `CryptoUtils.decipher` → `IllegalArgumentException` during `EboConfig` init (workflow + IDMProv fail).
8. **OAuth “invalid OAuth2 request”** — Client secrets matched; UA `ism` redirect URLs pointed at Service DNS (`https://identityapplications/...`) while OSP registered public ingress URLs (`https://<public-host>/...`).
9. **Chart footgun:** `MASTER_KEYSTORE_PWD` left as literal `$COMMON_KEYSTORE_PWD` in pod env until manually expanded from `identity-manager-key-store-pwd`.
10. **Image footgun:** OSP/UA images lack a usable `openssl` on `PATH` (lab workaround: host binary on shared volume).

**Note:** OSP login can succeed through all of (1)–(4). Readiness today optimistically signals the wrong layer.

---

## 4. Proposal — Job-based configure lifecycle

Keep OpenText images and Helm chart; **replace the lifecycle**, not the product.

```text
Engine healthy → Postgres roles/DBs
    → Job 00 prereqs (LDAP bind, DB, volume, keystore expanded)
    → Helm Deployments (scale app configure off / scale 0 during config)
    → Job 01 schema (Liquibase UA + WFE explicitly)
    → Job 02 ConfigUpdate (checked-in props template, public FQDNs, spaced driver DN, authprops)
    → Job 03 OAuth harden (public redirects + ENCRYPT decrypt audit)
    → Scale Deployments up
    → Job 04 smoke (HTTP gates via ingress)
```

**Principle:** Deployments only *run* Tomcat. Jobs *configure* and must exit non-zero on failure so GitOps/Helm hooks fail the release.

Reference stubs (draft, customer lab): `jobs/00-prereqs.yaml` … `jobs/04-smoke.yaml` plus scripts in this package.

### 4.1 Suggested productization (OpenText)

| Item | Suggestion |
|------|------------|
| Helm hooks / subchart | Optional `lifecycle.enabled` Jobs using the same app images |
| Values | `global.publicUrl`, `identityVault.host`, explicit `configureMode: job\|entrypoint\|none` |
| Silent env | Never dump raw process env; write a **quoted/filtered** silent file (or drop `source`) |
| Driver / display names | Allow spaces in LDAP DNs without putting spaces on shell-sourced env |
| ConfigUpdate template | Ship `ldap.admin.*` **enabled** for container/Helm path; document `authprops` requirement |
| Redirects | Always derive OAuth redirect URLs from `publicUrl` / ingress host, not pod Service names |
| Readiness | Gate on schema + required `ism` keys + optional HTTP checks, not only Tomcat listen |
| Keystore | Expand `MASTER_KEYSTORE_PWD` in chart templates; include `openssl` in images or document shared-volume contract |
| Docs | “External Engine + Helm apps” chapter with Job graph and failure modes above |

---

## 5. Scope of the recommendation

**In scope**

- A **supported, fail-closed configure pipeline** (Jobs / Helm hooks) that matches how large customers actually run 25.4 on Kubernetes (including hybrid Engine)
- Chart/image fixes that make that pipeline reliable
- Documentation and a certifiable reference Job graph

**Out of scope / not requested**

- A from-scratch rewrite of Identity Applications outside OpenText containers
- Long-term support of arbitrary uncertified entrypoint forks
- Dropping eDirectory AppConfig / `ism` as the runtime contract

The attached Jobs are a **lab-validated reference** for OpenText to adopt or reshape — not a fork to support unchanged.

---

## 6. Asks for OpenText engineering (to productize this)

1. **Confirm** whether Job-based configure (or Helm hooks) is on the roadmap for 25.4.x / 4.10.x containers.  
2. **Fix or document** the silent-properties `source` hazard (spaces/newlines/multiline).  
3. **Fix** Helm chart expansion of `MASTER_KEYSTORE_PWD` / keystore-related env.  
4. **Document** required `authprops` keys and that incomplete `ism` must fail readiness.  
5. **Ensure** ConfigUpdate / k8s helpers emit **public** OAuth redirect URLs when an ingress/public host is set.  
6. **Uncomment / enable** `com.novell.idm.ldap.admin.*` in the container ConfigUpdate path (or generate them unconditionally).  
7. **Provide** a reference smoke checklist OpenText support can use (schema, `ism` keys, ENCRYPT audit, HTTP gates).  
8. **Persist** `encrypt-keys.pkcs12` onto shared RWX storage beside `ism` after ConfigUpdate (lab still needs a post-CU ENCRYPT repair when the keystore stays only in the Job container FS).
9. **Feedback** on the attached Job graph — what you would change to make it certifiable.

---

## 7. Attachment index

| Artifact | Purpose |
|----------|---------|
| `jobs/*.yaml` | Draft Kubernetes Jobs |
| `scripts/0*.sh` | Job logic (lab-oriented; generalize hosts via env) |
| `templates/configupdate.properties.tmpl` | Minimal ConfigUpdate template (subset — promote full vendor file) |
| `rbac.yaml` | Sample SA/Role for lifecycle Jobs |
| `scripts/idm-lifecycle-apply.sh` | Optional operator wrapper |

Lab hostnames in scripts are examples from one deployment; substitute customer values.

---

## 8. Contact / follow-up

Happy to walk Catalina/`idmconfigure` logs, `ism` before/after ConfigUpdate, and the OAuth redirect mismatch with Identity Applications / containers engineering. As a consultant working with OpenText and large IDM accounts, I can also carry an aligned recommendation into customer architectures once engineering owns the lifecycle.

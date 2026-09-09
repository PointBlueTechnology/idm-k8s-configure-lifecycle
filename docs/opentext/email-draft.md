# Email draft — OpenText engineering

**To:** _(Identity Applications / containers engineering contact)_  
**Subject:** Recommendation: Job-based configure lifecycle for IDM 25.4 / Identity Applications 4.10.2 on Kubernetes

---

Hello,

I’m Jerry Combs (Point Blue Technology) — former OpenText / NetIQ Identity Manager, now consulting for OpenText and several of your largest IDM customers. I’m recommending a product direction, not filing a one-off customer ticket.

**Recommendation:** For Identity Manager **25.4** / Identity Applications containers **4.10.2** on Kubernetes (Helm `identity-manager`), treat configure as an explicit, fail-closed **Job (or Helm hook) lifecycle**. Keep OpenText images; stop relying on first-boot `configure` inside Deployments as the success path.

**Why:** In a hybrid lab (Engine/Vault outside the cluster; OSP + Identity Applications on k3s with shared RWX `/config`), stock configure left Pods Ready while `/IDMProv` was dead:

- `env` → `silent.properties` → `source` aborts on spaced/multiline values (e.g. driver DN / display names)
- Liquibase never ran → blank `/idmdash/` after OSP login
- Incomplete `ism` + empty `authprops` → admin user null on `/IDMProv`
- ENCRYPT mismatches after ConfigUpdate → `EboConfig` / `CryptoUtils.decipher` crashes
- OAuth redirects written to in-cluster Service DNS instead of the public ingress host
- Chart/image footguns: unexpanded `MASTER_KEYSTORE_PWD`, missing `openssl` on PATH

Operators (and support) see a green deployment that is not actually usable. That pattern will repeat for every large customer doing hybrid or ingress-fronted Helm installs.

**What I validated:** I drafted reference Jobs (prereqs → Liquibase → ConfigUpdate/authprops → OAuth harden → HTTP smoke), wiped UA schema/`ism` in lab on **2026-09-08**, and ran Jobs **00→04** end-to-end — **all PASS**, including public smoke of OSP, `/idmdash/`, and `/IDMProv/`. Framing: lab-validated **reference** for OpenText to productize or certify — not an unsupported fork to support as-is.

**Attached:**

1. `opentext-engineering-brief.md` — failure chain, Job graph, concrete engineering asks  
2. `idm-25.4-k8s-lifecycle-proposal-DRAFT.zip` — sanitized Jobs/scripts (example hosts only)

**What I want from engineering:** Align on whether Jobs/Helm hooks are the 25.4.x / 4.10.x path; fix silent/`MASTER_KEYSTORE_PWD`/public-redirect/`authprops`/ldap.admin gaps; persist `encrypt-keys.pkcs12` beside `ism` on RWX after ConfigUpdate. I can walk this with the containers / Identity Applications team and carry the same recommendation into large-customer architectures.

Happy to schedule a working session.

Thanks,  
Jerry Combs  
Point Blue Technology  

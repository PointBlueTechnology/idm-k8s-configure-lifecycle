# Why Kubernetes-native configure for Identity Manager 25.4

**Audience:** OpenText product management (Identity Manager / Identity Applications)  
**From:** Jerry Combs, Point Blue Technology — former OpenText/NetIQ Identity Manager; consults for OpenText and large IDM customers  
**Companion docs:** Engineering brief + lab-validated Job reference (separate package)  
**Ask in one line:** Make **configure a first-class, fail-closed product step** on Kubernetes — not a side effect of starting an app container.

---

## The opportunity

Large Identity Manager customers are moving Identity Applications onto Kubernetes (Helm, AKS, private k8s, hybrid Engine). They expect the same things they get from modern platforms elsewhere:

- Installs that **succeed or fail clearly**
- Upgrades and redeploys that do not silently leave half-configured systems
- A public URL / ingress as the front door — not internal service names
- Supportable outcomes that ops and OpenText support can reason about

Today, container configure still behaves like an **appliance first boot** inside a long-running pod. That mismatch is already biting hybrid and Helm installs. Fixing it is not a niche CI preference — it is how OpenText stays credible as the identity platform for cloud-native estates.

---

## What goes wrong today (in business terms)

When configure runs as part of “start the app,” the cluster can look healthy while the product is not usable:

| What the customer sees | What it costs |
|------------------------|---------------|
| Pods “Ready,” login works, dashboard shell loads | False confidence; projects declared “installed” |
| Provisioning / IDMProv fails or is blank | War rooms, partner hours, delayed go-lives |
| OAuth “invalid request” after days of debugging | Brand damage on the most visible step (sign-in) |
| Recovery via tribal knowledge (manual schema, ConfigUpdate, crypto repairs) | Unbillable thrash; tickets OpenText cannot close cleanly |
| Every large account reinvents the same escape hatches | Inconsistent architectures; harder to support and certify |

**The failure mode that matters to PMs:** *green deployment, red product.* That is a trust problem, not a script problem.

---

## The recommendation (product shape)

**Keep OpenText images and the Identity Applications runtime.** Change the **lifecycle**:

1. **Deployments run** the product (Tomcat / services).
2. **Jobs (or Helm hooks) configure** — schema, ConfigUpdate, OAuth/public URLs, health gates.
3. The release **fails closed** if configure did not finish — no “Ready but broken” Identity Applications.

This is the same pattern customers already accept for databases, service meshes, and other enterprise software on Kubernetes. Identity Manager should not be the outlier.

A lab reference implementing this flow was wiped and rebuilt end-to-end on **2026-09-08** and passed public smoke (login, dashboard, provisioning entry). Treat that as proof the product *can* be operated this way — engineering owns how to productize it.

---

## Benefits

### For customers (especially large / hybrid)

- **Faster, safer go-lives** — configure is a visible stage with a pass/fail, not folklore after Helm install  
- **Ingress-first installs** — public hostname is the OAuth and bookmark reality from day one  
- **Hybrid without apology** — Engine/Vault outside the cluster remains a first-class story, with apps that configure reliably against it  
- **Repeatable environments** — lab, DR, and prod follow the same lifecycle instead of “works on the engineer who fixed it”  
- **Clearer ownership** — ops can see which stage failed (prereqs, schema, config, smoke)

### For OpenText product & support

- **Fewer “it installed but doesn’t work” tickets** — Ready means product-ready, or the release failed  
- **A supportable story** — documented stages, gates, and logs instead of one-off recovery recipes  
- **Certifiable Kubernetes path** — something Sales and Partners can point to for AKS/Helm/hybrid deals  
- **Lower cost to serve** — less expert time burned on silent-configure footguns  
- **Roadmap leverage** — once configure is a product surface, you can version it, test it, and improve it like a feature

### For partners & consultants (including Point Blue)

- **Architectures you can recommend without caveats** — Job-based configure becomes the default design, not a custom rescue  
- **Less unpaid recovery** after “successful” Helm installs  
- **Aligned messaging** with OpenText engineering instead of competing workarounds per account

---

## Why do this now

1. **25.4 / 4.10.x containers are in market** — customers are installing *this* generation on Kubernetes now.  
2. **Hybrid is real** — largest accounts often keep Engine/Vault where it already runs; apps move first. The lifecycle must match that.  
3. **Competitors and adjacent stacks** sell “cloud-native” as operational clarity. Opaque first-boot configure undercuts that narrative.  
4. **You already have the pieces** (images, ConfigUpdate, Liquibase, Helm). The gap is **productizing the orchestration and success criteria**, not inventing a new Identity Applications.  
5. **Consultant and partner recommendation is ready** — this can be carried into large-customer designs *as soon as* OpenText owns the path.

---

## What “done” looks like for product

A PM-level definition of done (details in the engineering brief):

- Customer can choose a supported **configure mode** (Job/hook vs legacy entrypoint) in Helm values  
- Failed configure **fails the release** (no silent half-config)  
- Public URL / ingress is the source of truth for OAuth and redirects  
- Documented hybrid + Helm guide with a smoke checklist Support can use  
- Chart/image footguns that cause green-but-broken installs are fixed or blocked at install time  

Optional later: config-as-code overlays, GitOps-friendly re-runs, certified reference on AKS — after the lifecycle itself is a product.

---

## What this is not

- Not a request to rewrite Identity Applications outside OpenText containers  
- Not asking Support to bless arbitrary customer forks forever  
- Not a CI/CD fashion pitch — it is about **install integrity, time-to-value, and cost to serve**

---

## Call to action

1. **Sponsor** Job/Helm-hook configure as a 25.4.x / Identity Applications containers outcome.  
2. **Pair** PM + containers / Identity Applications engineering on the asks in the engineering brief (silent configure hazards, keystore/public URL, authprops, encrypt-keys on shared storage, readiness that matches product health).  
3. **Use** the lab-validated reference as a strawman — reshape and certify, don’t dismiss as “custom scripts.”  
4. **Enable** Sales/Partners with one slide: *Deploy runs. Configure Jobs. Ready means usable.*

I can brief PM and engineering together, and I will recommend this pattern to large IDM Kubernetes designs once OpenText owns the lifecycle.

— Jerry Combs, Point Blue Technology

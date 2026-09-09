# Email draft — OpenText product management

**To:** _(Identity Manager / Identity Applications PM)_  
**Subject:** Kubernetes-native configure for IDM 25.4 — recommendation + private reference repo

---

Hello,

I’m Jerry Combs (Point Blue) — former OpenText/NetIQ Identity Manager, now consulting for OpenText and several of your largest IDM customers. I’m recommending a product direction, not opening a support ticket.

**What this is**  
A recommendation that Identity Manager **25.4** / Identity Applications containers treat **configure as a first-class, fail-closed step on Kubernetes** (Jobs or Helm hooks), while Deployments only *run* the product. OpenText images stay; the lifecycle changes. I’ve published a private, lab-validated reference implementation you can review here:

`https://github.com/PointBlueTechnology/idm-k8s-configure-lifecycle`

*(repo is private — tell me who to add, or I can grant access on request.)*

**Why we’re doing it**  
Large customers are putting Identity Applications on Helm/Kubernetes (often hybrid: Engine/Vault outside the cluster). Stock first-boot configure still behaves like an appliance start inside a pod. The result PMs should care about is **green deployment, red product**: pods Ready, login may work, provisioning/dashboard unusable — then weeks of tribal recovery. That burns customer trust, partner time, and OpenText support capacity, and it undercuts a “cloud-native” story competitors already sell as operational clarity.

**What good looks like**  
Configure succeeds or fails clearly. Public/ingress URLs drive OAuth from day one. Hybrid stays first-class. Sales and partners get a path they can recommend without caveats. Cost to serve drops because “installed but broken” stops being normal.

Happy to brief you and engineering together. I’ll recommend this pattern into large-customer Kubernetes designs once OpenText owns the lifecycle.

Thanks,  
Jerry Combs  
Point Blue Technology  

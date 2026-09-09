# Portability

## Portable (this package)

- Job graph and shell logic parameterized by env
- RBAC Role shape (scale Deployment, read secrets/CMs)
- Vendor `configupdate.properties` template placeholders
- Helper jar for LDAP/JDBC checks inside the UA image
- Docs / OpenText briefs (sanitized)

## Each site must supply (`config/site.env`)

| Knob | Why |
|------|-----|
| `NAMESPACE`, `SHARED_PVC_NAME` | Cluster objects |
| `PUBLIC_HOST`, `PUBLIC_BASE_URL`, `INGRESS_IP` | OAuth redirects + smoke |
| `ENGINE_HOST`, `ENGINE_IP` | hostAliases + LDAP/JDBC targets |
| `PG_HOST`, DB names/user | Liquibase + Wipe |
| `IMAGE_UA` | Must match installed Helm chart image |
| `UA_DEPLOYMENT_NAME` | Scale target |
| Secret names/keys | Password + keystore |
| LDAP DNs / containers | Match your tree |
| `LIFECYCLE_NAME` | Object naming prefix (default `idm-lifecycle`) |

## OpenText Helm / image assumptions (still coupled)

Validated against **Identity Applications 4.10.2** image tag pattern `identityapplication:idm-4.10.2.0200-81` and typical Helm release shapes:

| Assumption | Detail |
|------------|--------|
| Deployment name | Default `identityapplications` (override via `UA_DEPLOYMENT_NAME`) |
| Secret shapes | `idm-common-password` / key `password`; `identity-manager-key-store-pwd` / key `keystore-pwd` |
| Image paths | `/opt/netiq/idm/apps/UserApplication`, `.../UserApplicationWorkflow`, `.../configupdate`, Tomcat postgresql JDBC jar |
| Liquibase | `IDMdb/*`, `IDMwfdb/*`, changelog `DatabaseChangeLog.xml`, contexts `prov,newdb,updatedb` |
| Shared volume layout | `userapp/tomcat/conf/ism-configuration.properties`, `idm.jks` on RWX PVC |
| ConfigUpdate | `com.netiq.installer.configupdate.RunConfigUpdate`; encrypt-keys may land in ephemeral FS (Job copies to PVC) |
| In-cluster Service DNS | Job 03 rejects redirects still pointing at `identityapplications` |

Sites on different chart versions, secret key names, or non-Helm installs must adapt `site.env` and possibly script paths — see IMPLEMENTATION.md.

## What is **not** claimed portable

- Point Blue lab IPs/hostnames (excluded from committed Jobs)
- Pre-baked Job YAML with live site values (use render)
- Guaranteed encrypt-keys persistence (known residual; Job 03 force-repairs for lab)
- OpenText support entitlement

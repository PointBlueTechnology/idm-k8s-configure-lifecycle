# Packaging for OpenText engineering

## Send first

1. `opentext-pm-brief.md` — product managers (why / benefits)
2. `opentext-engineering-brief.md` — engineering (evidence / Jobs / asks)
3. Optional zip of this folder **after sanitization**
4. `opentext-email-draft.md` — outbound email (adjust To:)

## Sanitize before external share

- Replace customer FQDNs/IPs with examples (`idm.example.com`, `192.0.2.10`)
- Strip or redact passwords, keystore material, TLS secrets
- Keep failure **symptoms and product behaviors**; drop private hostnames if desired
- Do **not** include live `ism-configuration.properties`, NFS dumps, or DB dumps

## Suggested zip name

`idm-25.4-k8s-lifecycle-proposal-DRAFT.zip`

Contents: this directory with lab-only secrets removed; brief on top.

## Positioning

Frame as a **consultant product recommendation** (former OpenText/NetIQ IDM; consults for OpenText and large customers), with lab-validated reference Jobs — not a demand to support an unsupported fork. Recommend OpenText productize a Job-based configure lifecycle for Helm/AKS/k8s installs.

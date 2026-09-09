# Example overlay (documentation only)

Rendered from `config/site.env.example` with **documentation hosts**:

- `idm.example.com` / `https://idm.example.com`
- `idm-engine.example.com` → `192.0.2.10` (TEST-NET-1)
- Ingress `192.0.2.20`

Do **not** apply these to a real cluster. Copy `config/site.env.example` → `config/site.env`, fill your values, and run `./scripts/render.sh` (output goes to `manifests/rendered/`, gitignored).

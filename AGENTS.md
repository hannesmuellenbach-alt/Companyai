# Base44 sandbox notes

How this repo runs in the Base44 sandbox. Nothing here changes the project's own
build (`docker-compose.yml`, `docker/Dockerfile`, `company dev`).

## Run it

```bash
docker compose -f docker-compose.base44.yml up -d --build
```

Then open host port **3000**. `docker-compose.base44.yml` runs one service from
the bind-mounted checkout (`.:/app`) on a plain `python:3.12-slim-trixie` +
bun + uv image (`docker/Dockerfile.base44`):

1. `docker/base44-dev-start.sh` installs dependencies into the checkout
   (`CI=true bun install --frozen-lockfile`, `bun --cwd server/nodejs run build`
   for the JS executor sidecar, `uv sync --frozen --no-dev --extra docs` in
   `server/`).
2. Starts the app the way `company dev` does: **Vite** with HMR on container
   port 5678 (published as 3000) and **uvicorn --reload** on 5679. Vite proxies
   `/api`, `/ws`, `/webhook`, `/health`, `/mcp` to the backend, so the app keeps
   its normal same-origin layout.
3. Exits the container if either dev server dies, so `restart: on-failure`
   brings the stack back.

Frontend and backend edits therefore apply without a rebuild. Dependency
changes (`package.json`, `bun.lock`, `server/uv.lock`) are installed again on
the next container start.

## Things that are not obvious

- **Runtime state** lives on the `data` named volume mounted at `/data`
  (`DATA_DIR=/data`): `workflow.db`, `credentials.db`, `temporal.db`,
  workspaces, and the Temporal CLI the backend downloads on first boot
  (`/data/packages/temporal/...`). Recreating the container keeps it;
  `down -v` wipes it.
- **Temporal** is backend-owned (`TEMPORAL_ENABLED=true` from `.env`). The first
  `Connect to Temporal` attempt can fail while the downloaded server starts —
  the lifecycle retries and settles. `/health/ready` only turns 200 once the
  worker pool is up; the compose healthcheck uses `/health` (liveness) instead.
- **Auth is off** because the committed `.env` has `VITE_AUTH_ENABLED=false`
  (`/api/auth/status` → `auth_enabled: false`), so the preview opens straight
  into the app as the owner, with a first-run welcome guide.
- **No AI provider is configured.** The app boots without one; employees only
  run after an AI model is connected in the UI (Settings → Connectors or the
  welcome guide). That credential is stored in the app's `credentials.db`, not
  in the environment.
- **Sandbox-only env overrides** (in `docker-compose.base44.yml`, gated on
  nothing else and unused outside the sandbox):
  - `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` (platform-provided): Vite appends
    it to `server.allowedHosts` so the preview host is accepted.
  - `CORS_ORIGINS` with `https://3000-${BASE44_PUBLIC_HOST_SUFFIX}`: the preview
    proxy forwards the page's public `Origin` but rewrites `Host` to the sandbox
    host, and `server/services/authz/ws_session.py` only accepts a WebSocket
    origin whose host matches `Host`. Without the preview origin listed, every
    `/ws/status` handshake is rejected (403 `origin_not_allowed`) and the app
    sits on its "Waking up OpenCompany" splash. The app's own `.env` value is
    untouched and applies everywhere else.
  - `BASE44_PREVIEW_MODE` is passed through and currently read by nothing.
- The dev image has no Chromium, so Browser-node runs and the Android/mobile
  workspace are unavailable here (`docker/Dockerfile`'s `EXTRAS=browser` ships
  them for self-hosting).

## Verify

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/            # 200, Vite dev HTML
curl -s http://localhost:3000/api/auth/status                              # auth_enabled: false
curl -s http://localhost:3000/health                                       # database/cache true, temporal true
docker compose -f docker-compose.base44.yml ps                             # healthy
```

The container healthcheck probes **both** components (Vite on 5678, backend
`/health` on 5679) and prints which one failed.

## Tests and tooling

The sandbox host has no language runtimes; run them in the container:

```bash
docker compose -f docker-compose.base44.yml exec app bash -lc 'cd /app/server && .venv/bin/python -m pytest tests/ -x -q'
docker compose -f docker-compose.base44.yml exec app bash -lc 'cd /app/client && bun run test'
```

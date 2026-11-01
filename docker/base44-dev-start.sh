#!/bin/bash
# Start OpenCompany from the bind-mounted checkout, in dev mode.
#
# Mirrors `company dev` (docs-internal/SETUP.md): Vite serves the client with
# HMR on $VITE_CLIENT_PORT and proxies /api, /ws, /webhook, /health, /mcp to
# uvicorn on $PYTHON_BACKEND_PORT. Both run with live reload so edits in the
# checkout apply without a rebuild.
set -euo pipefail

cd /app

echo "[base44] installing workspace dependencies (bun)..."
CI=true bun install --frozen-lockfile

echo "[base44] building the JS executor sidecar..."
bun --cwd server/nodejs run build

echo "[base44] syncing the server venv (uv)..."
(cd server && uv sync --frozen --no-dev --extra docs)

echo "[base44] starting backend (uvicorn --reload) on ${PYTHON_BACKEND_PORT}..."
(cd /app/server && exec /app/server/.venv/bin/python -m uvicorn main:app \
    --host 0.0.0.0 \
    --port "${PYTHON_BACKEND_PORT}" \
    --reload \
    --reload-dir /app/server \
    --log-level info) &
backend_pid=$!

echo "[base44] starting client (vite) on ${VITE_CLIENT_PORT}..."
(cd /app/client && exec bun run start) &
client_pid=$!

shutdown() {
    kill "${backend_pid}" "${client_pid}" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap shutdown TERM INT

# If either process exits, take the container down with it so
# `restart: on-failure` brings the whole dev stack back.
wait -n "${backend_pid}" "${client_pid}"
status=$?
echo "[base44] a dev server exited (status ${status}); stopping the stack"
kill "${backend_pid}" "${client_pid}" 2>/dev/null || true
exit "${status:-1}"

#!/usr/bin/env bash
#
# setup_mcpgateway.sh  (macOS)
# Instala y arranca IBM mcp-context-forge (ContextForge).
#
# Uso:
#   ./setup_mcpgateway.sh                  # background (muere al cerrar la terminal)
#   INSTALL_SERVICE=1 ./setup_mcpgateway.sh   # servicio launchd (arranca solo al iniciar sesión)
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Parámetros (sobreescribibles por entorno)
# ----------------------------------------------------------------------------
PORT="${PORT:-4444}"
HOST="${HOST:-0.0.0.0}"
INSTALL_SERVICE="${INSTALL_SERVICE:-0}"          # 1 = instalar agente launchd
SERVICE_LABEL="${SERVICE_LABEL:-com.ibm.mcpgateway}"
WORKDIR="${WORKDIR:-$PWD/mcpgateway}"

JWT_SECRET_KEY="${JWT_SECRET_KEY:-my-test-key-but-now-longer-than-32-bytes}"
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-pass}"
PLATFORM_ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-admin@example.com}"
PLATFORM_ADMIN_PASSWORD="${PLATFORM_ADMIN_PASSWORD:-changeme}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

# ----------------------------------------------------------------------------
# 1️⃣  Isolated env + install from pypi
# mcp-contextforge-gateway uses `except*` syntax -> requires Python >= 3.11
# ----------------------------------------------------------------------------
PYTHON_BIN="$(command -v python3.12 || command -v python3.13 || command -v python3.11 || true)"
if [ -z "$PYTHON_BIN" ]; then
  err "Se necesita Python >= 3.11 y no se encontró. Instálalo con: brew install python@3.12"
  exit 1
fi
log "Usando $($PYTHON_BIN --version) ($PYTHON_BIN)"

mkdir -p "$WORKDIR" && cd "$WORKDIR"
rm -rf .venv          # limpiar venv previo
"$PYTHON_BIN" -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip
pip install mcp-contextforge-gateway

# ----------------------------------------------------------------------------
# 2️⃣  Configuration
# ----------------------------------------------------------------------------
curl -fsSL -O https://raw.githubusercontent.com/IBM/mcp-context-forge/main/.env.example
cp .env.example .env

export MCPGATEWAY_UI_ENABLED=true
export MCPGATEWAY_ADMIN_API_ENABLED=true
export PLATFORM_ADMIN_EMAIL PLATFORM_ADMIN_PASSWORD
export PLATFORM_ADMIN_FULL_NAME="Platform Administrator"
export BASIC_AUTH_PASSWORD JWT_SECRET_KEY

# ----------------------------------------------------------------------------
# 3️⃣  Arranque: servicio launchd (INSTALL_SERVICE=1) o background
# ----------------------------------------------------------------------------
if [ "$INSTALL_SERVICE" = "1" ]; then
  # --- launchd (LaunchAgent del usuario) -------------------------------------
  PLIST="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
  mkdir -p "$HOME/Library/LaunchAgents"

  log "Escribiendo LaunchAgent en $PLIST"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${WORKDIR}/.venv/bin/mcpgateway</string>
        <string>--host</string>
        <string>${HOST}</string>
        <string>--port</string>
        <string>${PORT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${WORKDIR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MCPGATEWAY_UI_ENABLED</key><string>true</string>
        <key>MCPGATEWAY_ADMIN_API_ENABLED</key><string>true</string>
        <key>PLATFORM_ADMIN_EMAIL</key><string>${PLATFORM_ADMIN_EMAIL}</string>
        <key>PLATFORM_ADMIN_PASSWORD</key><string>${PLATFORM_ADMIN_PASSWORD}</string>
        <key>PLATFORM_ADMIN_FULL_NAME</key><string>Platform Administrator</string>
        <key>BASIC_AUTH_PASSWORD</key><string>${BASIC_AUTH_PASSWORD}</string>
        <key>JWT_SECRET_KEY</key><string>${JWT_SECRET_KEY}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${WORKDIR}/gateway.log</string>
    <key>StandardErrorPath</key>
    <string>${WORKDIR}/gateway.log</string>
</dict>
</plist>
EOF
  chmod 600 "$PLIST"

  log "Cargando el agente con launchctl…"
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  RUN_MODE="launchd"
else
  # --- background -------------------------------------------------------------
  log "Arrancando gateway en ${HOST}:${PORT} (background)…"
  mcpgateway --host "$HOST" --port "$PORT" > gateway.log 2>&1 &
  GATEWAY_PID=$!
  echo "$GATEWAY_PID" > gateway.pid
  log "Gateway PID $GATEWAY_PID"
  RUN_MODE="background"
fi

# Esperar a que el servidor responda (hasta ~30s)
up=0
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null \
     || curl -s -o /dev/null "http://127.0.0.1:${PORT}/version" 2>/dev/null; then
    up=1; break
  fi
  if [ "$RUN_MODE" = "background" ] && ! kill -0 "${GATEWAY_PID:-0}" 2>/dev/null; then
    err "El proceso del gateway murió durante el arranque. Últimas líneas del log:"
    tail -n 30 gateway.log >&2 || true
    exit 1
  fi
  sleep 1
done
[ "$up" = "1" ] || { err "El gateway no respondió a tiempo. Revisa $WORKDIR/gateway.log"; exit 1; }
log "Gateway operativo."

# ----------------------------------------------------------------------------
# 4️⃣  Generate a bearer token & smoke-test the API
# ----------------------------------------------------------------------------
export MCPGATEWAY_BEARER_TOKEN=$(python3 -m mcpgateway.utils.create_jwt_token \
    --username "$PLATFORM_ADMIN_EMAIL" --exp 10080 --secret "$JWT_SECRET_KEY")

log "Smoke-test /version:"
curl -s -H "Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN" \
     "http://127.0.0.1:${PORT}/version" | jq .

# ----------------------------------------------------------------------------
# Resumen
# ----------------------------------------------------------------------------
if [ "$RUN_MODE" = "launchd" ]; then
  cat <<EOF

────────────────────────────────────────────────────────────
✅ ContextForge en marcha (LaunchAgent: ${SERVICE_LABEL})
   URL      : http://${HOST}:${PORT}
   Admin UI : http://127.0.0.1:${PORT}/admin
   Usuario  : ${PLATFORM_ADMIN_EMAIL}  /  ${PLATFORM_ADMIN_PASSWORD}
   Log      : ${WORKDIR}/gateway.log

   Estado :  launchctl list | grep ${SERVICE_LABEL}
   Parar  :  launchctl unload ~/Library/LaunchAgents/${SERVICE_LABEL}.plist
   Quitar :  launchctl unload -w ~/Library/LaunchAgents/${SERVICE_LABEL}.plist && rm ~/Library/LaunchAgents/${SERVICE_LABEL}.plist
────────────────────────────────────────────────────────────
EOF
else
  cat <<EOF

────────────────────────────────────────────────────────────
✅ ContextForge en marcha (background)
   URL      : http://${HOST}:${PORT}
   Admin UI : http://127.0.0.1:${PORT}/admin
   Usuario  : ${PLATFORM_ADMIN_EMAIL}  /  ${PLATFORM_ADMIN_PASSWORD}
   PID      : $(cat "$WORKDIR/gateway.pid" 2>/dev/null)
   Log      : ${WORKDIR}/gateway.log

   Parar:   kill \$(cat ${WORKDIR}/gateway.pid)
   Nota :   este modo muere al cerrar la terminal. Para algo permanente:
            INSTALL_SERVICE=1 $0
────────────────────────────────────────────────────────────
EOF
fi

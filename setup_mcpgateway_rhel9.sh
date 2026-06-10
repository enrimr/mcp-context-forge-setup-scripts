#!/usr/bin/env bash
#
# setup_mcpgateway_rhel9.sh
# Instala y arranca IBM mcp-context-forge (ContextForge) en RHEL 9.
#
# Uso:
#   ./setup_mcpgateway_rhel9.sh                     # local, en background (muere al cerrar sesión)
#   EXPOSE=1 ./setup_mcpgateway_rhel9.sh            # bind 0.0.0.0 + abre firewall
#   INSTALL_SERVICE=1 sudo -E ./setup_mcpgateway_rhel9.sh   # servicio systemd (arranca solo, sobrevive a reinicios)
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Parámetros (sobreescribibles por entorno)
# ----------------------------------------------------------------------------
PY_VER="${PY_VER:-3.12}"                 # versión de python a usar (3.11 o 3.12)
PORT="${PORT:-4444}"
EXPOSE="${EXPOSE:-0}"                     # 1 = bind 0.0.0.0 y abrir firewall
INSTALL_SERVICE="${INSTALL_SERVICE:-1}"   # 1 = instalar unidad systemd
SERVICE_NAME="${SERVICE_NAME:-mcpgateway}"
HOST="$([ "$EXPOSE" = "1" ] && echo 0.0.0.0 || echo 127.0.0.1)"
WORKDIR="${WORKDIR:-$PWD/mcpgateway}"

# Credenciales / secretos (cámbialos para algo serio)
JWT_SECRET_KEY="${JWT_SECRET_KEY:-my-test-key-but-now-longer-than-32-bytes}"
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-pass}"
PLATFORM_ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-admin@example.com}"
PLATFORM_ADMIN_PASSWORD="${PLATFORM_ADMIN_PASSWORD:-changeme}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

# ----------------------------------------------------------------------------
# 0️⃣  Comprobar que estamos en RHEL 9 (aviso, no bloqueante)
# ----------------------------------------------------------------------------
if [ -r /etc/os-release ]; then
  . /etc/os-release
  log "Sistema: ${PRETTY_NAME:-desconocido}"
  case "${ID:-}" in
    rhel|rocky|almalinux|centos) : ;;
    *) err "Este script está pensado para RHEL 9 / Rocky / Alma. Continúo de todos modos." ;;
  esac
fi

# Usuario destino del servicio (el que invoca, no root cuando se usa sudo -E)
SERVICE_USER="${SUDO_USER:-$(id -un)}"
SERVICE_GROUP="$(id -gn "$SERVICE_USER" 2>/dev/null || echo "$SERVICE_USER")"

# ----------------------------------------------------------------------------
# 1️⃣  Pre-requisitos del sistema (dnf)
# ----------------------------------------------------------------------------
# sudo solo si no somos root
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
    err "No eres root y no hay 'sudo'. Instala los paquetes manualmente."; exit 1
  fi
fi

PYBIN="python${PY_VER}"
need_pkgs=()
command -v "$PYBIN"  >/dev/null 2>&1 || need_pkgs+=("python${PY_VER}" "python${PY_VER}-pip")
command -v jq        >/dev/null 2>&1 || need_pkgs+=("jq")
command -v curl      >/dev/null 2>&1 || need_pkgs+=("curl")

if [ "${#need_pkgs[@]}" -gt 0 ]; then
  log "Instalando paquetes con dnf: ${need_pkgs[*]}"
  $SUDO dnf install -y "${need_pkgs[@]}"
else
  log "Paquetes base ya presentes (python${PY_VER}, jq, curl)."
fi

# Toolchain de compilación: solo lo instalamos si NO es x86_64 (donde casi
# siempre hay wheels precompilados). En aarch64 puede hacer falta.
ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
  log "Arquitectura $ARCH detectada: instalando toolchain por si pip compila extensiones C."
  $SUDO dnf install -y gcc gcc-c++ make "python${PY_VER}-devel" libffi-devel openssl-devel || \
    err "No se pudo instalar el toolchain; si pip falla compilando, instálalo a mano."
fi

# Verificar que el binario de python existe ya
if ! command -v "$PYBIN" >/dev/null 2>&1; then
  err "No se encontró $PYBIN tras la instalación. Revisa el repo AppStream."; exit 1
fi
log "Usando $($PYBIN --version) ($(command -v "$PYBIN"))"

# ----------------------------------------------------------------------------
# 2️⃣  Entorno virtual aislado + instalación desde PyPI
# ----------------------------------------------------------------------------
mkdir -p "$WORKDIR" && cd "$WORKDIR"
if [ -d .venv ]; then
  log "Eliminando .venv previo."
  rm -rf .venv
fi
"$PYBIN" -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate

log "Actualizando pip e instalando mcp-contextforge-gateway…"
pip install --upgrade pip
pip install mcp-contextforge-gateway

# ----------------------------------------------------------------------------
# 3️⃣  Configuración (.env)
# ----------------------------------------------------------------------------
log "Descargando .env.example…"
curl -fsSL -O https://raw.githubusercontent.com/IBM/mcp-context-forge/main/.env.example
cp .env.example .env
# Edita .env para personalizar (¡sobre todo las contraseñas!)

# Variables de entorno usadas tanto en background como en el servicio
export MCPGATEWAY_UI_ENABLED=true
export MCPGATEWAY_ADMIN_API_ENABLED=true
export PLATFORM_ADMIN_EMAIL PLATFORM_ADMIN_PASSWORD
export PLATFORM_ADMIN_FULL_NAME="Platform Administrator"
export BASIC_AUTH_PASSWORD JWT_SECRET_KEY

# ----------------------------------------------------------------------------
# 3.5️⃣  Firewall (solo si EXPOSE=1)
# ----------------------------------------------------------------------------
if [ "$EXPOSE" = "1" ] && command -v firewall-cmd >/dev/null 2>&1; then
  if $SUDO firewall-cmd --state >/dev/null 2>&1; then
    log "Abriendo puerto $PORT/tcp en firewalld…"
    $SUDO firewall-cmd --add-port="${PORT}/tcp" --permanent
    $SUDO firewall-cmd --reload
  fi
fi

# Espera a que el gateway responda en 127.0.0.1:$PORT (hasta ~30s).
wait_until_up() {
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null \
       || curl -s -o /dev/null "http://127.0.0.1:${PORT}/version" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ----------------------------------------------------------------------------
# 4️⃣  Arranque: servicio systemd (INSTALL_SERVICE=1) o background
# ----------------------------------------------------------------------------
if [ "$INSTALL_SERVICE" = "1" ]; then
  # --- systemd ----------------------------------------------------------------
  ENV_FILE="$WORKDIR/${SERVICE_NAME}.env"
  UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

  log "Escribiendo EnvironmentFile en $ENV_FILE"
  cat > "$ENV_FILE" <<EOF
# Variables de entorno para el servicio ${SERVICE_NAME}. NO subir a git.
MCPGATEWAY_UI_ENABLED=true
MCPGATEWAY_ADMIN_API_ENABLED=true
PLATFORM_ADMIN_EMAIL=${PLATFORM_ADMIN_EMAIL}
PLATFORM_ADMIN_PASSWORD=${PLATFORM_ADMIN_PASSWORD}
PLATFORM_ADMIN_FULL_NAME=Platform Administrator
BASIC_AUTH_PASSWORD=${BASIC_AUTH_PASSWORD}
JWT_SECRET_KEY=${JWT_SECRET_KEY}
EOF
  chmod 600 "$ENV_FILE"
  chown "$SERVICE_USER:$SERVICE_GROUP" "$ENV_FILE" 2>/dev/null || true

  log "Instalando unidad systemd en $UNIT_FILE (usuario: $SERVICE_USER)"
  $SUDO tee "$UNIT_FILE" >/dev/null <<EOF
[Unit]
Description=IBM MCP Context Forge Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${WORKDIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${WORKDIR}/.venv/bin/mcpgateway --host ${HOST} --port ${PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  log "Recargando systemd y habilitando el servicio…"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now "${SERVICE_NAME}.service"

  if ! wait_until_up; then
    err "El servicio no respondió a tiempo. Revisa: journalctl -u ${SERVICE_NAME} -e"
    exit 1
  fi
  log "Servicio ${SERVICE_NAME} activo."
  RUN_MODE="systemd"
else
  # --- background -------------------------------------------------------------
  log "Arrancando gateway en ${HOST}:${PORT} (background)…"
  mcpgateway --host "$HOST" --port "$PORT" > gateway.log 2>&1 &
  GATEWAY_PID=$!
  echo "$GATEWAY_PID" > gateway.pid
  log "Gateway PID $GATEWAY_PID (log: $WORKDIR/gateway.log)"

  # Si el proceso muere durante el arranque, no esperar en vano
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null \
       || curl -s -o /dev/null "http://127.0.0.1:${PORT}/version" 2>/dev/null; then
      break
    fi
    if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
      err "El proceso del gateway murió durante el arranque. Últimas líneas del log:"
      tail -n 30 gateway.log >&2 || true
      exit 1
    fi
    sleep 1
  done
  if ! curl -s -o /dev/null "http://127.0.0.1:${PORT}/version" 2>/dev/null; then
    err "El gateway no respondió a tiempo. Revisa $WORKDIR/gateway.log"; exit 1
  fi
  log "Gateway operativo."
  RUN_MODE="background"
fi

# ----------------------------------------------------------------------------
# 5️⃣  Generar bearer token y smoke-test de la API
# ----------------------------------------------------------------------------
log "Generando bearer token…"
MCPGATEWAY_BEARER_TOKEN="$(python3 -m mcpgateway.utils.create_jwt_token \
    --username "$PLATFORM_ADMIN_EMAIL" --exp 10080 --secret "$JWT_SECRET_KEY")"
export MCPGATEWAY_BEARER_TOKEN

log "Smoke-test /version:"
curl -s -H "Authorization: Bearer $MCPGATEWAY_BEARER_TOKEN" \
     "http://127.0.0.1:${PORT}/version" | jq .

# ----------------------------------------------------------------------------
# Resumen
# ----------------------------------------------------------------------------
if [ "$RUN_MODE" = "systemd" ]; then
  cat <<EOF

────────────────────────────────────────────────────────────
✅ ContextForge en marcha (servicio systemd: ${SERVICE_NAME})
   URL        : http://${HOST}:${PORT}
   Admin UI   : http://127.0.0.1:${PORT}/admin
   Usuario    : ${PLATFORM_ADMIN_EMAIL}  /  ${PLATFORM_ADMIN_PASSWORD}

   Estado :  systemctl status ${SERVICE_NAME}
   Logs   :  journalctl -u ${SERVICE_NAME} -f
   Parar  :  sudo systemctl stop ${SERVICE_NAME}
   Quitar :  sudo systemctl disable --now ${SERVICE_NAME} && sudo rm ${UNIT_FILE} && sudo systemctl daemon-reload

   ⚠️  SELinux: si el WORKDIR está bajo /home, systemd puede tener problemas
       para ejecutar el binario. Para servicio, usa WORKDIR bajo /opt o /srv:
         INSTALL_SERVICE=1 WORKDIR=/opt/mcpgateway sudo -E $0
────────────────────────────────────────────────────────────
EOF
else
  cat <<EOF

────────────────────────────────────────────────────────────
✅ ContextForge en marcha (background)
   URL        : http://${HOST}:${PORT}
   Admin UI   : http://127.0.0.1:${PORT}/admin
   Usuario    : ${PLATFORM_ADMIN_EMAIL}  /  ${PLATFORM_ADMIN_PASSWORD}
   PID        : $(cat "$WORKDIR/gateway.pid" 2>/dev/null)   (guardado en gateway.pid)
   Log        : ${WORKDIR}/gateway.log

   Parar:   kill \$(cat ${WORKDIR}/gateway.pid)
   Nota :   este modo muere al cerrar la sesión. Para algo permanente:
            INSTALL_SERVICE=1 WORKDIR=/opt/mcpgateway sudo -E $0
────────────────────────────────────────────────────────────
EOF
fi

# ContextForge — scripts de instalación

Instala y arranca [IBM mcp-context-forge](https://github.com/IBM/mcp-context-forge)
(ContextForge) en un entorno aislado (`.venv`).

| Script | Plataforma | Servicio permanente |
|--------|-----------|---------------------|
| `setup_mcpgateway.sh`       | macOS    | launchd (LaunchAgent) |
| `setup_mcpgateway_rhel9.sh` | RHEL 9 / Rocky / Alma | systemd |

> **Requiere Python ≥ 3.11** (el paquete usa la sintaxis `except*`).
> El `python3` por defecto de macOS (3.10) y de RHEL 9 (3.9) **no sirve**.
> Los scripts buscan/usan `python3.12` o `python3.11` automáticamente.

---

## RHEL 9

### Pre-requisitos (los instala el script, aquí por referencia)
```bash
sudo dnf install -y python3.12 python3.12-pip jq
# solo en aarch64, si pip intenta compilar:
sudo dnf install -y gcc gcc-c++ make python3.12-devel libffi-devel openssl-devel
```

### Arranque rápido (background, efímero — muere al cerrar SSH)
```bash
chmod +x setup_mcpgateway_rhel9.sh
./setup_mcpgateway_rhel9.sh                 # bind 127.0.0.1
EXPOSE=1 ./setup_mcpgateway_rhel9.sh        # bind 0.0.0.0 + abre firewalld
```

### Servicio permanente (systemd — arranca al boot, se reinicia si falla)
```bash
INSTALL_SERVICE=1 WORKDIR=/opt/mcpgateway \
  JWT_SECRET_KEY='cambia-esto-a-mas-de-32-bytes' \
  PLATFORM_ADMIN_PASSWORD='algo-fuerte' \
  EXPOSE=1 sudo -E ./setup_mcpgateway_rhel9.sh
```

**Importante:**
- Usa **`sudo -E`** (no solo `sudo`): la `-E` conserva tus variables de entorno
  para que los secretos lleguen al `EnvironmentFile`. El servicio se monta bajo
  tu usuario (`$SUDO_USER`), no bajo root.
- Pon **`WORKDIR` fuera de `/home`** (p. ej. `/opt/mcpgateway`): con SELinux en
  `enforcing`, systemd suele fallar al ejecutar binarios bajo `/home`.

### Gestión del servicio
```bash
systemctl status mcpgateway
journalctl -u mcpgateway -f
sudo systemctl stop mcpgateway
# desinstalar:
sudo systemctl disable --now mcpgateway
sudo rm /etc/systemd/system/mcpgateway.service && sudo systemctl daemon-reload
```

---

## macOS

### Pre-requisitos
```bash
brew install python@3.12 jq
```

### Arranque rápido (background)
```bash
chmod +x setup_mcpgateway.sh
./setup_mcpgateway.sh
```

### Servicio permanente (launchd — arranca al iniciar sesión, KeepAlive)
```bash
INSTALL_SERVICE=1 ./setup_mcpgateway.sh
```

### Gestión del servicio
```bash
launchctl list | grep com.ibm.mcpgateway
launchctl unload ~/Library/LaunchAgents/com.ibm.mcpgateway.plist   # parar
# desinstalar:
launchctl unload -w ~/Library/LaunchAgents/com.ibm.mcpgateway.plist
rm ~/Library/LaunchAgents/com.ibm.mcpgateway.plist
```

---

## Variables de entorno (ambos scripts)

| Variable | Por defecto | Descripción |
|----------|-------------|-------------|
| `PORT` | `4444` | Puerto del gateway |
| `WORKDIR` | `$PWD/mcpgateway` | Directorio del venv y datos |
| `JWT_SECRET_KEY` | *(clave de prueba)* | Secreto JWT (**>32 bytes** en producción) |
| `BASIC_AUTH_PASSWORD` | `pass` | Password de basic auth |
| `PLATFORM_ADMIN_EMAIL` | `admin@example.com` | Usuario admin |
| `PLATFORM_ADMIN_PASSWORD` | `changeme` | Password admin |
| `EXPOSE` | `0` | RHEL: `1` → bind `0.0.0.0` + abre firewalld |
| `PY_VER` | `3.12` | RHEL: versión de Python (`3.11`/`3.12`) |
| `INSTALL_SERVICE` | `0` | `1` → instala servicio (systemd / launchd) |

---

## Acceso

- **API**: `http://<host>:4444/version` (con header `Authorization: Bearer <token>`)
- **Admin UI**: `http://127.0.0.1:4444/admin` (usuario/contraseña admin)

El script genera un bearer token al final y hace un smoke-test de `/version`.
Para regenerarlo manualmente (dentro del `.venv`):
```bash
python3 -m mcpgateway.utils.create_jwt_token \
  --username admin@example.com --exp 10080 --secret "$JWT_SECRET_KEY"
```

---

## ⚠️ Seguridad

Los valores por defecto son **solo para pruebas locales** (password de 4 caracteres,
JWT débil). Para algo serio:
- Define `JWT_SECRET_KEY` (>32 bytes) y un `PLATFORM_ADMIN_PASSWORD` fuerte.
- Genera los secretos de cifrado dentro del venv:
  ```bash
  python -m mcpgateway.scripts.init_secrets
  ```
- Edita el `.env` generado en `$WORKDIR` para el resto de ajustes.

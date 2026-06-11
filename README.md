# ContextForge — install scripts

Install and run [IBM mcp-context-forge](https://github.com/IBM/mcp-context-forge)
(ContextForge) in an isolated environment (`.venv`).

| Script | Platform | Persistent service |
|--------|----------|--------------------|
| `setup_mcpgateway.sh`       | macOS    | launchd (LaunchAgent) |
| `setup_mcpgateway_rhel9.sh` | RHEL 9 / Rocky / Alma | systemd |

> **Requires Python ≥ 3.11** (the package uses `except*` syntax).
> The default `python3` on macOS (3.10) and RHEL 9 (3.9) **won't work**.
> The scripts auto-detect and use `python3.12` or `python3.11`.

---

## RHEL 9

### Prerequisites (installed by the script, listed here for reference)
```bash
sudo dnf install -y python3.12 python3.12-pip jq
# aarch64 only, if pip needs to compile:
sudo dnf install -y gcc gcc-c++ make python3.12-devel libffi-devel openssl-devel
```

### Quick start (background, ephemeral — dies when the SSH session closes)
```bash
chmod +x setup_mcpgateway_rhel9.sh
INSTALL_SERVICE=0 ./setup_mcpgateway_rhel9.sh             # bind 127.0.0.1
INSTALL_SERVICE=0 EXPOSE=1 ./setup_mcpgateway_rhel9.sh    # bind 0.0.0.0 + open firewalld
```

### Persistent service (systemd — starts on boot, restarts on failure)
The RHEL script installs the systemd service **by default** (`INSTALL_SERVICE=1`):
```bash
JWT_SECRET_KEY='change-me-to-more-than-32-bytes' \
  PLATFORM_ADMIN_PASSWORD='something-strong' \
  EXPOSE=1 sudo -E ./setup_mcpgateway_rhel9.sh
```

**Important:**
- Use **`sudo -E`** (not just `sudo`): `-E` preserves your environment variables
  so the secrets reach the `EnvironmentFile`. The service runs as your user
  (`$SUDO_USER`), not root.
- In service mode, `WORKDIR` defaults to **`/opt/mcpgateway`** (persistent).
  The script **rejects `/tmp` and `/var/tmp`** because they are cleared on reboot
  and would wipe the venv and database. Also avoid `/home` (SELinux issues);
  `/opt` and `/srv` work without extra tweaks.
- **`EXPOSE=1`** makes the gateway listen on `0.0.0.0` and opens the firewall.
  Without it, it listens only on `127.0.0.1` (not reachable from other machines).
- The package binary lives in the venv. To use it manually (e.g. to mint a
  token), call the venv's python, **not** the system `python3`:
  ```bash
  /opt/mcpgateway/.venv/bin/python -m mcpgateway.utils.create_jwt_token \
    --username admin@example.com --exp 10080 --secret "$JWT_SECRET_KEY"
  ```

### Managing the service
```bash
systemctl status mcpgateway
journalctl -u mcpgateway -f
sudo systemctl stop mcpgateway
# uninstall:
sudo systemctl disable --now mcpgateway
sudo rm /etc/systemd/system/mcpgateway.service && sudo systemctl daemon-reload
```

### Exposing an already-installed service to the network
If you installed it without `EXPOSE=1` and it only listens on `127.0.0.1`:
```bash
sudo sed -i 's/--host 127.0.0.1/--host 0.0.0.0/' /etc/systemd/system/mcpgateway.service
sudo systemctl daemon-reload && sudo systemctl restart mcpgateway
sudo firewall-cmd --add-port=4444/tcp --permanent && sudo firewall-cmd --reload
sudo ss -tlnp | grep 4444     # should show 0.0.0.0:4444
```

---

## macOS

### Prerequisites
```bash
brew install python@3.12 jq
```

### Quick start (background)
```bash
chmod +x setup_mcpgateway.sh
./setup_mcpgateway.sh
```

### Persistent service (launchd — starts at login, KeepAlive)
```bash
INSTALL_SERVICE=1 ./setup_mcpgateway.sh
```

### Managing the service
```bash
launchctl list | grep com.ibm.mcpgateway
launchctl unload ~/Library/LaunchAgents/com.ibm.mcpgateway.plist   # stop
# uninstall:
launchctl unload -w ~/Library/LaunchAgents/com.ibm.mcpgateway.plist
rm ~/Library/LaunchAgents/com.ibm.mcpgateway.plist
```

---

## Environment variables (both scripts)

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4444` | Gateway port |
| `WORKDIR` | `$PWD/mcpgateway` (background) / `/opt/mcpgateway` (RHEL service) | venv and data directory |
| `JWT_SECRET_KEY` | *(test key)* | JWT secret (**>32 bytes** in production) |
| `BASIC_AUTH_PASSWORD` | `pass` | Basic-auth password |
| `PLATFORM_ADMIN_EMAIL` | `admin@example.com` | Admin user |
| `PLATFORM_ADMIN_PASSWORD` | `changeme` | Admin password |
| `EXPOSE` | `0` | RHEL: `1` → bind `0.0.0.0` + open firewalld |
| `PY_VER` | `3.12` | RHEL: Python version (`3.11`/`3.12`) |
| `INSTALL_SERVICE` | `1` (RHEL) / `0` (macOS) | `1` → install service (systemd / launchd) |

---

## Access

- **API**: `http://<host>:4444/version` (with header `Authorization: Bearer <token>`)
- **Admin UI**: `http://127.0.0.1:4444/admin` (admin user/password)

The script mints a bearer token at the end and runs a smoke-test against
`/version`. To regenerate it manually (using the venv's python):
```bash
/opt/mcpgateway/.venv/bin/python -m mcpgateway.utils.create_jwt_token \
  --username admin@example.com --exp 10080 --secret "$JWT_SECRET_KEY"
```

> The `JWT_SECRET_KEY` used to **start** the service must match the one used to
> **mint** the token, or `/version` returns 401.

---

## ⚠️ Security

The defaults are **for local testing only** (4-char password, weak JWT). For
anything serious:
- Set a strong `JWT_SECRET_KEY` (>32 bytes) and `PLATFORM_ADMIN_PASSWORD`
  (e.g. `openssl rand -hex 32` for the JWT secret).
- Generate the encryption secrets inside the venv:
  ```bash
  python -m mcpgateway.scripts.init_secrets
  ```
- Edit the generated `.env` in `$WORKDIR` for the remaining settings.

---

## Disclaimer

This software is provided **"as is"**, without warranty of any kind, express or
implied. The author is **not responsible** for any damage, data loss, downtime,
security issue, or other consequence arising from its use. You run these scripts
**at your own risk**. See the [LICENSE](LICENSE) file for full terms.

> Note: `mcp-context-forge` itself is a separate project by IBM. This repository
> only provides convenience install scripts and is not affiliated with or
> endorsed by IBM.

---

## License

Released under the [MIT License](LICENSE) — free to use, modify, and
redistribute.

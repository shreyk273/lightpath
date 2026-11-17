#!/usr/bin/env bash
# Lightpath host installer (user part). Run as your normal user; asks for sudo where needed.
#
#   host/install.sh            full setup: root setup, patched Sunshine, config, agent
#   host/install.sh --no-build skip building Sunshine (use the installed one)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
log() { printf '\033[1;36m[lightpath]\033[0m %s\n' "$*"; }

log "Root setup (packages, firewall, Tailscale, uinput, sysctl)"
sudo bash "$ROOT/host/setup-root.sh" "$USER"

if [[ "${1:-}" != "--no-build" ]]; then
  "$ROOT/host/build-sunshine.sh"
fi

log "Sunshine configuration"
CONF="$HOME/.config/sunshine"
mkdir -p "$CONF" "$HOME/.config/lightpath"
chmod 700 "$HOME/.config/lightpath"
cp "$ROOT/host/config/apps.json" "$CONF/apps.json"
if [[ -f "$CONF/sunshine.conf" ]]; then
  cp "$CONF/sunshine.conf" "$CONF/sunshine.conf.bak-$(date +%Y%m%d%H%M%S)"
fi
{ cat "$ROOT/host/config/sunshine.conf"; echo "file_apps = $CONF/apps.json"; } > "$CONF/sunshine.conf"

CRED="$HOME/.config/lightpath/sunshine-web.cred"
if [[ ! -f "$CRED" ]]; then
  PW="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
  printf 'username=lightpath\npassword=%s\n' "$PW" > "$CRED"
  chmod 600 "$CRED"
  sunshine --creds lightpath "$PW" >/dev/null
fi

log "Agent"
mkdir -p "$HOME/.local/share/lightpath" "$HOME/.config/systemd/user"
install -m 755 "$ROOT/host/agent/lightpath-agent.py" "$HOME/.local/share/lightpath/"
install -m 644 "$ROOT/host/systemd/lightpath-agent.service" "$HOME/.config/systemd/user/"

systemctl --user daemon-reload
systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service lightpath-agent.service
systemctl --user restart app-dev.lizardbyte.app.Sunshine.service lightpath-agent.service
log "Done. Web UI: https://localhost:48990 (credentials in $CRED)"

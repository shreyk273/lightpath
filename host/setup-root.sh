#!/usr/bin/env bash
# Lightpath host setup: the parts that need root. Idempotent; re-running is safe.
#
#   sudo bash host/setup-root.sh <username>
#
#   1. Installs Tailscale (private network for streaming from other Wi-Fi
#      networks) and the toolchain for building Lightpath's patched Sunshine
#      (CUDA for zero-copy NVENC, npm for the web UI). Sunshine itself is built
#      from source by host/build-sunshine.sh.
#   2. Opens the firewall (ufw or nftables) for Sunshine on the local network
#      and for Tailscale.
#   3. Enables tailscaled and lets <username> control it without sudo.
#   4. Loads uinput at boot (virtual keyboard/mouse/gamepads for the stream).
#   5. Applies network sysctls sized for 100+ Mbps video bursts.
set -euo pipefail

TARGET_USER="${1:-${SUDO_USER:-}}"
[[ -n "$TARGET_USER" ]] || { echo "usage: $0 <username>" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

# Sunshine's default base port (47989) puts its video socket on 47998/udp, which
# is already used on this machine, so Lightpath shifts every Sunshine port by
# +1000. Keep in sync with host/config/sunshine.conf (port = ...).
BASE_PORT="${LIGHTPATH_BASE_PORT:-48989}"
TCP_PORTS="$((BASE_PORT - 5)),${BASE_PORT},$((BASE_PORT + 1)),$((BASE_PORT + 21))"
UDP_RANGE="$((BASE_PORT + 9)):$((BASE_PORT + 21))"
LAN_V4=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16)
LAN_V6=(fe80::/10 fc00::/7)

log() { printf '\033[1;36m[lightpath]\033[0m %s\n' "$*"; }

# --------------------------------------------------------------------------- 1. packages
PKGS=(tailscale cuda npm appstream-glib cmake git make nodejs shaderc python-jinja
      appstream desktop-file-utils libmfx miniupnpc gst-plugin-pipewire)
MISSING=()
for p in "${PKGS[@]}"; do pacman -Q "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
if ((${#MISSING[@]})); then
  log "Installing packages: ${MISSING[*]}"
  # Prefer the plain Arch build of tailscale: some CachyOS mirrors lag behind their own database.
  pacman -S --noconfirm "${MISSING[@]/#tailscale/extra/tailscale}"
fi

# --------------------------------------------------------------------------- 2. firewall
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  log "Configuring ufw (Sunshine base port $BASE_PORT)"
  ufw allow in on tailscale0 comment 'lightpath: Tailscale private network' >/dev/null
  ufw allow 41641/udp comment 'lightpath: Tailscale direct connections' >/dev/null
  for net in "${LAN_V4[@]}" "${LAN_V6[@]}"; do
    ufw allow from "$net" to any port "$TCP_PORTS" proto tcp comment 'lightpath: Sunshine' >/dev/null
    ufw allow from "$net" to any port "$UDP_RANGE" proto udp comment 'lightpath: Sunshine' >/dev/null
    ufw allow from "$net" to any port 5353 proto udp comment 'lightpath: mDNS discovery' >/dev/null
  done
elif systemctl is-active --quiet nftables; then
  NFT=/etc/nftables.conf
  if ! grep -qF "# >>> lightpath >>>" "$NFT"; then
    log "Configuring nftables"
    cp -a "$NFT" "$NFT.bak-lightpath-$(date +%Y%m%d%H%M%S)"
    v4=$(IFS=,; echo "${LAN_V4[*]}"); v6=$(IFS=,; echo "${LAN_V6[*]}")
    RULES="    # >>> lightpath >>>
    iifname \"tailscale0\" accept comment \"lightpath: Tailscale\"
    udp dport 41641 accept comment \"lightpath: Tailscale direct\"
    ip saddr { $v4 } tcp dport { $TCP_PORTS } accept comment \"lightpath: Sunshine\"
    ip saddr { $v4 } udp dport ${UDP_RANGE/:/-} accept comment \"lightpath: Sunshine\"
    ip6 saddr { $v6 } tcp dport { $TCP_PORTS } accept comment \"lightpath: Sunshine\"
    ip6 saddr { $v6 } udp dport ${UDP_RANGE/:/-} accept comment \"lightpath: Sunshine\"
    udp dport 5353 accept comment \"lightpath: mDNS\"
    # <<< lightpath <<<"
    tmp=$(mktemp)
    if awk -v rules="$RULES" '!d && /pkttype host limit rate/ {print rules; d=1} {print} END {exit !d}' "$NFT" > "$tmp" \
        && nft -c -f "$tmp"; then
      install -m 0644 "$tmp" "$NFT"; systemctl reload nftables
    else
      log "Could not safely edit $NFT; firewall unchanged"
    fi
    rm -f "$tmp"
  fi
else
  log "No active firewall found; nothing to open"
fi

# --------------------------------------------------------------------------- 3. tailscale
log "Enabling tailscaled"
systemctl enable --now tailscaled
for _ in $(seq 1 30); do [[ -S /run/tailscale/tailscaled.sock ]] && break; sleep 0.5; done
tailscale set --operator="$TARGET_USER"

# --------------------------------------------------------------------------- 4. uinput
echo uinput > /etc/modules-load.d/lightpath-uinput.conf
modprobe uinput || true

# --------------------------------------------------------------------------- 5. sysctl
cat > /etc/sysctl.d/90-lightpath.conf <<'EOF'
# Lightpath: room for bursty high-bitrate video without socket drops.
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 16384
EOF
sysctl --system >/dev/null

log "Root setup done."

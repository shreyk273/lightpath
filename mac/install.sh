#!/bin/bash
# Lightpath Mac installer. Paste into Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/shreyk273/lightpath/main/mac/install.sh | bash
#
# Installs/updates: Tailscale (if missing), Lightpath's Moonlight build, awdl-guard (keeps the
# Wi-Fi radio from hopping channels while streaming), the `lightpath` command, a "Lightpath" app
# for the Dock, tuned Moonlight settings, and pairs with your PC automatically.
set -euo pipefail

REPO="shreyk273/lightpath"
RAW="https://raw.githubusercontent.com/$REPO/main"
REL="https://github.com/$REPO/releases/download/mac-latest"
OFFICIAL_DMG="https://github.com/moonlight-stream/moonlight-qt/releases/download/v6.2.0/Moonlight-6.2.0.dmg"
LIBEXEC="/usr/local/libexec/lightpath"
PLIST="/Library/LaunchDaemons/com.lightpath.awdl-guard.plist"
TS_APP="/Applications/Tailscale.app"
TS="$TS_APP/Contents/MacOS/Tailscale"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say()  { printf '\n\033[1;36m›\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*"; exit 1; }

[ "$(uname)" = "Darwin" ] || die "This installer is for macOS."

# ------------------------------------------------------------------ administrator access
# Asked for only when something system-wide actually changes (first install, a new Wi-Fi helper
# or Tailscale). Updates that only touch Moonlight and the lightpath command need no password.
# From Terminal sudo asks as usual; without a terminal (e.g. `lightpath update` started from an
# app) macOS shows its normal password dialog instead.
SUDO=(sudo)
ROOT_READY=0
as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; return; fi
    if [ "$ROOT_READY" = 0 ]; then
        if ( : < /dev/tty ) 2>/dev/null; then
            say "Lightpath needs your Mac password (to install its Wi-Fi helper)."
            sudo -v < /dev/tty || die "Administrator access is required."
            # Keep sudo alive while we work.
            ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
        else
            cat > "$WORK/askpass" <<'ASKPASS'
#!/bin/bash
# In front of other windows, and never waiting forever if nobody is at the Mac.
exec /usr/bin/osascript -e 'tell me to activate' -e 'text returned of (display dialog "Lightpath needs your Mac password to finish updating." default answer "" with hidden answer with title "Lightpath" with icon caution giving up after 180)' 2>/dev/null
ASKPASS
            chmod 700 "$WORK/askpass"
            export SUDO_ASKPASS="$WORK/askpass"
            SUDO=(sudo -A)
            "${SUDO[@]}" -v || die "Administrator access is required."
        fi
        ROOT_READY=1
    fi
    "${SUDO[@]}" "$@"
}
same_file() { [ -f "$2" ] && cmp -s "$1" "$2"; }

# ------------------------------------------------------------------ Tailscale
if [ ! -d "$TS_APP" ]; then
    say "Installing Tailscale…"
    curl -fL --progress-bar "https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg" -o "$WORK/tailscale.pkg"
    as_root installer -pkg "$WORK/tailscale.pkg" -target / >/dev/null
fi
open -a "$TS_APP" || true
say "Connecting to your PC through Tailscale…"
for i in $(seq 1 150); do
    PC_IP="$("$TS" ip -4 lightpath-pc 2>/dev/null | head -1 || true)"
    if [ -n "$PC_IP" ] && "$TS" status >/dev/null 2>&1; then break; fi
    if [ "$i" -eq 3 ]; then
        warn "Click the Tailscale icon in the menu bar (top right) and sign in"
        warn "with the same account you used on the PC. I'll wait."
    fi
    sleep 2
done
[ -n "${PC_IP:-}" ] || die "Couldn't see the PC on Tailscale. Sign in to Tailscale and run this again."

# ------------------------------------------------------------------ downloads
say "Downloading Lightpath…"
# Through the API, not raw.githubusercontent.com: the raw CDN can serve a copy up to 5 minutes old.
curl -fsSL -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/$REPO/contents/mac/lightpath?ref=main" -o "$WORK/lightpath" \
    || curl -fsSL "$RAW/mac/lightpath" -o "$WORK/lightpath"
HAVE_TOOLS=1
for f in awdl-guard lightpath-wake SHA256SUMS; do
    curl -fsSL "$REL/$f" -o "$WORK/$f" || HAVE_TOOLS=0
done
DMG_URL="$REL/Lightpath-Moonlight.dmg"
if curl -fL --progress-bar "$DMG_URL" -o "$WORK/Moonlight.dmg"; then
    if [ "$HAVE_TOOLS" = 1 ] && grep -q Lightpath-Moonlight.dmg "$WORK/SHA256SUMS"; then
        want="$(awk '/Lightpath-Moonlight.dmg/ {print $1}' "$WORK/SHA256SUMS")"
        have="$(shasum -a 256 "$WORK/Moonlight.dmg" | awk '{print $1}')"
        [ "$want" = "$have" ] || die "Download corrupted (checksum mismatch). Run the installer again."
    fi
    MOONLIGHT_FLAVOR="Lightpath build"
else
    warn "Lightpath's Moonlight build isn't available yet; installing the official release."
    curl -fL --progress-bar "$OFFICIAL_DMG" -o "$WORK/Moonlight.dmg"
    MOONLIGHT_FLAVOR="official 6.2.0"
fi
if [ "$HAVE_TOOLS" = 1 ]; then
    for f in awdl-guard lightpath-wake; do
        want="$(awk -v f="$f" '$2 == f {print $1}' "$WORK/SHA256SUMS")"
        have="$(shasum -a 256 "$WORK/$f" | awk '{print $1}')"
        [ -z "$want" ] || [ "$want" = "$have" ] || die "Download corrupted ($f). Run the installer again."
    done
fi

# ------------------------------------------------------------------ Moonlight
say "Installing Moonlight ($MOONLIGHT_FLAVOR)…"
if pgrep -x Moonlight >/dev/null; then
    osascript -e 'tell application "Moonlight" to quit' >/dev/null 2>&1 || true
    sleep 2
    pkill -x Moonlight 2>/dev/null || true
fi
hdiutil attach -nobrowse -readonly -mountpoint "$WORK/mnt" "$WORK/Moonlight.dmg" >/dev/null
rm -rf /Applications/Moonlight.app 2>/dev/null || as_root rm -rf /Applications/Moonlight.app
ditto "$WORK/mnt/Moonlight.app" /Applications/Moonlight.app 2>/dev/null || as_root ditto "$WORK/mnt/Moonlight.app" /Applications/Moonlight.app
hdiutil detach "$WORK/mnt" >/dev/null
xattr -dr com.apple.quarantine /Applications/Moonlight.app 2>/dev/null || true

# ------------------------------------------------------------------ helpers
say "Installing the lightpath command…"
# Owned by you, so later updates replace it without a password.
if [ -w /usr/local/bin/lightpath ]; then
    cat "$WORK/lightpath" > /usr/local/bin/lightpath
else
    as_root mkdir -p /usr/local/bin
    as_root install -o "$(id -u)" -g "$(id -g)" -m 755 "$WORK/lightpath" /usr/local/bin/lightpath
fi
chmod 755 /usr/local/bin/lightpath
if [ "$HAVE_TOOLS" = 1 ]; then
    cat > "$WORK/awdl-guard.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.lightpath.awdl-guard</string>
    <key>ProgramArguments</key>
    <array><string>/usr/local/libexec/lightpath/awdl-guard</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
    if same_file "$WORK/awdl-guard" "$LIBEXEC/awdl-guard" && same_file "$WORK/lightpath-wake" "$LIBEXEC/lightpath-wake" \
            && same_file "$WORK/awdl-guard.plist" "$PLIST" && launchctl print system/com.lightpath.awdl-guard >/dev/null 2>&1; then
        say "Wi-Fi helper is up to date."
    else
        say "Installing the Wi-Fi helper…"
        as_root mkdir -p "$LIBEXEC"
        as_root install -m 755 "$WORK/awdl-guard" "$WORK/lightpath-wake" "$LIBEXEC/"
        as_root xattr -d com.apple.quarantine "$LIBEXEC/awdl-guard" "$LIBEXEC/lightpath-wake" 2>/dev/null || true
        as_root install -o root -g wheel -m 644 "$WORK/awdl-guard.plist" "$PLIST"
        as_root launchctl bootout system/com.lightpath.awdl-guard 2>/dev/null || true
        as_root launchctl bootstrap system "$PLIST"
    fi
else
    warn "Helper binaries aren't published yet; skipping the Wi-Fi helper for now."
fi

# ------------------------------------------------------------------ Moonlight settings
say "Tuning Moonlight…"
SIZE="$(osascript -l JavaScript -e '
    ObjC.import("AppKit");
    var s = $.NSScreen.screens.objectAtIndex(0), f = s.frame, k = s.backingScaleFactor, top = 0;
    try { top = s.safeAreaInsets.top; } catch (e) {}
    Math.round(f.size.width * k) + "x" + Math.round((f.size.height - top) * k);' 2>/dev/null || echo 3024x1890)"
W="${SIZE%x*}"; H="${SIZE#*x}"
D="com.moonlight-stream.Moonlight"
defaults write "$D" defaultver -int 2
defaults write "$D" width -int "$W"
defaults write "$D" height -int "$H"
defaults write "$D" fps -int 120
defaults write "$D" bitrate -int 150000
defaults write "$D" unlockbitrate -bool true
defaults write "$D" autoadjustbitrate -bool false
defaults write "$D" vsync -bool false
defaults write "$D" framepacing -bool false
defaults write "$D" gameopts -bool true
defaults write "$D" windowmode -int 1
defaults write "$D" videocfg -int 2
defaults write "$D" videodec -int 0
defaults write "$D" renderer -int 0
defaults write "$D" hdr -bool false
defaults write "$D" yuv444 -bool false
defaults write "$D" keepawake -bool true
defaults write "$D" quitAppAfter -bool false
defaults write "$D" confwarnings -bool false
defaults write "$D" mdns -bool true
# Full screen: Cmd+Tab, Cmd+Space, Cmd+Q & co. go to the PC (the PC turns them into its shortcuts)
defaults write "$D" capturesyskeys -int 1

# ------------------------------------------------------------------ Lightpath.app (Dock/Spotlight)
say "Creating the Lightpath app…"
make_app() { # name, lightpath arguments
    local app="/Applications/$1.app"
    rm -rf "$app"
    osacompile -o "$app" -e "do shell script \"/usr/local/bin/lightpath $2 >> /tmp/lightpath.log 2>&1 &\"" >/dev/null
    cp /Applications/Moonlight.app/Contents/Resources/*.icns "$app/Contents/Resources/applet.icns" 2>/dev/null || true
    touch "$app"
}
make_app "Lightpath" "connect"
make_app "Lightpath Steam" "steam"

# ------------------------------------------------------------------ pair
if defaults read com.moonlight-stream.Moonlight 2>/dev/null | grep -q srvcert; then
    say "Already paired with your PC."
    PAIRED=1
else
    say "Pairing with your PC (automatic)…"
    if /usr/local/bin/lightpath pair; then
        PAIRED=1
    else
        PAIRED=0
    fi
fi

printf '\n\033[1;32m✓ Lightpath is ready.\033[0m\n'
echo "  • Open \"Lightpath\" (Spotlight or Applications) to stream your PC's desktop."
echo "  • Open \"Lightpath Steam\" to go straight to Steam Big Picture."
echo "  • Screen: ${W}x${H} at 120 Hz. Press Ctrl+Option+Shift+Q to stop streaming."
echo "  • Mac shortcuts work on the PC (Cmd+C/V, Cmd+Tab, Option+arrows…), copy/paste is shared."
[ "$PAIRED" = 1 ] || warn "Pairing didn't finish. Turn the PC on and run: lightpath pair"

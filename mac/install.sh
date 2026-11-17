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
# Needed only for system-wide pieces: Tailscale (first install) and the Wi-Fi helper (first install
# or when it changes). Everything else lives in your own folders, so ordinary updates never ask.
# From Terminal sudo asks as usual; without a terminal (e.g. `lightpath update` started from an
# app) macOS shows its normal password dialog instead. Saying no (or not being there) only skips
# the system-wide piece; it never breaks the rest of the update.
SUDO=(sudo)
ROOT_STATE=unknown  # unknown | ok | denied
as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; return; fi
    if [ "$ROOT_STATE" = unknown ]; then
        ROOT_STATE=denied
        if ( : < /dev/tty ) 2>/dev/null; then
            say "Lightpath needs your Mac password (for its Wi-Fi helper)."
            if sudo -v < /dev/tty; then
                ROOT_STATE=ok
                # Keep sudo alive while we work.
                ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
            fi
        else
            cat > "$WORK/askpass" <<'ASKPASS'
#!/bin/bash
# In front of other windows, and never waiting forever if nobody is at the Mac.
exec /usr/bin/osascript -e 'tell me to activate' -e 'text returned of (display dialog "Lightpath needs your Mac password to update its Wi-Fi helper." default answer "" with hidden answer with title "Lightpath" with icon caution giving up after 180)' 2>/dev/null
ASKPASS
            chmod 700 "$WORK/askpass"
            export SUDO_ASKPASS="$WORK/askpass"
            SUDO=(sudo -A)
            "${SUDO[@]}" -v 2>/dev/null && ROOT_STATE=ok
        fi
    fi
    [ "$ROOT_STATE" = ok ] || return 1
    "${SUDO[@]}" "$@"
}
same_file() { [ -f "$2" ] && cmp -s "$1" "$2"; }

# ------------------------------------------------------------------ Tailscale
if [ ! -d "$TS_APP" ]; then
    say "Installing Tailscale…"
    curl -fL --progress-bar "https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg" -o "$WORK/tailscale.pkg"
    as_root installer -pkg "$WORK/tailscale.pkg" -target / >/dev/null \
        || die "Tailscale needs your Mac password to install. Run the installer again."
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
{ rm -rf /Applications/Moonlight.app 2>/dev/null || as_root rm -rf /Applications/Moonlight.app; } \
    && { ditto "$WORK/mnt/Moonlight.app" /Applications/Moonlight.app 2>/dev/null || as_root ditto "$WORK/mnt/Moonlight.app" /Applications/Moonlight.app; } \
    || { hdiutil detach "$WORK/mnt" >/dev/null 2>&1; die "Couldn't replace /Applications/Moonlight.app. Run the installer again."; }
hdiutil detach "$WORK/mnt" >/dev/null
xattr -dr com.apple.quarantine /Applications/Moonlight.app 2>/dev/null || true

# ------------------------------------------------------------------ lightpath command
# The real command lives in your Library (always updatable without a password); the Lightpath
# apps call it there directly. /usr/local/bin/lightpath is a tiny pointer to it for Terminal.
say "Installing the lightpath command…"
LP_DIR="$HOME/Library/Lightpath"
LP_BIN="$LP_DIR/lightpath"
mkdir -p "$LP_DIR"
install -m 755 "$WORK/lightpath" "$LP_BIN"
printf '#!/bin/bash\n# Lightpath: the command lives in your Library so updates need no password.\nexec "$HOME/Library/Lightpath/lightpath" "$@"\n' > "$WORK/lightpath-shim"

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
    osacompile -o "$app" -e "do shell script \"'$LP_BIN' $2 >> /tmp/lightpath.log 2>&1 &\"" >/dev/null
    cp /Applications/Moonlight.app/Contents/Resources/*.icns "$app/Contents/Resources/applet.icns" 2>/dev/null || true
    touch "$app"
}
make_app "Lightpath" "connect"
make_app "Lightpath Steam" "steam"

# ------------------------------------------------------------------ system-wide pieces (password)
NEED_PASSWORD_LATER=0
if ! same_file "$WORK/lightpath-shim" /usr/local/bin/lightpath; then
    if { [ -w /usr/local/bin/lightpath ] || { [ ! -e /usr/local/bin/lightpath ] && [ -w /usr/local/bin ]; }; } \
            && cp "$WORK/lightpath-shim" /usr/local/bin/lightpath 2>/dev/null; then
        chmod 755 /usr/local/bin/lightpath
    elif as_root mkdir -p /usr/local/bin && as_root install -m 755 "$WORK/lightpath-shim" /usr/local/bin/lightpath; then
        :
    else
        NEED_PASSWORD_LATER=1
    fi
fi
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
            && same_file "$WORK/awdl-guard.plist" "$PLIST" && pgrep -x awdl-guard >/dev/null; then
        say "Wi-Fi helper is up to date."
    else
        say "Installing the Wi-Fi helper…"
        if as_root mkdir -p "$LIBEXEC" \
                && as_root install -m 755 "$WORK/awdl-guard" "$WORK/lightpath-wake" "$LIBEXEC/" \
                && as_root install -o root -g wheel -m 644 "$WORK/awdl-guard.plist" "$PLIST"; then
            as_root xattr -d com.apple.quarantine "$LIBEXEC/awdl-guard" "$LIBEXEC/lightpath-wake" 2>/dev/null || true
            as_root launchctl bootout system/com.lightpath.awdl-guard 2>/dev/null || true
            as_root launchctl bootstrap system "$PLIST" || warn "The Wi-Fi helper didn't start; it will on the next restart."
        else
            NEED_PASSWORD_LATER=1
        fi
    fi
else
    warn "Helper binaries aren't published yet; skipping the Wi-Fi helper for now."
fi

# ------------------------------------------------------------------ pair
if defaults read com.moonlight-stream.Moonlight 2>/dev/null | grep -q srvcert; then
    say "Already paired with your PC."
    PAIRED=1
else
    say "Pairing with your PC (automatic)…"
    if "$LP_BIN" pair; then
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
[ "$NEED_PASSWORD_LATER" = 0 ] || warn "Everything is updated except a system piece that needs your Mac password; it'll ask again next update (everything works meanwhile)."

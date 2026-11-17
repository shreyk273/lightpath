# Lightpath

Stream a Linux gaming PC to a MacBook with the lowest latency and the sharpest picture the hardware
allows: at home on the same Wi-Fi, or from anywhere else.

Built on open source ([Sunshine](https://github.com/LizardByte/Sunshine) on the PC,
[Moonlight](https://github.com/moonlight-stream/moonlight-qt) on the Mac,
[Tailscale](https://github.com/tailscale/tailscale) between them), with Lightpath's own changes to
all three layers.

## Use it

**Set up the Mac (once).** Open Terminal and paste:

```sh
curl -fsSL https://raw.githubusercontent.com/shreyk273/lightpath/main/mac/install.sh | bash
```

It asks for your Mac password once, installs everything, and pairs with the PC by itself.

**Stream.** Open **Lightpath** (Spotlight or Applications). It wakes the PC if it's asleep,
picks the fastest route, and opens the PC's desktop full screen at your Mac's exact resolution
and 120 Hz. **Lightpath Steam** goes straight to Steam Big Picture.
Press **Ctrl+Option+Shift+Q** to stop. **Ctrl+Option+Shift+S** shows live performance stats.

In Terminal, `lightpath status` shows how the PC is reachable and how fast the link is;
`lightpath wake` just wakes it.

## What makes it fast

### On the PC (patched Sunshine, `patches/sunshine/`)

| Change | Why it matters |
|---|---|
| **Virtual display matched to the client** (`capture = mutter`) | For every stream GNOME creates a monitor with exactly the Mac's resolution and refresh rate (3024x1890 @ 120 Hz on a 14" MacBook Pro), makes it the only display, captures it zero-copy (DMA-BUF into NVENC) and removes it afterwards, restoring the projector/monitor. No scaling anywhere, frames come from a 120 Hz compositor clock and are encoded the instant they're rendered. |
| **NVENC split-frame encoding on Linux** | Upstream only offers it on Windows. On GPUs with two NVENC engines (RTX 4090) each frame is encoded as two halves in parallel: **3.6 → 2.2 ms per frame**. |
| **Route-MTU packet sizing** | Video packets are capped to what fits the route to the client (1280-byte MTU over Tailscale), so they are never IP-fragmented. |
| **PipeWire fixes** | Uninitialized stream state could crash Sunshine on teardown; a format renegotiation right after start was treated as a dead stream (1 s freeze + full re-init). |

### On the Mac (patched Moonlight, `patches/moonlight-qt/`, `patches/moonlight-common-c/`)

| Change | Why it matters |
|---|---|
| **awdl-guard** (`mac/awdl-guard/`) | macOS's AirDrop radio (AWDL) makes Wi-Fi hop channels several times a second, causing periodic lag spikes. A tiny root daemon turns it off only while a stream is running and restores it afterwards. |
| **VPN-aware packet size** | Over Tailscale, packets fill exactly one 1280-byte tunnel MTU instead of 1024 bytes (or fragmenting on IPv6). |
| **Prefer the home network** | Moonlight no longer sticks to the Tailscale route when you're back home. |
| **Latency-critical activity** | macOS never applies App Nap or timer coalescing to Moonlight while streaming. |
| **Native size below the notch** | The stream is sized to the Mac's screen area below the notch, so every pixel maps 1:1. |

### Between them

- **Same Wi-Fi:** direct LAN, HEVC at 150 Mbps.
- **Elsewhere:** Tailscale (WireGuard, peer-to-peer where possible). `lightpath` measures the
  bandwidth from the PC first and sets the bitrate to 65% of it, using AV1 (better quality per bit,
  hardware-decoded on M3 and newer).
- **Pairing without PINs:** the PC's agent approves Moonlight's pairing request only for devices
  signed in to the same Tailscale account.
- **Wake from the Mac:** Wake-on-Wi-Fi magic packets (LAN broadcast and unicast, plus the PC's
  global IPv6 addresses and public IPv4 for waking from outside).

## Measured

PC streaming to itself (Moonlight on the same machine), 3024x1890 @ 120 fps, 150 Mbps, RTX 4090:

| Encoder setting | Host processing per frame (avg / max) |
|---|---|
| HEVC, preset P1, split-frame **(default)** | **2.2 / 4.0 ms** |
| HEVC, preset P1, single engine (upstream Linux behaviour) | 3.6 / 6.3 ms |
| AV1, preset P1, split-frame (used away from home) | 2.4 / 4.9 ms |
| HEVC, preset P4, split-frame | 4.3 / 9.0 ms |
| AV1, preset P4, split-frame | 3.6 / 6.6 ms |

120 fps sustained, 0 % frames lost to the network, stream start ~0.3 s.
Reproduce with `host/tools/loopback-bench.sh`.

## Layout

```
host/                   Linux host (CachyOS/Arch, GNOME, NVIDIA)
  install.sh            everything below, in order
  setup-root.sh         packages, firewall (ufw/nftables), Tailscale, uinput, sysctl
  build-sunshine.sh     fetch upstream Sunshine, apply patches, build + install as a package
  config/               tuned sunshine.conf and apps.json
  agent/                lightpath-agent: pairing approval, wake intent, host facts, speed test
  pkg/                  PKGBUILD for sunshine-lightpath
  tools/                loopback benchmark
mac/
  install.sh            one-line Mac installer
  lightpath             the Mac command (connect / steam / wake / status / pair / set)
  awdl-guard/           AWDL suppression daemon (C)
  wake/                 magic packet sender (C)
patches/                Lightpath's changes on top of the pinned upstream commits
.github/workflows/      builds the Mac app + helpers and publishes the "mac-latest" release
```

## Ports

Sunshine's ports are shifted by +1000 (47998/udp is taken by another service on the host):
48984/tcp, 48989/tcp, 48990/tcp (web UI), 49010/tcp, 48998-49010/udp. The agent listens on
48900/tcp, reachable only through Tailscale.

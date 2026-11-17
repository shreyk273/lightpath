# Lightpath

Stream a Linux gaming PC to a MacBook with the lowest latency and the sharpest picture the hardware
allows, at home on the same Wi-Fi or from anywhere else.

Built on open source: [Sunshine](https://github.com/LizardByte/Sunshine) (host),
[Moonlight](https://github.com/moonlight-stream/moonlight-qt) (client) and
[Tailscale](https://github.com/tailscale/tailscale) (private network), with Lightpath's own changes
on top.

## What Lightpath changes

### Host (Sunshine, patched: `patches/sunshine/`)

| Change | Why it matters |
|---|---|
| **GNOME virtual display** (`capture = mutter`) | For every stream Mutter creates a virtual monitor with exactly the client's resolution and refresh rate (e.g. 3024x1964 @ 120 Hz for a 14" MacBook Pro), makes it the only display, captures it zero-copy (DMA-BUF into NVENC) and removes it afterwards, restoring the physical screens. No scaling on either side, frames paced by a 120 Hz compositor clock, encode starts the moment a frame is ready. No portal dialogs. |
| **NVENC split-frame encoding on Linux** | Upstream only exposes `nvenc_split_encode` on Windows. On GPUs with two NVENC engines (RTX 4090) each frame is encoded as two halves in parallel. |
| **Route-MTU packet sizing** | Video packets are capped to what fits through the route to the client (1280-byte MTU over Tailscale), so they are never IP-fragmented. |
| **PipeWire fixes** | Uninitialized stream state could crash Sunshine when a capture was torn down; a brief format renegotiation pause right after start was treated as a dead stream and cost a 1 s freeze plus a full re-init. |

### Measured (PC streaming to itself, 3024x1964 @ 120 fps, HEVC 150 Mbps, RTX 4090)

| Metric | Result |
|---|---|
| Frame rate | 120 fps sustained |
| Host processing (capture + convert + encode) | 2.2 ms average, 3.7 ms max |
| Stream start | ~0.3 s from launch to first frame |
| Frames dropped | 0 % (network), 0.17 % (jitter) |

## Layout

```
host/                 Linux host (CachyOS/Arch, GNOME, NVIDIA)
  setup-root.sh       one-time root setup: packages, firewall, Tailscale, uinput, sysctl
  build-sunshine.sh   fetch upstream Sunshine, apply patches, build + install as a package
  config/             tuned sunshine.conf and apps.json
  pkg/                PKGBUILD for sunshine-lightpath
  tools/              loopback benchmark and helpers
patches/sunshine/     Lightpath's Sunshine changes on top of UPSTREAM_COMMIT
```

## Ports

Sunshine's ports are shifted by +1000 (47998/udp is taken by another service on the host):
48984/tcp, 48989/tcp, 48990/tcp (web UI), 49010/tcp, 48998-49010/udp.

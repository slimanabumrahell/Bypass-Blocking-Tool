# Bypass-Blocking-Tool

Root utility for Android that routes **all** device traffic (Wi-Fi + Mobile Data) through a Cloudflare WARP tunnel (sing-box TUN), changing your IP and bypassing ISP / DPI blocks. No need to install the 1.1.1.1 app.

## Root Network Unblocker (v2.1)

- **Standalone:** `install` downloads sing-box and registers a free WARP account (saved to `/data/adb/warp.conf`).
- **Full tunnel:** everything goes through WARP, DNS included (hijacked and resolved via 1.1.1.1 inside the tunnel).
- **No IPv6 leaks:** IPv6 is dropped while running (loopback kept).
- **Safe restore:** your previous Private DNS and ip6tables policies are saved and restored on `stop`.
- **Optional HTTP proxy chaining:** device → WARP → your HTTP proxy.
- **Autostart at boot** (Magisk / KernelSU / APatch).

## Setup (Termux)

```sh
curl -fsSL https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/unblock.sh -o "$HOME/unblock.sh"
su -c "cp $HOME/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh"
su -c 'sh /data/local/tmp/unblock.sh install'     # once
su -c 'sh /data/local/tmp/unblock.sh start'
```

## Commands

| Command | What it does |
|---|---|
| `install` | Download core + register WARP (once) |
| `start` / `stop` / `restart` | Control the tunnel |
| `status` | Shows running state, public IP, country, WARP on/off |
| `logs` | Last 40 lines of sing-box log |
| `renew` | Register a fresh WARP account |
| `autostart on\|off` | Start at boot |
| `uninstall` | Remove everything (`PURGE=1` also deletes credentials) |

## HTTP proxy chaining

```sh
su -c 'PROXY_IP=1.2.3.4 PROXY_PORT=8080 sh /data/local/tmp/unblock.sh start'
su -c 'PROXY_IP=1.2.3.4 PROXY_PORT=8080 PROXY_USER=user PROXY_PASS=pass sh /data/local/tmp/unblock.sh start'
```

For persistent settings (also used by autostart) create `/data/adb/unblock.conf`:

```sh
PROXY_IP=1.2.3.4
PROXY_PORT=8080
```

## Troubleshooting

- **Started but no internet / `warp=off`:** your ISP may block UDP 2408. Try `WARP_PORT=500`, `1701` or `4500`.
- **Still no traffic:** try `TUN_STACK=gvisor`.
- **Download blocked:** pass a mirror link with `SB_URL=...`.
- **IPv6-only mobile networks** (464XLAT) may break because IPv6 is dropped.
- Check errors with `logs`.

## Environment variables

`WARP_PORT`, `WARP_ENDPOINT`, `TUN_STACK`, `SB_VER`, `SB_URL`, `FORCE=1`, `PROXY_*`.

# Bypass-Blocking-Tool

Root utility for Android (run from Termux) that routes all device traffic through Cloudflare WARP, a proxy / proxy link, or a local DPI-bypass engine.

## Root Network Unblocker & DPI Bypass Suite (v3.0)

Every mode uses the same path: `apps -> tun0 (sing-box) -> local engine -> internet`.

| Mode | Engine | What it does |
|---|---|---|
| `warp` | wireproxy | Cloudflare WARP (WireGuard) as a local SOCKS5 on `127.0.0.1:40000` |
| `dpi` | ByeDPI (`ciadpi`) | Local SNI split / packet fragmentation on `127.0.0.1:10800`, no external server |
| `proxy` | Xray-core / sing-box | SOCKS4, SOCKS5, HTTP, HTTPS, or a `vless://` `vmess://` `trojan://` `ss://` link (Xray on `127.0.0.1:10808`) |
| `all` | WARP + proxy | `device -> WARP -> proxy -> internet` |

Extras: DNS-over-HTTPS (1.1.1.1) for all DNS, IPv6 leak block, automatic WARP endpoint discovery (13 endpoint/port pairs), TLS fragmentation and uTLS fingerprint (`chrome`) for Xray links, Private DNS restore on stop.

Safety: engines are started and tested **before** any network setting is changed. If the tunnel is up but no traffic passes, everything is rolled back automatically.

## Setup (Termux, rooted device)

### 1. Install

```sh
pkg install -y curl unzip && mkdir -p ~/unblocker && cd ~/unblocker && for f in unblock.sh start.sh stop.sh; do curl -fsSLO "https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f"; done && for f in unblock.sh start.sh stop.sh; do sh -n $f || echo "BROKEN FILE: $f"; done && su -c "cp $PWD/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh && sh /data/local/tmp/unblock.sh install"
```

If you see `BROKEN FILE`, the copy on GitHub is damaged. Re-upload the files from the original download, not by copy/paste from a chat window (chat renderers strip `#`, `$` and `|` characters).

### 2. Use

```sh
su -c 'sh /data/local/tmp/unblock.sh warp on'    # WARP
su -c 'sh /data/local/tmp/unblock.sh dpi on'     # local DPI bypass
su -c 'sh /data/local/tmp/unblock.sh proxy set'  # configure a proxy or link
su -c 'sh /data/local/tmp/unblock.sh proxy on'   # proxy only
su -c 'sh /data/local/tmp/unblock.sh all on'     # WARP + proxy
su -c 'sh /data/local/tmp/unblock.sh stop'       # stop everything, restore network
```

Or with the wrappers: `sh start.sh warp`, `sh start.sh dpi`, `sh start.sh all`, `sh stop.sh`.

## Commands

| Command | Description |
|---|---|
| `install` | Download engines, register a free WARP account |
| `warp on \| off` | Cloudflare WARP |
| `dpi on \| off` | ByeDPI packet fragmentation |
| `proxy set` | Interactive setup (SOCKS4/5, HTTP/S, vless/vmess/trojan/ss link) |
| `proxy on \| off \| show \| clear` | Proxy mode |
| `all on \| off` | WARP + proxy chained |
| `start [warp\|dpi\|proxy\|all]` | Start a mode (no argument = auto) |
| `stop` | Stop all engines, restore network settings |
| `status` | Engines, mode, public IP, country |
| `doctor` | Diagnostics, file integrity check, recent logs |
| `selfcheck` | Detect damaged script files |
| `renew` | Register a new WARP account |

## Settings (optional)

Put overrides in `/data/adb/unblock.conf` (shell syntax), for example:

```sh
DPI_ARGS='-s 1+s -d 1+s -r 1+s'   # ByeDPI options; change if your ISP still blocks
WARP_ENDPOINT=162.159.192.1       # fix the WARP endpoint (WARP_PORT=2408)
XRAY_FRAGMENT=0                   # disable TLS fragmentation for links
BYEDPI_URL='https://.../ciadpi'   # direct download link for the ByeDPI binary
ENGINE_UID=2000                   # user the engines run as (excluded from the tunnel)
PRIVATE_DNS=keep                  # do not touch Android Private DNS
BLOCK_IPV6=0                      # do not block IPv6
```

## Notes and limitations

- WARP and ByeDPI run as SOCKS5 engines, so **UDP traffic (QUIC, voice calls, games) does not pass through them**; apps fall back to TCP. Proxy links through Xray do support UDP.
- If ByeDPI cannot be downloaded automatically, `install` prints how to build it in Termux (`pkg install git clang make`).
- Requires a root manager that supports `su <uid> -c`. If yours does not, set `ENGINE_UID=0`.
- Logs: `/data/local/tmp/unblocker/*.log` (or `sh unblock.sh logs`).

## Responsible use

This tool routes your device traffic. Make sure your use complies with applicable laws and terms of service.

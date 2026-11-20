# Bypass-Blocking-Tool

<p align="center">
  <b>Root Network Utility for Android</b><br>
  <sub>Version 3.1 · Termux · Root required</sub>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Version-3.1-blue?style=for-the-badge">
  <img src="https://img.shields.io/badge/Platform-Android-green?style=for-the-badge">
  <img src="https://img.shields.io/badge/Environment-Termux-black?style=for-the-badge">
  <img src="https://img.shields.io/badge/Root-Required-orange?style=for-the-badge">
</p>

---

## Overview

A root shell script for Android that routes **all device traffic** (Wi-Fi and mobile data) through a TUN interface managed by [sing-box](https://github.com/SagerNet/sing-box), so blocked sites open and your public IP changes. It can use Cloudflare WARP, your own proxy / Xray link, a local ByeDPI anti-DPI engine, or a combination.

Everything is one script: `/data/local/tmp/unblock.sh`. It downloads its own engines and registers a free WARP account, so the 1.1.1.1 app is **not** needed.

## Modes

| Mode | Command | Path |
|------|---------|------|
| WARP | `warp on` / `warp off` | device → WARP → internet |
| Proxy | `proxy on` / `proxy off` | device → proxy (SOCKS4/5, HTTP/S) or Xray link → internet |
| Anti-DPI | `dpi on` / `dpi off` | device → ByeDPI → internet |
| Combined | `all on` / `all off` | WARP + proxy/Xray/ByeDPI together |

With a **remote** proxy the combined path is `device → WARP → proxy`. With a **local** engine (Xray, ByeDPI) WARP wraps the engine's own outgoing connection instead.

## Components

| Component | Role |
|-----------|------|
| sing-box (pinned `1.10.1`) | TUN, routing, DNS, WARP (WireGuard) |
| Xray-core | vless / vmess / trojan / ss links, with TLS fragmentation |
| ByeDPI (`ciadpi`) | local SOCKS5 anti-DPI packet manipulation |
| wireproxy | optional userspace WARP engine (`WARP_ENGINE=wireproxy`) |

## Requirements

- Rooted Android device (Magisk / KernelSU) with TUN support in the kernel (`/dev/net/tun`)
- [Termux](https://termux.dev) with `curl` and `unzip`
- Internet access to GitHub for the first install (see *Offline install* below if GitHub is blocked)

## Setup (Termux)

One-time install:

```sh
pkg install -y curl unzip && mkdir -p ~/unblocker && cd ~/unblocker && for f in unblock.sh start.sh stop.sh; do curl -fsSLO "https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f"; done && su -c "cp $PWD/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh && sh /data/local/tmp/unblock.sh install"
```

`install` downloads the engines and creates the WARP account in `/data/adb/warp.conf` (root-only, mode 600).

## Usage

```sh
su -c 'sh /data/local/tmp/unblock.sh warp on'      # WARP only
su -c 'sh /data/local/tmp/unblock.sh warp off'

su -c 'sh /data/local/tmp/unblock.sh proxy set'    # interactive wizard (saved to /data/adb/unblock.conf)
su -c 'sh /data/local/tmp/unblock.sh proxy on'
su -c 'sh /data/local/tmp/unblock.sh proxy off'

su -c 'sh /data/local/tmp/unblock.sh dpi on'       # ByeDPI
su -c 'sh /data/local/tmp/unblock.sh dpi off'

su -c 'sh /data/local/tmp/unblock.sh all on'       # WARP + proxy together
su -c 'sh /data/local/tmp/unblock.sh stop'         # stop everything, restore network settings
```

Other commands:

| Command | What it does |
|---------|--------------|
| `status` | state, public IP, country, WARP on/off, DNS check |
| `logs` | last lines of the sing-box / Xray / ByeDPI / wireproxy logs |
| `doctor` | device, engines, account, endpoint, DNS servers |
| `renew` | register a new WARP account (restarts the tunnel if it was running) |
| `autostart on\|off` | start at boot through Magisk / KernelSU `service.d` |
| `uninstall` | remove engines and config (`PURGE=1` also removes the account and saved proxy) |
| `restart` | stop and start again in the same mode |

`start.sh` and `stop.sh` are thin wrappers that elevate with `su` themselves, for example `sh ~/unblocker/start.sh warp` and `sh ~/unblocker/stop.sh`.

One-shot proxy without the wizard:

```sh
su -c 'PROXY_TYPE=socks5 PROXY_IP=1.2.3.4 PROXY_PORT=1080 sh /data/local/tmp/unblock.sh proxy on'
```

## Configuration

Optional file `/data/adb/unblock.conf` (shell syntax). Environment variables on the command line override it.

| Variable | Default | Meaning |
|----------|---------|---------|
| `WARP_ENGINE` | `sing-box` | `wireproxy` uses the userspace engine instead |
| `WARP_ENDPOINT`, `WARP_PORT` | auto | pin a WARP endpoint (otherwise the best reachable one is searched) |
| `WARP_MTU` | `1360` | WireGuard MTU (1200–1500) |
| `PRIVATE_DNS` | `off` | `keep` leaves Android Private DNS untouched |
| `DNS_HIJACK` | `1` | `0` restores the old DNS routing (raw forwarding) |
| `TLS_FRAG` | `1` | Xray TLS ClientHello fragmentation |
| `DPI_ARGS` | built-in | ByeDPI arguments |
| `BLOCK_IPV6` | `1` | `0` keeps IPv6 (auto-skipped on IPv6-only/464XLAT networks) |
| `FAST_START` | unset | skip the endpoint re-check on start |
| `KEEP_ON_FAIL` | unset | keep the tunnel running after a failed start, for inspection |
| `SB_VER`, `XRAY_VER`, `BYEDPI_VER`, `WP_VER` | pinned | engine versions |
| `SB_URL`, `XRAY_URL`, `BYEDPI_URL`, `WP_URL` | — | custom download URLs |

> The generated sing-box config targets **1.10.x**. Newer sing-box versions removed some fields it uses (`inet4_address`, the WireGuard and DNS outbounds), so keep `SB_VER` on 1.10.x unless you also update the config builder.

## Files

| Path | Content |
|------|---------|
| `/data/local/tmp/unblock.sh` | the script |
| `/data/local/tmp/unblocker/` | engines, generated configs, logs, state |
| `/data/adb/warp.conf` | WARP credentials (private key) |
| `/data/adb/unblock.conf` | saved proxy and settings |
| `/data/adb/service.d/99-unblock.sh` | autostart hook (when enabled) |

## Offline install (GitHub blocked)

Download the engine archives by any other means, put them on the phone, and point the script at them with `SB_URL=file:///…`, `XRAY_URL=…`, `BYEDPI_URL=…`, `WP_URL=…` (any URL `curl` understands).

## Troubleshooting

- **Start fails / no internet:** `su -c 'sh /data/local/tmp/unblock.sh logs'`, then try another WARP port: `WARP_PORT=500` (or 854, 1701, 4500).
- **Sites open by IP but not by name:** run `doctor` and check the DNS line; try `PRIVATE_DNS=keep`.
- **Network stuck after a crash:** `su -c 'sh /data/local/tmp/unblock.sh stop'` removes `tun0`, the routing rules, the IPv6 rule and restores Private DNS.
- **Xray link not accepted:** supported transports are `tcp`, `ws`, `grpc` (vless / vmess / trojan / ss).

## Known limitations

- **ByeDPI mode is experimental.** ByeDPI's own outgoing connections are not excluded from `tun0`, so `dpi on` may loop on some devices. Report `logs` output if it does.
- Xray's server address is resolved once at start (DoH through `1.1.1.1`, then `ping`); CDN servers that rotate IPs may need a restart.
- wireproxy has no WARP "reserved" bytes support and no SOCKS5 UDP; DNS goes over TCP in that mode.
- The script modifies routing, IPv6 and Private DNS while running; `stop` restores them.

## Changelog

**3.1**
- ByeDPI download fixed (correct release asset name and architecture names; default `0.17.3`).
- wireproxy config fixed (`PersistentKeepalive`, `AllowedIPs`); DNS over TCP in that mode.
- Xray TLS fragmentation now actually used (`dialerProxy` chain); previously the outbound was defined but never referenced.
- vmess links in pretty-printed JSON (v2rayN) are parsed; base64url/unpadded `ss://` links, grpc `serviceName`, ws `host`, IPv6 literals and unsupported transports handled.
- DNS is hijacked into sing-box's resolver instead of being forwarded raw to the phone's resolver.
- Local engines (Xray / wireproxy) no longer loop into `tun0`; they are never detoured through WARP as if they were remote.
- A start that dies half-way now restores IPv6 rules, Private DNS and routing.
- Autostart hook no longer blocks other `service.d` scripts.

---

## License

Distributed under the MIT License. See the `LICENSE` file for details.

<p align="center">
  <b>Bypass-Blocking-Tool · v3.1</b><br>
  <sub>Android · Termux · Root Network Utility</sub>
</p>

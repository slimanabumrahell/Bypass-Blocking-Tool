# Bypass-Blocking-Tool

An all-in-one Android root utility to bypass ISP restrictions, DPI censorship, and blocked websites across Wi-Fi and Mobile Data via Cloudflare WARP, Proxy Chaining, and Local Packet Fragmentation.

## Root Network Unblocker & DPI Bypass Suite (v3.0)

Powerful multi-engine root utility for Android (run from Termux) that routes all device traffic through Cloudflare WARP, Xray-core/sing-box proxies, Wireproxy, or ByeDPI (local DPI packet splitting).

- **100% Standalone:** Downloads required engines (`sing-box`, `Xray-core`, `ByeDPI`) and registers a free WARP account (`install`).
- **Multi-Engine Support:**
  - **Cloudflare WARP:** Encrypted WireGuard tunnel.
  - **ByeDPI Engine (`dpi on`):** Local SNI fragmentation and TCP packet splitting to bypass DPI censorship **without external servers or speed penalty**.
  - **Advanced Proxy (`proxy set`):** Supports `SOCKS4`, `SOCKS5`, `HTTP`, `HTTPS`, `VLESS`, `VMess`, `Trojan`, and `Shadowsocks`.
- **Speed & Anti-Blocking:** Optimized MTU, DNS-over-HTTPS (DoH) anti-poisoning, and automatic endpoint discovery.
- **Fail-safe & Restore:** Automatic rollback if a tunnel fails to verify traffic, clean IPv6 leak protection, and Private DNS state restoration.

## Setup & Usage (Termux)

Requires a rooted Android device and Termux.

### 1. Install (One-time setup)

Run this single command in Termux:

```sh
pkg install -y curl && mkdir -p ~/unblocker && cd ~/unblocker && for f in unblock.sh start.sh stop.sh; do curl -fsSLO "https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f"; done && su -c "cp $PWD/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh && sh /data/local/tmp/unblock.sh install"
```

### 2. WARP Only (Start / Stop)

- **Start WARP:**
```sh
su -c 'sh /data/local/tmp/unblock.sh warp on'
```
- **Stop WARP:**
```sh
su -c 'sh /data/local/tmp/unblock.sh warp off'
```

### 3. Local DPI Packet Splitting (No Speed Drop / No External Server)

Bypasses ISP site blocking locally via ByeDPI packet fragmentation:
- **Start DPI Bypass:**
```sh
su -c 'sh /data/local/tmp/unblock.sh dpi on'
```
- **Stop DPI Bypass:**
```sh
su -c 'sh /data/local/tmp/unblock.sh dpi off'
```

### 4. WARP + Proxy Together (Start / Stop)

Traffic path: `device -> WARP -> proxy -> internet`.

- **Configure & Start Proxy + WARP:**
```sh
su -c 'sh /data/local/tmp/unblock.sh proxy set'
su -c 'sh /data/local/tmp/unblock.sh all on'
```
- **Stop Both:**
```sh
su -c 'sh /data/local/tmp/unblock.sh all off'
```

## Commands Summary

| Command | Description |
|---|---|
| `warp on \| off` | Control Cloudflare WARP tunnel |
| `dpi on \| off` | Control local ByeDPI packet fragmentation engine |
| `proxy set` | Interactive configuration (SOCKS4/5/HTTP/HTTPS/VLESS/VMess/Trojan/SS) |
| `proxy on \| off` | Control proxy mode |
| `all on \| off` | Control WARP + Proxy chained mode |
| `status` | View connection, public IP, country, and active engine statuses |
| `doctor` | Run diagnostic checks and print logs |
| `stop` | Emergency stop all engines and restore network settings |

## Responsible Use

This tool routes your device traffic. Ensure usage complies with applicable terms of service and laws.

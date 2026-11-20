# Bypass-Blocking-Tool

An all-in-one Android root utility to bypass ISP restrictions, DPI censorship, and blocked websites across Wi-Fi and Mobile Data using `sing-box`, `Xray-core`, `ByeDPI`, `wireproxy`, and Cloudflare WARP.

## Root Network Unblocker (v3.0)

Root utility for Android (run from Termux) that routes all device traffic through Cloudflare WARP, proxies, Xray links (`vless://`, `vmess://`, `trojan://`, `ss://`), and/or ByeDPI packet fragmentation.

- **Multi-Engine Power:** Combines `sing-box` (TUN & routing), `Xray-core` (VLESS/VMess/Trojan/SS + TLS fragmentation), `ByeDPI / ciadpi` (Anti-DPI packet splitting), and `wireproxy` (userspace WARP SOCKS5).
- **Composable & Independent Modes:** Run WARP alone, proxy/Xray/ByeDPI alone, or layer them together (`device -> WARP -> proxy/Xray/ByeDPI`), and stop either side without dropping the other.
- **No IPv6 Leaks:** IPv6 is rejected with `ip6tables` in its own chain and removed cleanly on stop.
- **Fail-safe & Safe Restore:** Automatically rolls back on failed starts and restores Private DNS and network state on stop.
- **Built-in Diagnostics:** `doctor` inspects engines, WARP credentials, saved proxy, `tun0`, and DNS servers.

## Setup & Usage (Termux)

Requires a rooted device and Termux.

### 1. Install (One-time setup)

pkg install -y curl unzip && mkdir -p ~/unblocker && cd ~/unblocker && for f in unblock.sh start.sh stop.sh; do curl -fsSLO "https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f"; done && su -c "cp $PWD/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh && sh /data/local/tmp/unblock.sh install"

### 2. WARP Only (Start / Stop)

- **Start WARP:**

su -c 'sh /data/local/tmp/unblock.sh warp on'

- **Stop WARP:**

su -c 'sh /data/local/tmp/unblock.sh warp off'

### 3. Proxy / Xray Link (Start / Stop)

- **Set proxy or Xray link (`socks5`, `socks4`, `http`, `https`, `vless://`, `vmess://`, `trojan://`, `ss://`):**

su -c 'sh /data/local/tmp/unblock.sh proxy set'

- **Start Proxy / Xray:**

su -c 'sh /data/local/tmp/unblock.sh proxy on'

- **Stop Proxy / Xray:**

su -c 'sh /data/local/tmp/unblock.sh proxy off'

### 4. ByeDPI Anti-DPI (Start / Stop)

- **Start ByeDPI:**

su -c 'sh /data/local/tmp/unblock.sh dpi on'

- **Stop ByeDPI:**

su -c 'sh /data/local/tmp/unblock.sh dpi off'

### 5. WARP + Proxy / Xray / ByeDPI Together (Start / Stop)

- **Start both:**

su -c 'sh /data/local/tmp/unblock.sh all on'

- **Stop both:**

su -c 'sh /data/local/tmp/unblock.sh all off'

## Commands Reference

| Command | Description |
|---|---|
| `warp on\|off` | Start or stop WARP only (keeps proxy/DPI running if layered) |
| `proxy on\|off\|set\|clear\|status` | Manage proxy or Xray link (`vless://`, `vmess://`, `trojan://`, `ss://`) |
| `dpi on\|off` | Start or stop ByeDPI Anti-DPI packet fragmentation |
| `all on\|off` | Start or stop WARP + proxy/Xray/ByeDPI together |
| `status` | Show active engines, mode, public IP, country, WARP state, and DNS check |
| `doctor` | Full system and engine diagnostics |
| `logs` | View logs for `sing-box`, `Xray-core`, `ByeDPI`, and `wireproxy` |
| `renew` | Register a new WARP account |
| `autostart on\|off` | Enable or disable start on boot |
| `stop` | Stop everything and clean up leftover routes, `tun0`, IPv6 rules, and Private DNS |
| `uninstall` | Remove scripts and working directory (`PURGE=1` removes credentials and config) |

## Environment Variables

`PROXY_TYPE`, `PROXY_URI`, `PROXY_IP`, `PROXY_PORT`, `PROXY_USER`, `PROXY_PASS`, `PROXY_SNI`, `PROXY_INSECURE`, `WARP_ENGINE` (`sing-box`|`wireproxy`), `WARP_ENDPOINT`, `WARP_PORT`, `WARP_MTU`, `DPI_ARGS`, `TUN_STACK`, `FAST_START`, `TLS_FRAG`, `SB_VER`, `XRAY_VER`, `BYEDPI_VER`, `WP_VER`, `BLOCK_IPV6`, `HIDE_PASS`, `PRIVATE_DNS`, `KEEP_ON_FAIL`, `DNS_TRIES`, `FORCE=1`, `PURGE=1`.

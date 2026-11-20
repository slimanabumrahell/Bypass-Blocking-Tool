# Bypass-Blocking-Tool

An all-in-one Android root utility to bypass ISP restrictions, DPI censorship, and blocked websites across Wi-Fi and Mobile Data via an automated Cloudflare WARP tunnel.

## Root Network Unblocker (v2.6)

Root utility for Android (run from Termux) that routes all device traffic through Cloudflare WARP and/or your own proxy (`device -> WARP -> proxy -> internet`), changing your IP and bypassing ISP / DPI blocks. No need to install the 1.1.1.1 app.

- **100% Standalone:** Automatically downloads the core engine (`sing-box`) and registers a free WARP account (`install`).
- **WARP & Layered Proxy:** Run WARP alone, or layer your proxy on top of WARP (`device -> WARP -> proxy`).
- **Speed & Stability Focused:** Uses saved working WARP endpoints first, supports `FAST_START=1` and `WARP_MTU`, and avoids unnecessary delays.
- **No IPv6 Leaks:** IPv6 is rejected with `ip6tables` (in its own chain, removed again on stop).
- **Proxy Support:** `socks5`, `socks4`, `http`, and `https`, with or without authentication.
- **Fail-safe:** If a start does not pass traffic, normal network settings are restored automatically (or a sensible fallback is used).
- **Safe Restore:** Your previous Private DNS setting is restored on stop.
- **Built-in diagnostics:** `doctor` prints everything needed to find a problem (no passwords).

## Setup & Usage (Termux)

Requires a rooted device and Termux.

### 1. Install (One-time setup)

One command: downloads the scripts, installs the engine, and registers WARP:

```sh
pkg install -y curl && mkdir -p ~/unblocker && cd ~/unblocker && for f in unblock.sh start.sh stop.sh; do curl -fsSLO "[https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f](https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f)"; done && su -c "cp $PWD/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh && sh /data/local/tmp/unblock.sh install"
```

**Updating:** Run the same command again. The engine and your WARP account are kept; only the scripts are replaced.

### 2. WARP Only (Start / Stop)

- **Start WARP:**

```sh
su -c 'sh /data/local/tmp/unblock.sh warp on'
```

- **Stop WARP:**

```sh
su -c 'sh /data/local/tmp/unblock.sh warp off'
```

### 3. WARP + Proxy Together (Start / Stop)

Traffic path: `device -> WARP -> proxy -> internet`. Required when your proxy runs over WARP or when your ISP blocks direct access to the proxy.

- **Set & start both (interactive proxy setup, then starts WARP + proxy):**

```sh
su -c 'sh /data/local/tmp/unblock.sh proxy set'
su -c 'sh /data/local/tmp/unblock.sh all on'
```

- **Stop both (restores normal network settings):**

```sh
su -c 'sh /data/local/tmp/unblock.sh all off'
```

When a proxy is active in the chain, the exit IP belongs to the proxy, so `WARP: off` in the status output is expected.

## Extra Commands

| Command | What it does |
|---|---|
| `status` | Shows running state, mode, public IP, country, WARP status, active proxy, and DNS check |
| `doctor` | Prints full diagnostics: device info, core/WARP status, saved proxy, `tun0`, and DNS servers |
| `logs` | Shows the last 40 lines of the `sing-box` log |
| `proxy set` | Interactive setup for proxy type, IP/host, port, and optional username/password |
| `proxy status` | Shows saved and active proxy details |
| `proxy clear` | Removes saved proxy settings (and switches to WARP-only if `both` was active) |
| `renew` | Registers a fresh WARP account (and restarts WARP/`both` if active) |
| `autostart on\|off` | Enables or disables start at boot via `/data/adb/service.d/99-unblock.sh` |
| `stop` | Same as `all off`; also cleans up leftover `tun0`, routes, IPv6 rules, and Private DNS |
| `uninstall` | Removes installed scripts and working directory (`PURGE=1` also removes credentials and config) |
| `version` | Prints the current script version |

Usage: `su -c 'sh /data/local/tmp/unblock.sh <command>'`

## Notes

- **WARP requirement for proxy:** On networks where direct proxy traffic is blocked or unsupported without a tunnel, use `all on` (`device -> WARP -> proxy`) rather than running the proxy alone.
- **`socks4`** sends only a user ID (no password). Hostnames use `socks4a` automatically.
- **`https` proxy** connects over TLS. Set `PROXY_SNI=name` if needed, or `PROXY_INSECURE=1` to skip certificate verification (not recommended).
- **Private DNS** is turned **off** while running so DNS queries are handled cleanly through the tunnel, then restored on stop. Set `PRIVATE_DNS=keep` to leave Private DNS untouched.
- **Security:** Passwords typed in `proxy set` are visible by default to avoid `stty` hangs under `su` (`HIDE_PASS=1` can be used on supported terminals). Avoid sharing screenshots during setup.

## What's new in v2.6

- **WARP + Proxy chaining:** Reliable `device -> WARP -> proxy -> internet` routing with automatic fallback to WARP-only if proxy traffic fails.
- **Faster startup & MTU tuning:** Added `FAST_START=1` and `WARP_MTU` (default `1360`) for responsive connections.
- **Cleaner DNS routing:** Consistent DNS outbound routing across WARP and chained proxy modes.

## Troubleshooting

Run `su -c 'sh /data/local/tmp/unblock.sh doctor'` first to inspect your setup.

- **Proxy fails alone, works with `all on`:** Your ISP blocks direct proxy traffic or requires the WARP tunnel first; always use `all on`.
- **DNS resolution fails (`curl exit 6`):** Wait a few seconds and check `status`, or start with `BLOCK_IPV6=0` on networks where system DNS is IPv6-only.
- **WARP fails to connect:** Your ISP may block UDP `2408`; try `WARP_PORT=500`, `1701`, or `4500`, or let the script probe endpoints.
- **No traffic with `system` stack:** Try `TUN_STACK=gvisor`.
- **Leftover tunnel rules after crash/reboot:** Run `sh /data/local/tmp/unblock.sh stop`.

## Environment variables

`PROXY_TYPE`, `PROXY_IP`, `PROXY_PORT`, `PROXY_USER`, `PROXY_PASS`, `PROXY_SNI`, `PROXY_INSECURE`, `WARP_PORT`, `WARP_ENDPOINT`, `WARP_MTU`, `TUN_STACK`, `FAST_START`, `SB_VER`, `SB_URL`, `BLOCK_IPV6`, `HIDE_PASS`, `PRIVATE_DNS`, `KEEP_ON_FAIL`, `DNS_TRIES`, `FORCE=1`, `PURGE=1`.

## Responsible use

This tool only routes your own device's traffic. Use it where permitted by law and in accordance with the terms of the services and proxies you use.

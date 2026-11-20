# Bypass-Blocking-Tool

Root utility for Android (run from Termux) that routes **all** device traffic (Wi-Fi + Mobile Data) through a Cloudflare WARP tunnel and/or your own proxy (sing-box TUN). No need to install the 1.1.1.1 app.

## Root Network Unblocker (v2.3)

Root utility for Android (run from Termux) that routes all device traffic through Cloudflare WARP and/or your own proxy, changing your IP and bypassing ISP / DPI blocks. No need to install the 1.1.1.1 app.

- **100% Standalone:** Automatically downloads the core engine (sing-box) and registers a free WARP account (`install`).
- **Full Traffic Tunneling:** Routes all device traffic (Wi-Fi & Mobile Data) through an encrypted tunnel and changes your IP.
- **Zero IPv6 Leaks:** Automatically blocks IPv6 leaks via `ip6tables`.
- **Independent Modes:** WARP only, proxy only, or both chained (device -> WARP -> proxy).
- **Proxy Support:** socks5, socks4, http and https, with or without authentication.
- **Safe Restore:** Your previous Private DNS and IPv6 settings are restored on stop.

## Setup & Usage (Termux)

Requires a rooted device and Termux.

### 1. Install (One-time setup)

One command: downloads the scripts, installs the engine and registers WARP.

```sh
pkg install -y curl && mkdir -p ~/unblocker && cd ~/unblocker && for f in unblock.sh start.sh stop.sh; do curl -fsSLO "https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f"; done && su -c "cp $PWD/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh && sh /data/local/tmp/unblock.sh install"
```

### 2. WARP Only (Start / Stop)

- Start WARP:

```su -c 'WARP_PORT=4500 sh /data/local/tmp/unblock.sh warp on'
```

- Stop WARP:

```su -c 'WARP_PORT=4500 sh /data/local/tmp/unblock.sh warp on'
```

### 3. Proxy Only (Start / Stop)

Supported types: `socks5`, `socks4`, `http`, `https`.

- Set the proxy once (interactive: type, IP, port, user/pass):

```sh
su -c 'sh /data/local/tmp/unblock.sh proxy set'
```

- Start proxy (uses the saved proxy):

```sh
su -c 'sh /data/local/tmp/unblock.sh proxy on'
```

- Start proxy without authentication:

```sh
su -c 'PROXY_TYPE=socks5 PROXY_IP=1.2.3.4 PROXY_PORT=1080 sh /data/local/tmp/unblock.sh proxy on'
```

- Start proxy with username & password:

```sh
su -c 'PROXY_TYPE=http PROXY_IP=1.2.3.4 PROXY_PORT=8080 PROXY_USER=user PROXY_PASS=pass sh /data/local/tmp/unblock.sh proxy on'
```

- Stop proxy:

```sh
su -c 'sh /data/local/tmp/unblock.sh proxy off'
```

### 4. WARP + Proxy Together (Start / Stop)

Traffic path: device -> WARP -> proxy -> internet.

- Start both (uses the saved proxy):

```sh
su -c 'sh /data/local/tmp/unblock.sh all on'
```

- Start both with a custom proxy:

```sh
su -c 'PROXY_TYPE=socks5 PROXY_IP=1.2.3.4 PROXY_PORT=1080 PROXY_USER=user PROXY_PASS=pass sh /data/local/tmp/unblock.sh all on'
```

- Stop both (restores your normal network):

```sh
su -c 'sh /data/local/tmp/unblock.sh all off'
```

## Extra Commands

| Command | What it does |
|---|---|
| `status` | Mode, public IP, country, WARP on/off, active proxy |
| `logs` | Last 40 lines of the sing-box log |
| `proxy status` | Show saved and active proxy |
| `proxy clear` | Forget the saved proxy |
| `renew` | Register a fresh WARP account |
| `autostart on\|off` | Start at boot (Magisk / KernelSU / APatch) |
| `uninstall` | Remove everything (`PURGE=1` also deletes credentials) |

Usage: `su -c 'sh /data/local/tmp/unblock.sh <command>'`

Switching while running: `warp off` while both run keeps the proxy; `proxy off` while both run keeps WARP; any `on` command switches to that mode.

## Notes

- **socks4** sends only a user id (no password). A hostname uses SOCKS4a automatically.
- **https** proxy = reached over TLS. Use `PROXY_SNI=name` to set the server name, or `PROXY_INSECURE=1` to skip verification (not recommended).
- **Proxy-only mode** uses DNS over TCP through the proxy and turns Android Private DNS off while running. HTTP/HTTPS proxies cannot carry UDP, so UDP apps (calls, some games) will not work in this mode.
- Proxy values passed on the command line are used for that run only. Use `proxy set` to save them in `/data/adb/unblock.conf`.

## Troubleshooting

- **Started but no internet / `warp=off`:** your ISP may block UDP 2408. Try `WARP_PORT=500`, `1701` or `4500`.
- **No traffic after adding a proxy:** wrong type/credentials or the proxy is down. Run `proxy off`.
- **Still no traffic:** try `TUN_STACK=gvisor`.
- **Download blocked:** pass a mirror link with `SB_URL=...`.
- **IPv6-only mobile networks** (464XLAT) may break because IPv6 is dropped.
- Check errors with `logs`.

## Environment variables

`PROXY_TYPE`, `PROXY_IP`, `PROXY_PORT`, `PROXY_USER`, `PROXY_PASS`, `PROXY_SNI`, `PROXY_INSECURE`, `WARP_PORT`, `WARP_ENDPOINT`, `TUN_STACK`, `SB_VER`, `SB_URL`, `FORCE=1`.

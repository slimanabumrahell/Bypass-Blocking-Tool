# Bypass-Blocking-Tool

Root utility for Android (run from Termux) that routes **all** device traffic (Wi-Fi + Mobile Data) through a Cloudflare WARP tunnel and/or your own proxy (sing-box TUN). No need to install the 1.1.1.1 app.

## Root Network Unblocker (v2.3)

- **Standalone:** downloads sing-box and registers a free WARP account (saved to `/data/adb/warp.conf`).
- **Three independent modes:** WARP only, proxy only, or both chained (device → WARP → proxy).
- **Full tunnel:** DNS is hijacked and resolved inside the tunnel. IPv6 is dropped while running (loopback kept).
- **Safe restore:** your previous Private DNS and ip6tables policies are saved and restored on stop.
- **Proxy types:** socks5, socks4, http, https (IP/host + port, optional username/password).
- **Autostart at boot** (Magisk / KernelSU / APatch).

## Quick start (Termux)

Put `unblock.sh`, `start.sh`, `stop.sh` in the same folder, then:

```sh
sh start.sh warp       # WARP only
sh start.sh proxy      # proxy only (asks for the proxy the first time)
sh start.sh all        # WARP + proxy together

sh stop.sh warp        # stop WARP only
sh stop.sh proxy       # stop proxy only
sh stop.sh             # stop everything (WARP + proxy) and restore the network
```

## Commands (`unblock.sh`)

Run as `su -c 'sh /data/local/tmp/unblock.sh <command>'` (or use `start.sh` / `stop.sh`).

| Command | What it does |
|---|---|
| `warp on` / `warp off` | WARP only: device → WARP → internet |
| `proxy set` | Interactive proxy setup, saved to `/data/adb/unblock.conf` |
| `proxy on` / `proxy off` | Proxy only: device → proxy → internet |
| `proxy clear` | Forget the saved proxy |
| `proxy status` | Show saved and active proxy |
| `all on` | Start WARP + proxy together |
| `all off` (or `stop`) | Stop both and restore network settings |
| `install` | Download core + register WARP (once) |
| `start [--no-ask]` | Classic start: asks about a proxy, uses WARP (+ proxy if chosen) |
| `restart` | Restart in the current mode |
| `status` | Mode, public IP, country, WARP on/off, active proxy |
| `logs` | Last 40 lines of the sing-box log |
| `renew` | Register a fresh WARP account |
| `autostart on\|off` | Start at boot (WARP + proxy if one is saved, else WARP) |
| `uninstall` | Remove everything (`PURGE=1` also deletes credentials) |

Mixing modes while running:

- `warp off` while both are running → proxy keeps running alone.
- `proxy off` while both are running → WARP keeps running alone.
- `warp on` / `proxy on` / `all on` while another mode is running → switches to that mode.

## Proxy without questions

```sh
su -c 'PROXY_TYPE=socks5 PROXY_IP=1.2.3.4 PROXY_PORT=1080 sh /data/local/tmp/unblock.sh all on'
su -c 'PROXY_TYPE=http PROXY_IP=1.2.3.4 PROXY_PORT=8080 PROXY_USER=user PROXY_PASS=pass sh /data/local/tmp/unblock.sh proxy on'
```

Or persistent settings in `/data/adb/unblock.conf` (**use single quotes** for values with special characters):

```sh
PROXY_TYPE='socks5'      # socks5 | socks4 | http | https
PROXY_IP='1.2.3.4'
PROXY_PORT='1080'
PROXY_USER='user'        # optional
PROXY_PASS='pass'        # optional
```

Notes:
- **socks4** has no passwords: only the username (user id) is sent. A hostname uses SOCKS4a automatically.
- **https** = a proxy reached over TLS. For a hostname the certificate is verified against it; use `PROXY_SNI=name` to set the server name, or `PROXY_INSECURE=1` to skip verification (not recommended).
- **Proxy-only mode** uses DNS over TCP through the proxy and turns Android Private DNS off while running. HTTP/HTTPS proxies cannot carry UDP, so UDP apps (calls, some games) will not work in this mode.

## Troubleshooting

- **WARP started but no internet / `warp=off`:** your ISP may block UDP 2408. Try `WARP_PORT=500`, `1701` or `4500`.
- **No traffic after adding a proxy:** wrong type/credentials or the proxy is down. Run `sh stop.sh proxy`.
- **Still no traffic:** try `TUN_STACK=gvisor`.
- **Download blocked:** pass a mirror link with `SB_URL=...`.
- **IPv6-only mobile networks** (464XLAT) may break because IPv6 is dropped.
- Check errors with `logs`.

## Environment variables

`PROXY_TYPE`, `PROXY_IP`, `PROXY_PORT`, `PROXY_USER`, `PROXY_PASS`, `PROXY_SNI`, `PROXY_INSECURE`, `WARP_PORT`, `WARP_ENDPOINT`, `TUN_STACK`, `SB_VER`, `SB_URL`, `FORCE=1`.

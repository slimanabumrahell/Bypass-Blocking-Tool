# Bypass-Blocking-Tool

Root utility for Android that routes **all** device traffic (Wi-Fi + Mobile Data) through a Cloudflare WARP tunnel (sing-box TUN), changing your IP and bypassing ISP / DPI blocks. No need to install the 1.1.1.1 app.

## Root Network Unblocker (v2.2)

- **Standalone:** downloads sing-box and registers a free WARP account (saved to `/data/adb/warp.conf`). `start` installs automatically if needed.
- **Full tunnel:** everything goes through WARP, DNS included (hijacked and resolved via 1.1.1.1 inside the tunnel).
- **No IPv6 leaks:** IPv6 is dropped while running (loopback kept).
- **Safe restore:** your previous Private DNS and ip6tables policies are saved and restored on stop.
- **Proxy chaining (new):** device → WARP → your proxy. Supports **socks5, socks4, http, https**, with IP/host + port and optional username/password. Questions are asked before start.
- **Separate start / stop scripts (new):** `start.sh` and `stop.sh`.
- **Autostart at boot** (Magisk / KernelSU / APatch).

> No extra libraries are needed: sing-box (the core that gets downloaded) already implements all four proxy protocols.

## Quick start (Termux)

Put `unblock.sh`, `start.sh`, `stop.sh` in the same folder, then:

```sh
sh start.sh          # asks: use a proxy? type? IP? port? user/pass? -> starts
sh stop.sh           # stops everything, restores the network
sh stop.sh proxy     # stops only the proxy (WARP keeps running)
```

### What `start.sh` asks

```
Do you want to use a proxy (socks5 / socks4 / http / https)? [y/N]: y
  1) socks5   2) socks4   3) http   4) https
Proxy type [1-4]: 1
Proxy IP / host: 5.6.7.8
Proxy port: 1080
Username (press Enter if none):
Password (press Enter if none):        <- hidden input
Save this proxy for next time? [Y/n]:
```

If a proxy is already saved you can use it, change it, or skip it for this run. If the proxy does not pass traffic, you are offered to continue with WARP only.

`sh start.sh --no-ask` skips all questions and uses the saved settings (this is what autostart uses).

## Commands (`unblock.sh`)

| Command | What it does |
|---|---|
| `install` | Download core + register WARP (once) |
| `start [--no-ask]` | Start the tunnel (asks about a proxy first) |
| `stop` | Stop everything and restore network settings |
| `restart` | Stop + start with saved settings (no questions) |
| `proxy set` | Interactive proxy setup, saved to `/data/adb/unblock.conf` |
| `proxy off` | Remove the proxy; if running, restarts with WARP only |
| `proxy status` | Show saved and active proxy |
| `status` | Running state, public IP, country, WARP on/off, active proxy |
| `logs` | Last 40 lines of sing-box log |
| `renew` | Register a fresh WARP account |
| `autostart on\|off` | Start at boot |
| `uninstall` | Remove everything (`PURGE=1` also deletes credentials) |

## Proxy without questions

```sh
su -c 'PROXY_TYPE=socks5 PROXY_IP=1.2.3.4 PROXY_PORT=1080 sh /data/local/tmp/unblock.sh start'
su -c 'PROXY_TYPE=http PROXY_IP=1.2.3.4 PROXY_PORT=8080 PROXY_USER=user PROXY_PASS=pass sh /data/local/tmp/unblock.sh start'
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
- Traffic path: device → WARP → proxy → internet.

## Troubleshooting

- **Started but no internet / `warp=off`:** your ISP may block UDP 2408. Try `WARP_PORT=500`, `1701` or `4500`.
- **No traffic after adding a proxy:** wrong type/credentials or the proxy is down. Run `sh stop.sh proxy`.
- **Still no traffic:** try `TUN_STACK=gvisor`.
- **Download blocked:** pass a mirror link with `SB_URL=...`.
- **IPv6-only mobile networks** (464XLAT) may break because IPv6 is dropped.
- Check errors with `logs`.

## Environment variables

`PROXY_TYPE`, `PROXY_IP`, `PROXY_PORT`, `PROXY_USER`, `PROXY_PASS`, `PROXY_SNI`, `PROXY_INSECURE`, `WARP_PORT`, `WARP_ENDPOINT`, `TUN_STACK`, `SB_VER`, `SB_URL`, `FORCE=1`.

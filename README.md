# Bypass-Blocking-Tool

## Root Network Unblocker (v2.5)

Root utility for Android (run from Termux) that routes all device traffic through Cloudflare WARP and/or your own proxy, changing your IP and bypassing ISP / DPI blocks. No need to install the 1.1.1.1 app.

- **100% Standalone:** Automatically downloads the core engine (sing-box) and registers a free WARP account (`install`).
- **Full Traffic Tunneling:** Routes all device traffic (Wi-Fi & Mobile Data) through an encrypted tunnel and changes your IP.
- **No IPv6 Leaks:** IPv6 is rejected with `ip6tables` (in its own chain, removed again on stop).
- **Independent Modes:** WARP only, proxy only, or both chained (device -> WARP -> proxy).
- **Proxy Support:** socks5, socks4, http and https, with or without authentication.
- **Fail-safe:** if a start does not pass traffic, your normal network is restored automatically - a bad proxy can no longer leave the phone offline.
- **Safe Restore:** Your previous Private DNS setting is restored on stop.
- **Built-in diagnostics:** `doctor` prints everything needed to find a problem (no passwords).

## Setup & Usage (Termux)

Requires a rooted device and Termux.

### 1. Install (One-time setup)

One command: downloads the scripts, installs the engine and registers WARP.

```sh
pkg install -y curl && mkdir -p ~/unblocker && cd ~/unblocker && for f in unblock.sh start.sh stop.sh; do curl -fsSLO "https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f"; done && su -c "cp $PWD/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh && sh /data/local/tmp/unblock.sh install"
```

**Updating:** run the same command again. The engine and your WARP account are kept; only the scripts are replaced.

### 2. WARP Only (Start / Stop)

- Start WARP:

```sh
su -c 'sh /data/local/tmp/unblock.sh warp on'
```

- Stop WARP:

```sh
su -c 'sh /data/local/tmp/unblock.sh warp off'
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

> Before starting, proxy-only mode checks that the proxy answers from your network. If it does not (some ISPs block direct connections to proxies), you are offered to reach it **through WARP** instead - see mode 4.

### 4. WARP + Proxy Together (Start / Stop)

Traffic path: device -> WARP -> proxy -> internet. This is also the mode to use when your ISP blocks the proxy itself: the connection to the proxy then travels inside the WARP tunnel.

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

With a proxy in the chain the exit IP is the proxy's, so `WARP: off` in the status line is **expected** - it does not mean WARP failed.

## Extra Commands

| Command | What it does |
|---|---|
| `status` | Mode, public IP, country, WARP on/off, active proxy, DNS check |
| `doctor` | Full diagnostics: device, DNS servers, Private DNS, ip rules, live tests, log tail |
| `logs` | Last 40 lines of the sing-box log |
| `proxy status` | Show saved and active proxy |
| `proxy clear` | Forget the saved proxy |
| `renew` | Register a fresh WARP account |
| `autostart on\|off` | Start at boot (Magisk / KernelSU / APatch) |
| `stop` | Same as `all off`; also repairs a crashed tunnel (stale `tun0`, ip rules, IPv6 rule, Private DNS) |
| `uninstall` | Remove everything (`PURGE=1` also deletes credentials) |
| `version` | Print the version |

Usage: `su -c 'sh /data/local/tmp/unblock.sh <command>'`

Switching while running: `warp off` while both run keeps the proxy; `proxy off` while both run keeps WARP; any `on` command switches to that mode.

## Notes

- **socks4** sends only a user id (no password). A hostname uses SOCKS4a automatically.
- **https** proxy = reached over TLS. Use `PROXY_SNI=name` to set the server name, or `PROXY_INSECURE=1` to skip verification (not recommended).
- **Proxy-only mode** uses DNS over TCP through the proxy. HTTP/HTTPS proxies cannot carry UDP, so UDP apps (calls, some games) will not work in this mode.
- **Private DNS** is switched **off** while the tunnel runs (DNS is then captured by the tunnel and answered through WARP / the proxy) and restored on stop. Use `PRIVATE_DNS=keep` to leave it untouched.
- Proxy values passed on the command line are used for that run only. Use `proxy set` to save them in `/data/adb/unblock.conf` (mode 600).
- **Security:** the password is shown while you type it in `proxy set` (hiding it hangs under `su` on many devices; `HIDE_PASS=1` tries to hide it). Do not share screenshots of that step, and rotate the password if you did.

## What's new in v2.5

- **Fail-safe start:** when the tunnel comes up but no traffic passes, the network is rolled back automatically (set `KEEP_ON_FAIL=1` to keep the tunnel for debugging). The misleading green `Path: ...` line is no longer printed after a failure.
- **Proxy blocked by the ISP:** proxy-only mode tests the proxy first and offers to chain it through WARP. `all on` falls back to WARP only if the proxy fails (automatically when started at boot).
- **DNS fixes:** Private DNS is turned off while running instead of forcing a strict host name (which can make every lookup fail while Android validates it); IPv6 is rejected instead of dropped (no multi-second lookup timeouts); a second `port 53` DNS-capture rule is added; the name-resolution check now retries instead of failing on the first try.
- **Hostname proxies in proxy-only mode:** the proxy's own host name is resolved directly (it used to deadlock waiting on the proxy it was trying to reach).
- **`doctor` command** and clearer status output.
- **Safer cleanup:** only *our* sing-box is ever killed (another app's sing-box, e.g. NekoBox, is left alone); a hard-killed tunnel's leftovers (`tun0`, ip rules) are removed by `stop`; the IPv6 rule lives in its own chain.

## Troubleshooting

Run `su -c 'sh /data/local/tmp/unblock.sh doctor'` first - it shows most causes directly.

- **`proxy on` fails but `all on` works:** your ISP blocks the direct connection to the proxy. Use `all on` (WARP -> proxy).
- **Tunnel works but names do not resolve (`DNS: FAILED`, curl exit 6):** wait ~20 s and run `status` again. If it stays, check `doctor`: if *all* system DNS servers are IPv6, start with `BLOCK_IPV6=0`.
- **Started but no internet / `warp=off` in WARP-only mode:** your ISP may block UDP 2408. Try `WARP_PORT=500`, `1701` or `4500` (the tool also searches automatically).
- **Still no traffic:** try `TUN_STACK=gvisor`.
- **Internet dead after a crash or reboot loop:** run `stop` - it removes leftover routes and rules.
- **Download blocked:** pass a mirror link with `SB_URL=...`.
- **IPv6-only mobile networks** (464XLAT): IPv6 is not blocked there (otherwise data would die), so IPv6 traffic is not tunneled.
- Check errors with `logs`.

## Environment variables

`PROXY_TYPE`, `PROXY_IP`, `PROXY_PORT`, `PROXY_USER`, `PROXY_PASS`, `PROXY_SNI`, `PROXY_INSECURE`, `WARP_PORT`, `WARP_ENDPOINT`, `TUN_STACK`, `SB_VER`, `SB_URL`, `BLOCK_IPV6`, `HIDE_PASS`, `PRIVATE_DNS`, `KEEP_ON_FAIL`, `DNS_TRIES`, `FORCE=1`, `PURGE=1`.

## Responsible use

This tool only routes your own device's traffic. Use it where that is legal and in line with the terms of the services and proxies you connect to.

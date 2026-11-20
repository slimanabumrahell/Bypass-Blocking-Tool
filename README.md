# Bypass-Blocking-Tool

## Root Network Unblocker (v2.6)

Root utility for Android (run from Termux) that routes all device traffic through Cloudflare WARP and/or your own proxy, changing your IP and bypassing ISP / DPI blocks. No need to install the 1.1.1.1 app.

- **100% Standalone:** Automatically downloads the core engine (`sing-box`) and registers a free WARP account (`install`).
- **Composable & Independent Modes:** Run WARP alone, proxy alone, or layer them together (`device -> WARP -> proxy`), and turn either one off later while keeping the other running.
- **Speed & Stability Focused:** Uses saved working WARP endpoints first, supports `FAST_START=1` and `WARP_MTU`, and avoids unnecessary delays.
- **No IPv6 Leaks:** IPv6 is rejected with `ip6tables` (in its own chain, removed again on stop).
- **Proxy Support:** `socks5`, `socks4`, `http`, and `https`, with or without authentication.
- **Fail-safe:** If a start or layer switch does not pass traffic, normal network settings are restored automatically (or a sensible fallback is used).
- **Safe Restore:** Your previous Private DNS setting is restored on stop.
- **Built-in diagnostics:** `doctor` prints everything needed to find a problem (no passwords).

## Setup & Usage (Termux)

Requires a rooted device and Termux.

### 1. Install (One-time setup)

One command: downloads the scripts, installs the engine, and registers WARP:

```sh
pkg install -y curl && mkdir -p ~/unblocker && cd ~/unblocker && for f in unblock.sh start.sh stop.sh; do curl -fsSLO "[https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f](https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f)"; done && su -c "cp $PWD/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh && sh /data/local/tmp/unblock.sh install"

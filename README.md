# Bypass-Blocking-Tool

```bash
su -c 'curl -sL https://githubusercontent.com -o /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh'
```

# Root Network Unblocker (v2.0)

A standalone root script for Android to bypass network restrictions, DPI blocks, and HTTP proxy blocks across Wi-Fi and Mobile Data using an automated Cloudflare WARP TUN engine (`sing-box`).

## Features
- **100% Standalone:** Automatically downloads the core engine and registers a free WARP account (`install`).
- **Full Traffic Tunneling:** Routes all device traffic (Wi-Fi & Mobile Data) through an encrypted tunnel and changes your IP.
- **Zero IPv6 Leaks:** Automatically blocks IPv6 leaks via `ip6tables`.
- **Built-in HTTP Proxy Chaining:** Supports routing HTTP proxies (with or without authentication) directly through the encrypted tunnel.

## Setup & Usage (Termux)

### 1. Move script to executable path (One-time setup)
Download `unblock.sh` to your internal storage or `Download` folder, then run in Termux:
```bash
su -c 'cp /sdcard/Download/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh'
```

### 2. Install Engine & Register WARP (One-time setup)
```bash
su -c 'sh /data/local/tmp/unblock.sh install'
```

### 3. Start Unblocker (Changes IP & Unblocks Sites)
```bash
su -c 'sh /data/local/tmp/unblock.sh start'
```

### 4. Start Unblocker + Custom HTTP Proxy
* Without authentication:
```bash
su -c 'PROXY_IP=1.2.3.4 PROXY_PORT=8080 sh /data/local/tmp/unblock.sh start'
```
* With username & password:
```bash
su -c 'PROXY_IP=1.2.3.4 PROXY_PORT=8080 PROXY_USER=user PROXY_PASS=pass sh /data/local/tmp/unblock.sh start'
```

### 5. Stop Unblocker
```bash
su -c 'sh /data/local/tmp/unblock.sh stop'
```

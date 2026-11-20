Bypass-Blocking-Tool

<p align="center">
  <b>Root Network Utility for Android</b><br>
  <sub>Version 3.0 · Termux · Root Required</sub>
</p><p align="center">
  <img src="https://img.shields.io/badge/Version-3.0-blue?style=for-the-badge">
  <img src="https://img.shields.io/badge/Platform-Android-green?style=for-the-badge">
  <img src="https://img.shields.io/badge/Environment-Termux-black?style=for-the-badge">
  <img src="https://img.shields.io/badge/Root-Required-orange?style=for-the-badge">
</p>---

Overview

Bypass-Blocking-Tool is an Android root utility designed to manage network components, connectivity configurations, and network diagnostics through a unified command-line interface.

The project operates through Termux and requires root access.

Features

- Modular network component management
- Independent component configuration
- Network status monitoring
- System diagnostics
- Logging and troubleshooting
- Configuration management
- Cleanup and restoration support
- Root integration
- Termux compatibility

Components

Component| Technology
Network Engine| "sing-box"
Core Engine| "Xray-core"
Network Component| "ByeDPI / ciadpi"
Userspace Networking| "wireproxy"
Shell Interface| Shell Scripts
Android Integration| Root / Termux

---

Requirements

- Android device
- Root access
- Termux
- Internet connection
- Required system utilities

---
Setup & Usage (Termux)

Requires a rooted Android device and Termux.

### 1. Install (One-time setup)

Run this single command in Termux:

```sh
pkg install -y curl unzip && mkdir -p ~/unblocker && cd ~/unblocker && for f in unblock.sh start.sh stop.sh; do curl -fsSLO "https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f"; done && su -c "cp $PWD/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh && sh /data/local/tmp/unblock.sh install"
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

### 3. ByeDPI Anti-DPI (Start / Stop)

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
su -c 'sh /data/local/tmp/unblock.sh proxy on'
```
- **Stop Both:**
```sh
su -c 'sh /data/local/tmp/unblock.sh proxy off'
```
---

License

Distributed under the MIT License.

See the "LICENSE" file for details.

---

<p align="center">
  <b>Bypass-Blocking-Tool · v3.0</b><br>
  <sub>Android · Termux · Root Network Utility</sub>
</p>

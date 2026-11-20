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

Install Dependencies

pkg update
pkg install -y curl unzip

---

Installation

1. Download Project Files

mkdir -p ~/unblocker
cd ~/unblocker

2. Download Scripts

for f in unblock.sh start.sh stop.sh; do
    curl -fsSLO "https://raw.githubusercontent.com/slimanabumrahell/Bypass-Blocking-Tool/main/$f"
done

3. Install

su -c "cp $PWD/unblock.sh /data/local/tmp/unblock.sh && chmod 755 /data/local/tmp/unblock.sh"

---

Commands Reference

Command| Description
"status"| Display current status
"doctor"| Run diagnostics
"logs"| View logs
"renew"| Refresh configuration
"autostart"| Manage startup configuration
"stop"| Stop managed components
"uninstall"| Remove the utility
"help"| Display help information

---

Configuration

Configuration options are managed through environment variables.

Variable| Description
"PROXY_TYPE"| Configuration type
"PROXY_URI"| Configuration URI
"PROXY_IP"| Server IP address
"PROXY_PORT"| Server port
"PROXY_USER"| Username
"PROXY_PASS"| Password
"PROXY_SNI"| Server name
"PROXY_INSECURE"| TLS verification configuration
"WARP_ENGINE"| Engine selection
"WARP_ENDPOINT"| Endpoint configuration
"WARP_PORT"| Endpoint port
"WARP_MTU"| MTU configuration
"DPI_ARGS"| Component arguments
"TUN_STACK"| Network stack configuration
"FAST_START"| Startup configuration
"TLS_FRAG"| Transport configuration
"SB_VER"| sing-box version
"XRAY_VER"| Xray version
"BYEDPI_VER"| ByeDPI version
"WP_VER"| wireproxy version
"BLOCK_IPV6"| IPv6 configuration
"HIDE_PASS"| Sensitive output handling
"PRIVATE_DNS"| Private DNS configuration
"KEEP_ON_FAIL"| Failure handling
"DNS_TRIES"| DNS diagnostic attempts
"FORCE"| Force operation
"PURGE"| Remove saved configuration

---

Diagnostics

The diagnostic system checks the environment and configuration.

Diagnostic Checks

- Root access
- Required dependencies
- Component availability
- Configuration integrity
- Network interfaces
- DNS settings
- Runtime status
- Log availability

---

Troubleshooting

Problem| Possible Cause| Recommended Action
Installation failure| Missing dependencies| Check installed packages
Root unavailable| Permission issue| Verify root access
Component unavailable| Missing files| Check installation
Configuration error| Invalid configuration| Review configuration
Network issue| System configuration| Check network settings
Startup failure| Runtime error| Review diagnostic logs
Cleanup failure| Remaining configuration| Review cleanup status

---

Logs

Logs can be used to investigate component errors and runtime problems.

When troubleshooting, review:

- Startup errors
- Configuration errors
- Component failures
- DNS issues
- Runtime messages
- Cleanup errors

Privacy: Remove passwords, credentials, tokens, and personal information before sharing logs.

---

Cleanup

The cleanup functionality is intended to:

- Stop managed processes
- Remove temporary files
- Restore supported system settings
- Remove managed runtime configuration
- Clean up temporary resources

Always verify your device's connectivity and system settings after cleanup.

---

Uninstallation

Before uninstalling:

1. Stop managed components.
2. Review saved configuration.
3. Back up files you want to retain.
4. Verify cleanup.
5. Remove the utility files.

---

Compatibility

Platform| Requirement
Android| Required
Termux| Required
Root Access| Required
Non-root devices| Unsupported
Custom ROMs| Compatibility may vary

Compatibility depends on the Android version, kernel, root solution, and available system utilities.

---

Security

Because this utility operates with elevated privileges:

- Review scripts before execution.
- Use trusted download sources.
- Protect configuration files.
- Never publish private credentials.
- Keep components updated.
- Review system changes before and after use.

---

Disclaimer

This project is provided for educational purposes and authorized network administration.

Users are responsible for complying with applicable laws, regulations, and network policies.

The developers are not responsible for misuse, system instability, connectivity interruptions, configuration errors, or damages resulting from use of this software.

---

Contributing

Contributions, bug reports, and documentation improvements are welcome.

When reporting an issue, include:

- Android version
- Device model
- Root solution
- Error message
- Diagnostic output
- Steps to reproduce

Please remove sensitive information before submitting reports.

---

License

Distributed under the MIT License.

See the "LICENSE" file for details.

---

<p align="center">
  <b>Bypass-Blocking-Tool · v3.0</b><br>
  <sub>Android · Termux · Root Network Utility</sub>
</p>

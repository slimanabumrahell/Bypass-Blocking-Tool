Bypass-Blocking-Tool

<p align="center">
  <b>Root Network Utility for Android</b><br>
  <sub>Version 3.0 · Termux · Root Required</sub>
</p><p align="center">
  <img src="https://img.shields.io/badge/Version-3.0-blue?style=for-the-badge" alt="Version 3.0">
  <img src="https://img.shields.io/badge/Platform-Android-green?style=for-the-badge" alt="Android">
  <img src="https://img.shields.io/badge/Environment-Termux-black?style=for-the-badge" alt="Termux">
  <img src="https://img.shields.io/badge/Root-Required-orange?style=for-the-badge" alt="Root Required">
  <img src="https://img.shields.io/badge/License-MIT-lightgrey?style=for-the-badge" alt="License">
</p>---

Overview

Bypass-Blocking-Tool is a modular Android network utility designed to provide a unified command-line interface for managing network components, configurations, connectivity settings, and diagnostics.

The project is designed for rooted Android devices and operates through a Termux-based environment.

Its modular architecture allows components to be managed independently, with centralized configuration, status reporting, logging, and cleanup functionality.

Features

- Modular Architecture — Independent components with centralized management.
- Network Management — Manage network-related configurations and services.
- Diagnostics — Inspect system configuration and component availability.
- Status Monitoring — Review service states and system information.
- Logging — Access component logs for troubleshooting.
- Configuration Management — Manage runtime settings and saved configurations.
- Cleanup & Restoration — Restore supported system settings when services are stopped.
- Root Integration — Designed for rooted Android devices.
- Termux Support — Command-line interface using Termux.
- Automatic Recovery — Includes handling for startup failures and cleanup operations.

---

Architecture

The project uses several independent components:

Component| Technology| Purpose
Network Manager| "sing-box"| Network service management
Core Engine| "Xray-core"| Configurable network transport
Network Diagnostics| "ByeDPI / ciadpi"| Network behavior testing
Userspace Networking| "wireproxy"| Userspace network integration
Shell Interface| Bash / POSIX Shell| Command-line management
Android Integration| Root / Termux| System-level integration

Components are managed through a central script and configuration system.

---

Requirements

Device Requirements

- Android device
- Root access
- Termux installed
- Compatible Android shell environment
- Internet connection for initial setup

Software Requirements

- "curl"
- "unzip"
- Shell environment
- Root permissions

Install the basic dependencies:

pkg update
pkg install -y curl unzip

---

Installation

Initial Setup

Create the project directory:

mkdir -p ~/unblocker
cd ~/unblocker

Download the project files from the repository and review them before installation.

Root Environment

The utility requires root permissions for supported system-level operations.

Verify root access:

su -c id

You should receive output indicating that the command is running with root privileges.

Installation Files

File| Description
"unblock.sh"| Main command-line interface
"start.sh"| Startup helper
"stop.sh"| Shutdown helper
"README.md"| Project documentation

---

Usage

The project provides a unified command-line interface.

General syntax:

unblock.sh <command> <action>

Commands Reference

Command| Description
"status"| Display current component and system status
"doctor"| Run diagnostic checks
"logs"| Display available logs
"renew"| Refresh supported configuration credentials
"autostart"| Manage startup configuration
"stop"| Stop managed services and perform cleanup
"uninstall"| Remove the utility
"help"| Display available commands

Component Management

The utility organizes its components into independent management modules.

Module| Purpose
Network Components| Manage configured networking services
Configuration| Set, inspect, and remove configurations
Diagnostics| Check system and component health
Logging| Inspect operational logs
Cleanup| Restore managed settings and remove runtime state

---

Configuration

Configuration is managed through environment variables and project configuration files.

Environment Variables

Variable| Description
"PROXY_TYPE"| Configuration type
"PROXY_URI"| Configuration URI
"PROXY_IP"| Server address
"PROXY_PORT"| Server port
"PROXY_USER"| Authentication username
"PROXY_PASS"| Authentication password
"PROXY_SNI"| Server name configuration
"PROXY_INSECURE"| TLS verification setting
"WARP_ENGINE"| Selected network engine
"WARP_ENDPOINT"| Endpoint configuration
"WARP_PORT"| Endpoint port
"WARP_MTU"| Network MTU setting
"DPI_ARGS"| Component arguments
"TUN_STACK"| Network stack configuration
"FAST_START"| Startup behavior
"TLS_FRAG"| Transport configuration
"SB_VER"| Component version
"XRAY_VER"| Component version
"BYEDPI_VER"| Component version
"WP_VER"| Component version
"BLOCK_IPV6"| IPv6 management setting
"HIDE_PASS"| Sensitive output handling
"PRIVATE_DNS"| Private DNS configuration
"KEEP_ON_FAIL"| Failure-handling behavior
"DNS_TRIES"| DNS diagnostic attempts
"FORCE"| Force-operation option
"PURGE"| Configuration removal option

«Security Notice: Never publish credentials, authentication tokens, private keys, or personal configuration files in a public repository.»

---

Diagnostics

The diagnostic system helps identify configuration and environment issues.

Diagnostic checks may include:

- Root permission availability
- Required dependencies
- Component availability
- Configuration integrity
- Network interface status
- DNS configuration
- Runtime state
- Log availability

Troubleshooting

Problem| Recommended Check
Installation fails| Verify dependencies and network access
Root permission unavailable| Verify root access and permission authorization
Component unavailable| Check installation and version compatibility
Configuration error| Review configuration files and diagnostic output
Network connectivity issue| Review system network settings
Service fails to start| Inspect logs and diagnostic output
Cleanup incomplete| Run the cleanup procedure and verify restored settings

---

Logs

Logs are intended to help identify component errors and startup problems.

Review logs when:

- A component fails to initialize
- Configuration is rejected
- Network connectivity changes unexpectedly
- Cleanup does not complete
- Runtime errors occur

Avoid sharing logs publicly if they contain IP addresses, credentials, tokens, or personal information.

---

Stopping & Cleanup

The project includes cleanup functionality intended to:

- Stop managed processes
- Remove temporary runtime files
- Restore supported network settings
- Remove managed rules
- Restore previously saved configuration where applicable

Always verify the device's connectivity and system settings after performing cleanup.

---

Uninstallation

The uninstallation process removes the project and its managed files.

Configuration and credential removal may depend on the selected cleanup options.

Before uninstalling:

1. Review your current configuration.
2. Back up files you want to retain.
3. Stop managed components.
4. Verify that system settings have been restored.
5. Remove the project files.

---

Compatibility

Platform| Support
Android| Required
Termux| Required
Root| Required
Non-root devices| Not supported
Custom Android environments| Compatibility may vary

Compatibility depends on the Android version, root implementation, kernel, and available system utilities.

---

Security

This project interacts with system-level networking and requires elevated privileges.

Users should:

- Review scripts before executing them.
- Use trusted sources for downloads.
- Keep components updated.
- Protect configuration files.
- Avoid exposing credentials in logs.
- Understand the system changes made by each component.

---

Disclaimer

This project is provided for educational purposes, software development, and authorized network administration.

The developers are not responsible for misuse, device instability, configuration errors, service interruptions, or damages resulting from use of this software.

Users are responsible for complying with applicable laws, regulations, and network policies.

---

Contributing

Contributions, bug reports, documentation improvements, and compatibility reports are welcome.

When submitting a report, include:

- Android version
- Device model
- Root solution
- Relevant error messages
- Diagnostic output
- Steps to reproduce the issue

Remove personal information and credentials before submitting logs.

---

License

This project is distributed under the MIT License.

See the "LICENSE" file for details.

---

<p align="center">
  <b>Bypass-Blocking-Tool · v3.0</b><br>
  <sub>Android · Termux · Root Network Utility</sub>
</p>

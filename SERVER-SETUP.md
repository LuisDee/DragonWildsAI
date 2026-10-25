# This VM: actual state

Facts about this box, written by the Claude Code session on Luis's Mac that set it up (2026-10-25). `CLAUDE.md` owns the goal and the plan; this file only says what is actually here. Update it when you change the machine.

## Machine

- Contabo Cloud VPS 4, Windows Server 2025 (build 26100), hostname `vmi3696124`, public IPv4 `95.111.233.70`.
- Tailscale: logged in to Luis's tailnet as `vmi3696124` / `100.98.73.63`, unattended mode.

## Firewall (Windows Firewall on for all profiles)

| Port | Open to |
|---|---|
| Remote Desktop TCP/UDP 3389 | Luis's home IP `195.224.171.195` and Tailscale `100.64.0.0/10` |
| WinRM HTTPS 5986 | same as Remote Desktop |
| OpenSSH 22 | Tailscale only; key login for Luis's Mac |
| Game UDP 7777 | **not open yet**: open it (to everyone) when the dedicated server is installed |

## Installed

- Tailscale, OpenSSH Server (running, starts automatically), Claude Code 2.1.310 for `Administrator` (on the user PATH).

## Not installed yet (CLAUDE.md section 3 lists them as expected)

- Git for Windows, Python 3, SteamCMD, the Dragonwilds dedicated server, UE4SS.
- Windows Update active-hours / no-auto-reboot setting is not configured.

## Account quirks

- The `Administrator` login is a normal admin account (SID ending `-1001`), not Windows' built-in one. PowerShell needs **Run as administrator** for admin work. WinRM from outside is refused by UAC remote restrictions; leave that as is.
- Account lockout threshold is Never, so failed logins cannot lock the account.

## Rules

- Never open Remote Desktop, WinRM or SSH to the whole internet.
- If networking breaks, the way back in is the browser console (VNC) in the Contabo customer panel.

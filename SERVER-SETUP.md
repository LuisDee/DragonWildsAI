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
| Game UDP 7777 | everyone (rule "Dragonwilds Server UDP 7777") |
| Beacon UDP 8888 | everyone (rule "Dragonwilds Server UDP 8888 beacon") |

## Installed

- Tailscale, OpenSSH Server (running, starts automatically), Claude Code 2.1.310 for `Administrator` (on the user PATH).
- Installed via winget, always with `--source winget` (the msstore source fails here with a certificate error):
  - Git 2.56.0, Python 3.12.10 (machine-wide), SteamCMD, VC++ 2015–2022 x64 runtime, Lua 5.4.5 (`DEVCOM.Lua`).
- The Dragonwilds dedicated server (build 26161880) is at `C:\GameServers\Dragonwilds`, with the `CompanionDev` throwaway world.
  - World and admin passwords are in `C:\gameserver\server-secrets.local.txt`, which is not in git.
- UE4SS experimental-latest, loaded through Ultimate ASI Loader as `version.dll`, is in `C:\GameServers\Dragonwilds\RSDragonwilds\Binaries\Win64`. See docs/DISCOVERIES.md.
- The Python venv for the brain is at `C:\gameserver\.venv`.
- Server control: `tools\start_server.ps1`, `stop_server.ps1`, `update_server.ps1`, `install_ue4ss.ps1`, `deploy_mod.ps1`.
  - The server does **not** start automatically at boot yet.

## Not done yet

- Windows Update is configured (2026-10-25):
  - Active hours are 08:00–02:00.
  - Policy `AU\NoAutoRebootWithLoggedOnUsers=1`.
  - `AUOptions=3` (download, then notify before installing).
- No auto-start or auto-restart for the game server.

## Account quirks

- The `Administrator` login is a normal admin account (SID ending `-1001`), not Windows' built-in one. PowerShell needs **Run as administrator** for admin work. WinRM from outside is refused by UAC remote restrictions; leave that as is.
- Account lockout threshold is Never, so failed logins cannot lock the account.

## Rules

- Never open Remote Desktop, WinRM or SSH to the whole internet.
- If networking breaks, the way back in is the browser console (VNC) in the Contabo customer panel.

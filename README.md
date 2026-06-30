# RAMMap Memory Guard

[English](README.md) | [简体中文](README.zh-CN.md)

A lightweight Windows background service that automatically frees up physical
memory when usage crosses a configurable threshold, using the Microsoft
Sysinternals **RAMMap** tool.

Everything lives in a **single PowerShell script** —
[`RAMMapMemoryGuard.ps1`](RAMMapMemoryGuard.ps1) — which handles monitoring,
installation, uninstallation, and a dry-run diagnostic mode. See
[DESIGN.md](DESIGN.md) for the full design.

## How it works

A native PowerShell loop polls physical memory usage at a fixed interval (via
`Get-CimInstance Win32_OperatingSystem`, no child processes). When usage rises
above the threshold — and the cooldown has elapsed — it calls `RAMMap64.exe` to
empty the working sets, system working set, and modified page list, samples
memory again, and logs how much was freed.

| Component | Role |
|-----------|------|
| `RAMMapMemoryGuard.ps1` | Single entry point: monitor loop / install / uninstall / diagnostic |
| `RAMMap64.exe` | Microsoft Sysinternals binary that performs the actual memory cleanup (not bundled) |

RAMMap operations used (configurable subset via `-Operations`):

- `-Ew` — Empty Working Sets
- `-Es` — Empty System Working Set
- `-Em` — Empty Modified Page List

### Keep-alive

Installation registers a Task Scheduler task that runs as **SYSTEM** on a
**BOOT** trigger, repeating every few minutes. A named mutex
(`Global\RAMMapMemoryGuard`, falling back to `Local\`) guarantees a single
instance: each scheduled launch either acquires the mutex and takes over, or
exits silently because another instance already holds it. If the guard process
dies, the OS releases the mutex and the next repetition restarts it. Running as
SYSTEM in Session 0 means **no console window and no UAC popup ever appears**.

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Administrator privileges (RAMMap needs admin to empty memory lists; the
  `-WhatIf` diagnostic mode does not)
- `RAMMap64.exe` — **not bundled**; download it from the official source (see below)

## Setup

1. Download RAMMap from Microsoft and place `RAMMap64.exe` in the **same folder**
   as the script:
   <https://learn.microsoft.com/sysinternals/downloads/rammap>

2. Install the keep-alive task (this triggers a UAC elevation prompt):

   ```powershell
   powershell -ExecutionPolicy Bypass -File RAMMapMemoryGuard.ps1 -Install
   ```

   This registers a Task Scheduler task named `RAMMapMemoryGuard` that:
   - starts at system boot and repeats every 5 minutes (auto-restart if it dies),
   - runs as **SYSTEM** in Session 0 with no window and no UAC prompt.

3. To start immediately without rebooting:

   ```powershell
   schtasks /run /tn "RAMMapMemoryGuard"
   ```

## Configuration

Pass parameters on the command line (defaults shown):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Threshold` | `80` | Memory usage % that triggers cleanup (1–99) |
| `-Interval` | `30` | Sampling interval in seconds (5–3600) |
| `-CleanupCooldown` | `5` | Minimum minutes between cleanups (1–1440) |
| `-Operations` | `Ew Es Em` | Subset of RAMMap operations to run |
| `-LogPath` | auto | Log file path; defaults to a daily-rolling `memory_cleaner_YYYYMMDD.log` |
| `-WhatIf` | off | Diagnostic mode: sample and report only, no cleanup, no log file, no admin required |
| `-RunGuardInterval` | `5` | Keep-alive trigger interval in minutes (used with `-Install`) |

Examples:

```powershell
# Run the monitor directly with a 90% threshold and 60s interval
powershell -File RAMMapMemoryGuard.ps1 -Threshold 90 -Interval 60

# Diagnostic dry run — see what it would do, no admin needed
powershell -File RAMMapMemoryGuard.ps1 -WhatIf
```

## Uninstall

```powershell
powershell -File RAMMapMemoryGuard.ps1 -Uninstall
```

If the guard process is currently running, stop it as well:

```powershell
Stop-Process -Name RAMMap64 -Force
```

## ⚠️ Security notice — please read

This script intentionally uses techniques that **antivirus software may flag**:
elevation to administrator, a hidden window, running as SYSTEM, and a persistent
scheduled task. This is the same pattern some malware uses, so a false positive
is possible. Everything here is plain text and fully auditable:

- **Why administrator / SYSTEM?** RAMMap requires admin rights to empty memory
  lists; running the keep-alive task as SYSTEM avoids a UAC prompt on every
  trigger.
- **Why a scheduled task?** So the service runs in the background and
  auto-restarts if it dies.
- **Why a hidden window?** So the background loop does not keep a console window
  on screen. In Session 0 (SYSTEM) there is no interactive desktop at all.

You are encouraged to read every line before running, and to scan the folder
with your own tools (e.g. <https://www.virustotal.com>). You can verify any file
against your own copy with `Get-FileHash <file> -Algorithm SHA256`.
**Run at your own risk.**

## Disclaimer

This project is **not affiliated with Microsoft or Sysinternals**. RAMMap is a
Microsoft tool distributed under its own license; download it only from the
official link above and do not redistribute the binary. This script is
provided **as-is, without warranty of any kind**.

## Contributors
1. Deepseek v4 pro/flash
2. Claude Opus 4.8

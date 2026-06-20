# RAMMap Auto Memory Cleaner

[English](README.md) | [简体中文](README.zh-CN.md)

A lightweight Windows background service that automatically frees up physical
memory when usage crosses a configurable threshold, using the Microsoft
Sysinternals **RAMMap** tool.

## How it works

A batch script polls physical memory usage at a fixed interval. When usage
rises above the threshold, it calls `RAMMap64.exe` to empty the working sets,
system working set, and modified page list, then logs how much was freed.

| Component | Role |
|-----------|------|
| `memory_cleaner.bat` | Core loop: poll memory, run RAMMap when above threshold, write log |
| `memory_cleaner.vbs` | Launcher that starts the loop hidden and elevated |
| `schtasks_install.ps1` | Registers a scheduled task so the service starts at logon and auto-restarts |
| `schtasks_install.bat` | Convenience wrapper that elevates and runs the installer |

RAMMap flags used:

- `-Ew` — Empty Working Sets
- `-Es` — Empty System Working Set
- `-Em` — Empty Modified Page List

## Requirements

- Windows (tested on Windows 10/11)
- Administrator privileges (RAMMap needs admin to empty memory lists)
- `RAMMap64.exe` — **not bundled**; download it from the official source (see below)

## Setup

1. Download RAMMap from Microsoft and place `RAMMap64.exe` in the **same folder**
   as the scripts:
   <https://learn.microsoft.com/sysinternals/downloads/rammap>

2. (Optional) Adjust the settings at the top of `memory_cleaner.bat`:

   ```bat
   set THRESHOLD=80     :: clean when memory usage >= 80%
   set INTERVAL=30      :: check every 30 seconds
   ```

3. Run `schtasks_install.bat` (it will request administrator privileges). It
   registers a scheduled task named `MemoryCleaner` that:
   - starts the cleaner at logon,
   - repeats every 5 minutes so it auto-restarts if the process dies,
   - runs with highest privileges to avoid a UAC prompt on every trigger.

4. To start immediately without logging off again:

   ```bat
   schtasks /run /tn "MemoryCleaner"
   ```

## Uninstall

```bat
schtasks /delete /tn "MemoryCleaner" /f
```

## ⚠️ Security notice — please read

These scripts intentionally use techniques that **antivirus software may flag**:
elevation to administrator, a hidden launcher window, and a persistent
scheduled task. This is the same pattern some malware uses, so a false positive
is possible. Everything here is plain text and fully auditable:

- **Why administrator?** RAMMap requires admin rights to empty memory lists.
- **Why a scheduled task at highest privileges?** So the service can run in the
  background without prompting for UAC every few minutes.
- **Why a hidden window?** So the background loop does not keep a console window
  on screen. Change the trailing `0` to `1` in `memory_cleaner.vbs` to make it
  visible.

You are encouraged to read every line before running, and to scan the folder
with your own tools (e.g. <https://www.virustotal.com>). **Run at your own risk.**

### Virus scan reports

The two scripts most likely to trigger antivirus heuristics have been scanned on
VirusTotal. Each report's SHA-256 matches the file in this repository, so you can
verify it yourself with `Get-FileHash <file> -Algorithm SHA256`:

- `memory_cleaner.bat` —
  <https://www.virustotal.com/gui/file/77cfe7f3bf0b310cacdd4450ea3cd65c8440cec1a92c967eb64e5eaf6257c4cf>
- `schtasks_install.ps1` —
  <https://www.virustotal.com/gui/file/d8fb7f6c0dc854622df7907164aa8babab9cefb392eeaa362ec4716e84adba3e>

## Disclaimer

This project is **not affiliated with Microsoft or Sysinternals**. RAMMap is a
Microsoft tool distributed under its own license; download it only from the
official link above and do not redistribute the binary. These scripts are
provided **as-is, without warranty of any kind**. Add a `LICENSE` file of your
choice before publishing.

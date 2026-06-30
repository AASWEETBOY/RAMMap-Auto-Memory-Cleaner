<#
.SYNOPSIS
    RAMMap Memory Guard — 后台内存监控与自动清理守护服务

.DESCRIPTION
    持续监控物理内存使用率，超过阈值时自动调用 Sysinternals RAMMap
    执行内存清理（清空工作集、系统缓存、已修改页面列表）。

    通过 Windows Task Scheduler 实现 keep-alive：用户登录时启动，
    每 5 分钟自动检测，若进程已崩溃则自动重新拉起。

    单脚本替代原有 memory_cleaner.bat + memory_cleaner.vbs + schtasks_install.ps1 + schtasks_install.bat。

.PARAMETER Threshold
    内存使用率触发阈值（百分比），默认 80。

.PARAMETER Interval
    内存采样间隔（秒），默认 30。

.PARAMETER CleanupCooldown
    两次清理之间的最小间隔（分钟），默认 5，防止高频清理。

.PARAMETER Operations
    要执行的 RAMMap 清理操作，可选 Ew, Es, Em 的任意子集。默认全部。

.PARAMETER LogPath
    日志文件路径。默认为脚本同级目录下按日期滚动的 memory_cleaner_YYYYMMDD.log。

.PARAMETER WhatIf
    诊断模式：采样并报告但不执行 RAMMap 清理动作，不写入日志文件。

.PARAMETER Install
    安装模式：在 Task Scheduler 中注册 keep-alive 任务。

.PARAMETER Uninstall
    卸载模式：从 Task Scheduler 中删除 keep-alive 任务。

.PARAMETER RunGuardInterval
    keep-alive 间隔（分钟），默认 5。仅与 -Install 配合使用。

.PARAMETER Force
    安装时若任务已存在则先删除再重新创建。卸载时跳过确认提示。

.EXAMPLE
    RAMMapMemoryGuard.ps1
    启动监控守护进程（需管理员权限）。

.EXAMPLE
    RAMMapMemoryGuard.ps1 -Threshold 90 -Interval 60
    以 90% 阈值、60 秒采样间隔启动。

.EXAMPLE
    RAMMapMemoryGuard.ps1 -WhatIf
    诊断模式：仅报告不执行清理。

.EXAMPLE
    RAMMapMemoryGuard.ps1 -Install
    安装到 Task Scheduler（keep-alive）。

.EXAMPLE
    RAMMapMemoryGuard.ps1 -Uninstall
    从 Task Scheduler 移除。

.NOTES
    文件名: RAMMapMemoryGuard.ps1
    重构日期: 2026-06-30
    原文件: memory_cleaner.bat, memory_cleaner.vbs, schtasks_install.ps1, schtasks_install.bat
#>

[CmdletBinding(DefaultParameterSetName = "Monitor")]
param(
    [Parameter(ParameterSetName = "Monitor")]
    [ValidateRange(1, 99)]
    [int] $Threshold = 80,

    [Parameter(ParameterSetName = "Monitor")]
    [ValidateRange(5, 3600)]
    [int] $Interval = 30,

    [Parameter(ParameterSetName = "Monitor")]
    [ValidateRange(1, 1440)]
    [int] $CleanupCooldown = 5,

    [Parameter(ParameterSetName = "Monitor")]
    [ValidateSet("Ew", "Es", "Em")]
    [string[]] $Operations = @("Ew", "Es", "Em"),

    [Parameter(ParameterSetName = "Monitor")]
    [string] $LogPath,

    [Parameter(ParameterSetName = "Monitor")]
    [switch] $WhatIf,

    [Parameter(ParameterSetName = "Install")]
    [switch] $Install,

    [Parameter(ParameterSetName = "Install")]
    [ValidateRange(1, 1440)]
    [int] $RunGuardInterval = 5,

    [Parameter(ParameterSetName = "Uninstall")]
    [switch] $Uninstall,

    [Parameter(ParameterSetName = "Install")]
    [Parameter(ParameterSetName = "Uninstall")]
    [switch] $Force
)

# =============================================================================
# Constants
# =============================================================================
Set-Variable -Name MUTEX_NAME_GLOBAL -Value "Global\RAMMapMemoryGuard" -Option Constant
Set-Variable -Name MUTEX_NAME_LOCAL  -Value "Local\RAMMapMemoryGuard"  -Option Constant
# The active mutex name is resolved at runtime (Local fallback if Global fails)
Set-Variable -Name TASK_NAME  -Value "RAMMapMemoryGuard"       -Option Constant
Set-Variable -Name RAMMAP_EXE -Value "RAMMap64.exe"            -Option Constant

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = $MyInvocation.MyCommand.Path
$OSInfo     = Get-CimInstance -ClassName Win32_OperatingSystem
$TotalMemKB = [int64] $OSInfo.TotalVisibleMemorySize
$TotalMemMB = [int64] ($TotalMemKB / 1024)
$TotalMemGB = [math]::Round($TotalMemKB / 1048576.0, 1)

# =============================================================================
# Helper Functions
# =============================================================================

function Get-TimeStamp {
    return Get-Date -Format "yyyy/MM/dd HH:mm:ss"
}

function Write-Log {
    param([string] $Message)
    $ts  = Get-TimeStamp
    $line = "[$ts] $Message"

    if (-not $WhatIf) {
        $today = Get-Date -Format "yyyyMMdd"
        $logFile = if ($LogPath) { $LogPath } else { Join-Path $ScriptDir "memory_cleaner_$today.log" }
        $line | Out-File -FilePath $logFile -Append -Encoding utf8
    }

    # Console echo: always, unless running fully hidden from Task Scheduler
    Write-Host $line
}

function Write-Screen {
    <# Screen-only output (banner, summary) — logged to file as well, but intended for interactive use. #>
    param([string] $Message)
    $ts  = Get-TimeStamp
    $line = "[$ts] $Message"
    Write-Host $line
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SystemAccount {
    <# Returns $true if running as LOCAL SYSTEM (S-1-5-18) — e.g. via Boot trigger #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity.User.Value -eq 'S-1-5-18'
}

function Request-Administrator {
    Write-Host "Requesting administrator privileges..."
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName  = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    $psi.Verb      = "runas"
    try {
        [Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        Write-Host "[ERROR] Failed to elevate: $_" -ForegroundColor Red
        exit 2
    }
    exit 0
}

function Get-MemoryStatus {
    <# Returns [PSCustomObject] with TotalKB, FreeKB, UsedKB, UsedPct #>
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $total = [int64] $os.TotalVisibleMemorySize
        $free  = [int64] $os.FreePhysicalMemory
        $used  = $total - $free
        $pct   = if ($total -gt 0) { [math]::Round($used * 100.0 / $total, 1) } else { 0 }
        return [PSCustomObject] @{
            TotalKB = $total
            FreeKB  = $free
            UsedKB  = $used
            UsedPct = $pct
        }
    } catch {
        Write-Log "ERROR: Failed to query memory via WMI: $_"
        return $null
    }
}

function Invoke-RAMMapCleanup {
    <# Runs RAMMap with the specified operations. Returns $true if all succeeded. #>
    param([string[]] $Ops)

    $rammapPath = Join-Path $ScriptDir $RAMMAP_EXE
    $allOk = $true

    foreach ($op in $Ops) {
        $opDesc = switch ($op) {
            "Ew" { "Empty Working Set" }
            "Es" { "Empty System Working Set" }
            "Em" { "Empty Modified Page List" }
        }

        if ($WhatIf) {
            Write-Screen "  [WHATIF] Would run: $RAMMAP_EXE -$op ($opDesc)"
            continue
        }

        try {
            $proc = Start-Process -FilePath $rammapPath -ArgumentList "-$op" `
                                  -WindowStyle Hidden -PassThru

            if ($proc -and -not $proc.WaitForExit(15000)) {
                Write-Log "WARNING: $RAMMAP_EXE -$op ($opDesc) timed out (15s), killing..."
                try { $proc.Kill() } catch {}
                $allOk = $false
            } elseif ($proc -and $proc.ExitCode -ne 0) {
                Write-Log "WARNING: $RAMMAP_EXE -$op ($opDesc) exited with code $($proc.ExitCode)"
                $allOk = $false
            }
        } catch {
            Write-Log "ERROR: Failed to start $RAMMAP_EXE -$op ($opDesc): $_"
            $allOk = $false
        }

        if (-not $WhatIf) {
            Start-Sleep -Seconds 3
        }
    }

    return $allOk
}

function Register-KeepAliveTask {
    param([int] $GuardInterval)

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "  RAMMap Memory Guard — Install" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""

    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $root = $svc.GetFolder("\")

        # Remove existing task if present
        try {
            $root.DeleteTask($TASK_NAME, 0)
            Write-Host "  [OK] Removed existing task." -ForegroundColor Green
        } catch {
            Write-Host "  [OK] No existing task to remove."
        }

        $def = $svc.NewTask(0)

        # --- Settings ---
        $def.Settings.StartWhenAvailable       = $true
        $def.Settings.DisallowStartIfOnBatteries = $false
        $def.Settings.StopIfGoingOnBatteries   = $false
        $def.Settings.ExecutionTimeLimit       = "PT0S"
        $def.Settings.Enabled                  = $true
        $def.Settings.AllowHardTerminate       = $true
        $def.Settings.Compatibility            = 2  # TASK_COMPATIBILITY_V2

        # --- Principal ---
        $def.Principal.UserId   = "SYSTEM"
        $def.Principal.LogonType = 5  # TASK_LOGON_SERVICE_ACCOUNT
        $def.Principal.RunLevel  = 1  # Highest

        # --- Trigger: at system boot + repeat every N minutes ---
        # BOOT trigger runs in Session 0 (no interactive desktop, no windows at all).
        $trigger = $def.Triggers.Create(8)  # TASK_TRIGGER_BOOT
        $trigger.Enabled               = $true
        $trigger.Repetition.Interval   = "PT${GuardInterval}M"
        $trigger.Repetition.Duration   = "P365D"

        # --- Action: powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "<script>" ---
        $action = $def.Actions.Create(0)  # TASK_ACTION_EXEC
        $action.Path      = "powershell.exe"
        $action.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""

        # --- Register with SERVICE_ACCOUNT logon (no password needed for SYSTEM) ---
        $root.RegisterTaskDefinition($TASK_NAME, $def, 6, $null, $null, 5)
        # Flags: 6 = TASK_CREATE_OR_UPDATE, 3 = TASK_LOGON_NONE

        Write-Host ""
        Write-Host "==============================================" -ForegroundColor Green
        Write-Host "  [OK] Keep-Alive Task Registered" -ForegroundColor Green
        Write-Host "==============================================" -ForegroundColor Green
        Write-Host "  Task name   : $TASK_NAME"
        Write-Host "  Script      : $ScriptPath"
        Write-Host "  Trigger     : At system boot + every ${GuardInterval} min"
        Write-Host "  Principal   : SYSTEM (Session 0 — no window, no popup)"
        Write-Host "  Action      : powershell.exe -WindowStyle Hidden ..."
        Write-Host ""
        Write-Host "  The task runs in Session 0 (background), completely invisible."
        Write-Host "  If the guard process dies, it auto-restarts"
        Write-Host "  within ${GuardInterval} minutes via the repetition trigger."
        Write-Host ""
        Write-Host "  To start now (or after installation):"
        Write-Host "    schtasks /run /tn `"$TASK_NAME`""
        Write-Host ""
        Write-Host "  To uninstall:"
        Write-Host "    powershell -File `"$ScriptPath`" -Uninstall"
        Write-Host "==============================================" -ForegroundColor Green

    } catch {
        Write-Host "[ERROR] Failed to register task: $_" -ForegroundColor Red
        exit 3
    }
}

function Unregister-KeepAliveTask {
    if (-not $Force) {
        Write-Host "This will remove the '$TASK_NAME' scheduled task."
        $confirm = Read-Host "Are you sure? (y/N)"
        if ($confirm -notmatch '^[yY]') {
            Write-Host "Cancelled."
            exit 0
        }
    }

    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $root = $svc.GetFolder("\")
        $root.DeleteTask($TASK_NAME, 0)
        Write-Host "[OK] Task '$TASK_NAME' removed from Task Scheduler." -ForegroundColor Green
    } catch {
        Write-Host "[INFO] Task '$TASK_NAME' was not found (already removed)." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Note: If the guard process is currently running, kill it manually:"
    Write-Host "  Stop-Process -Name RAMMap64 -Force"
    Write-Host "  (The PowerShell host will exit on its own within the interval.)"
}

# =============================================================================
# Main Entry Point
# =============================================================================

# --- Dispatch: install / uninstall / monitor ---
if ($Install) {
    if (-not (Test-Administrator)) { Request-Administrator }
    Register-KeepAliveTask -GuardInterval $RunGuardInterval
    exit 0
}

if ($Uninstall) {
    if (-not (Test-Administrator)) { Request-Administrator }
    Unregister-KeepAliveTask
    exit 0
}

# --- Verify RAMMap exists ---
$rammapFullPath = Join-Path $ScriptDir $RAMMAP_EXE
if (-not $WhatIf -and -not (Test-Path $rammapFullPath)) {
    Write-Host "[ERROR] $RAMMAP_EXE not found at: $ScriptDir" -ForegroundColor Red
    Write-Host "        Please place RAMMap64.exe in the same directory as this script."
    exit 4
}

# --- Mutex-based single-instance guard ---
$mutex = $null
$createdNew = $false
$activeMutexName = $MUTEX_NAME_GLOBAL

try {
    $mutex = [System.Threading.Mutex]::new($true, $MUTEX_NAME_GLOBAL, [ref] $createdNew)
} catch {
    # Global\ namespace requires admin on some systems; fall back to Local\
    Write-Host "[INFO] Global mutex unavailable, falling back to Local namespace." -ForegroundColor Yellow
    try {
        $mutex = [System.Threading.Mutex]::new($true, $MUTEX_NAME_LOCAL, [ref] $createdNew)
        $activeMutexName = $MUTEX_NAME_LOCAL
    } catch {
        Write-Host "[ERROR] Failed to create mutex: $_" -ForegroundColor Red
        exit 5
    }
}

if (-not $createdNew) {
    # Another instance is already running — exit silently (keep-alive relies on this)
    $mutex.Dispose()
    exit 0
}

# --- Auto-elevate in monitor mode (skip in WhatIf diagnostic mode) ---
# Boot-triggered SYSTEM account already has all privileges — no elevation needed.
if (-not $WhatIf -and -not (Test-Administrator) -and -not (Test-SystemAccount)) {
    $mutex.Dispose()
    Request-Administrator
}

# =============================================================================
# Monitoring Loop
# =============================================================================

Write-Screen "=============================================="
Write-Screen "  RAMMap Memory Guard v2.0"
Write-Screen "=============================================="
Write-Screen "  Threshold     : ${Threshold}%"
Write-Screen "  Check every   : ${Interval}s"
Write-Screen "  Cooldown      : ${CleanupCooldown}min"
Write-Screen "  Operations    : $($Operations -join ', ')"
Write-Screen "  RAMMap        : $rammapFullPath"
Write-Screen "  Total Memory  : ${TotalMemGB} GB"
Write-Screen "  Mutex         : $activeMutexName"
if ($WhatIf) {
    Write-Screen "  MODE          : DIAGNOSTIC (WhatIf) — no cleanup will run"
}
Write-Screen "=============================================="

$initial = Get-MemoryStatus
if ($initial) {
    Write-Log "Service started. Initial memory: $($initial.UsedPct)% ($($initial.UsedKB) KB used / $($initial.TotalKB) KB total)"
} else {
    Write-Log "Service started. (Unable to read initial memory status.)"
}

$lastCleanupTime = [DateTime]::MinValue

while ($true) {
    try {
        $mem = Get-MemoryStatus
        if (-not $mem) {
            Write-Log "WARNING: Failed to query memory, skipping this cycle."
            Start-Sleep -Seconds $Interval
            continue
        }

        Write-Log "Memory: $($mem.UsedPct)% ($($mem.UsedKB) KB used / $($mem.TotalKB) KB total)"

        if ($mem.UsedPct -ge $Threshold) {
            $sinceLast = [DateTime]::Now - $lastCleanupTime
            if ($sinceLast.TotalMinutes -ge $CleanupCooldown) {
                Write-Log "WARNING: Memory exceeds ${Threshold}% threshold! Cleaning..."

                $beforeFree = $mem.FreeKB
                $cleanOk = Invoke-RAMMapCleanup -Ops $Operations

                # Re-sample after cleanup
                Start-Sleep -Seconds 2
                $afterMem = Get-MemoryStatus
                if ($afterMem) {
                    $freedKB = $afterMem.FreeKB - $beforeFree
                    $freedMB = [int] ($freedKB / 1024)

                    if ($freedMB -gt 0) {
                        Write-Log "CLEANUP: After cleanup: $($afterMem.UsedPct)% used (freed ~${freedMB} MB)"
                    } elseif ($cleanOk) {
                        Write-Log "CLEANUP: Completed, but no significant memory freed."
                    } else {
                        Write-Log "CLEANUP: Completed with errors."
                    }
                } else {
                    Write-Log "CLEANUP: Completed, but failed to re-sample memory."
                }

                $lastCleanupTime = [DateTime]::Now
            } else {
                $waitMinutes = [math]::Round($CleanupCooldown - $sinceLast.TotalMinutes, 1)
                Write-Log "SKIP: Threshold exceeded but cooldown active (${waitMinutes} min remaining before next cleanup)."
            }
        } else {
            Write-Log "OK: Memory below threshold."
        }

    } catch {
        Write-Log "ERROR in monitoring loop: $_"
    }

    Start-Sleep -Seconds $Interval
}

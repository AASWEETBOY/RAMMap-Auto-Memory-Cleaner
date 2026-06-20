#Requires -RunAsAdministrator

$TaskName = "MemoryCleaner"
# Derive the VBS path from this script's own folder so it works wherever the
# project is placed (no hardcoded drive/path).
$VbsPath = Join-Path $PSScriptRoot "memory_cleaner.vbs"

Write-Host "=============================================="
Write-Host "  RAMMap Memory Cleaner - Keep-Alive Install"
Write-Host "=============================================="
Write-Host ""

# Use Task Scheduler COM API (most reliable method)
$Service = New-Object -ComObject Schedule.Service
$Service.Connect()
$RootFolder = $Service.GetFolder("\")

# Remove existing task
try {
    $RootFolder.DeleteTask($TaskName, 0)
    Write-Host "[OK] Old task cleaned."
} catch {
    Write-Host "[OK] No existing task to remove."
}

# Create empty task definition
$TaskDef = $Service.NewTask(0)

# === Settings ===
$TaskDef.Settings.StartWhenAvailable = $true
$TaskDef.Settings.DisallowStartIfOnBatteries = $false
$TaskDef.Settings.StopIfGoingOnBatteries = $false
$TaskDef.Settings.ExecutionTimeLimit = "PT0S"  # no limit
$TaskDef.Settings.Enabled = $true
$TaskDef.Settings.AllowHardTerminate = $true

# === Principal ===
# RunLevel "Highest" is needed because RAMMap requires administrator rights to
# empty memory lists. It also lets the task run unattended in the background
# without a UAC prompt on every 5-minute trigger.
$TaskDef.Principal.UserId = $env:USERNAME
$TaskDef.Principal.LogonType = 3   # InteractiveToken
$TaskDef.Principal.RunLevel = 1    # Highest (TASK_RUNLEVEL_HIGHEST)

# === Trigger: At logon + repeat every 5 min ===
$Trigger = $TaskDef.Triggers.Create(9)   # TASK_TRIGGER_LOGON = 9
$Trigger.UserId = $env:USERNAME
$Trigger.Enabled = $true
$Trigger.Repetition.Interval = "PT5M"   # every 5 min
$Trigger.Repetition.Duration = "P365D"  # repeat for 365 days (renews next logon)

# === Action: wscript.exe memory_cleaner.vbs ===
$Action = $TaskDef.Actions.Create(0)    # TASK_ACTION_EXEC = 0
$Action.Path = "wscript.exe"
$Action.Arguments = $VbsPath

# === Register task ===
$RootFolder.RegisterTaskDefinition($TaskName, $TaskDef, 6, $null, $null, 3)
# Flags: 6 = CreateOrUpdate, 3 = LogonNone (use principal's user)

Write-Host ""
Write-Host "=============================================="
Write-Host "  [OK] Keep-Alive Task Installed"
Write-Host "=============================================="
Write-Host "  Task name   : $TaskName"
Write-Host "  Trigger     : At logon + every 5 min"
Write-Host "  Privilege   : Highest (unattended; avoids repeat UAC prompts)"
Write-Host "  Action      : wscript.exe $VbsPath"
Write-Host ""
Write-Host "  If the monitor process dies, it auto-restarts"
Write-Host "  within 5 minutes via the next trigger."
Write-Host ""
Write-Host "  To start now:"
Write-Host "    schtasks /run /tn ""$TaskName"""
Write-Host "=============================================="

Read-Host "Press Enter to exit"

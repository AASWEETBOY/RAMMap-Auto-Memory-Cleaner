' RAMMap Memory Monitor - Launcher (Hidden Window, Auto-Elevate)
' 使用 ShellExecute "runas" 请求管理员权限并隐藏窗口启动 memory_cleaner.bat
' 已被提权时不会弹出 UAC 对话框（如通过管理员计划任务启动）

Dim scriptPath, objShell
scriptPath = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\memory_cleaner.bat"

Set objShell = CreateObject("Shell.Application")
objShell.ShellExecute "cmd.exe", "/c """ & scriptPath & """", "", "runas", 0

Set objShell = Nothing

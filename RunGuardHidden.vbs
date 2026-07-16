Option Explicit

Dim shell, fileSystem, scriptDirectory, powershellExe, guardScript, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellExe = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
guardScript = fileSystem.BuildPath(scriptDirectory, "BaiduMediaGuard.ps1")

command = Quote(powershellExe) & _
    " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass" & _
    " -WindowStyle Hidden -File " & Quote(guardScript) & " -Guard -Quiet"

WScript.Quit shell.Run(command, 0, True)

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function

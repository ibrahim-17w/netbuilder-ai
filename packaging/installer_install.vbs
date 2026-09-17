Option Explicit

Dim shell, fso, scriptDir, scriptPath, payloadPath, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(scriptDir, "installer_install.ps1")
payloadPath = fso.BuildPath(scriptDir, "payload.zip")
command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Quote(scriptPath) & " -Payload " & Quote(payloadPath)
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function

# Adds AutoCopy to Windows startup and starts it now.
$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut((Join-Path $startup 'AutoCopy.lnk'))
$sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$sc.Arguments = '"' + (Join-Path $PSScriptRoot 'Start-AutoCopy.vbs') + '"'
$sc.WorkingDirectory = $PSScriptRoot
$sc.Description = 'Auto Copy - copies new downloads and captures to the clipboard'
$sc.Save()

Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $PSScriptRoot 'Start-AutoCopy.vbs') + '"')
Write-Host 'AutoCopy installed to startup and running now (check the system tray).'

# Stops AutoCopy and removes it from Windows startup.
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'AutoCopy.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force }

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*AutoCopy.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Write-Host 'AutoCopy stopped and removed from startup.'

# remove the iPhone-codes firewall rule, if it was added (needs admin)
if (Get-NetFirewallRule -DisplayName 'AutoCopy - iPhone codes' -ErrorAction SilentlyContinue) {
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command', "Remove-NetFirewallRule -DisplayName 'AutoCopy - iPhone codes'"
    Write-Host 'Removed the "AutoCopy - iPhone codes" firewall rule.'
}

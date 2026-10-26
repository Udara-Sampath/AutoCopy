# Lets an iPhone Shortcut on your home network send one-time codes to AutoCopy.
# Right-click -> Run with PowerShell. It asks for admin rights (needed to change
# Windows Firewall).
#
# What it does:
#   1. Adds ONE narrow firewall rule: only AutoCopy's port (47321), only from
#      devices on your local network, only when Windows marks the network as
#      Private (home), never on public Wi-Fi.
#   2. Offers to remove the broad "Windows PowerShell" allow rules that a
#      firewall pop-up creates (any port, any address, public networks too).
#
# Undo: run Uninstall.ps1, or delete the rule "AutoCopy - iPhone codes" in
# Windows Defender Firewall -> Advanced settings -> Inbound Rules.

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    exit
}

$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

Get-NetFirewallRule -DisplayName 'AutoCopy - iPhone codes' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'AutoCopy - iPhone codes' `
    -Description 'Lets an iPhone Shortcut on the home network send one-time codes to AutoCopy (port 47321, local subnet, Private networks only).' `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 47321 `
    -RemoteAddress LocalSubnet -Profile Private -Program $ps | Out-Null
Write-Host 'Added firewall rule "AutoCopy - iPhone codes" (port 47321, local network, Private networks only).' -ForegroundColor Green

$broad = Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
         Where-Object { $_.Program -like '*\powershell.exe' } | Get-NetFirewallRule |
         Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and $_.Name -like '*Query User*' }
if ($broad) {
    Write-Host ''
    Write-Host "Found $(@($broad).Count) broad rule(s) letting ANY PowerShell script accept connections on any port," -ForegroundColor Yellow
    Write-Host 'including on public Wi-Fi. They were created by clicking "Allow" on a firewall pop-up.' -ForegroundColor Yellow
    $a = Read-Host 'Remove them? AutoCopy does not need them. (Y/n)'
    if ($a -notmatch '^[nN]') {
        $broad | Remove-NetFirewallRule
        Write-Host 'Removed.' -ForegroundColor Green
    }
}

Write-Host ''
Read-Host 'Done. Press Enter to close'

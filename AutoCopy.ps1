# AutoCopy — watches Downloads / Screenshots / Screen Recordings and copies
# every new finished file to the clipboard so it can be pasted anywhere.
# Runs as a system-tray app. Right-click the tray icon to Pause or Exit.
#
# Also provides global quick-action hotkeys (work everywhere, including games).
#
# AutoCopy.ps1 -Settings   opens the hotkey settings window (starts the app if
#                          it isn't running yet).
param([switch]$Settings)

# --- quick-action hotkeys: defaults --------------------------------------------
# Change them from the tray icon -> "Settings..." (or double-click the
# tray icon). Your choices are saved permanently to
# %APPDATA%\AutoCopy\settings.json and override these defaults.
# Format: modifiers + key, e.g. 'Ctrl+Alt+M', 'Pause', 'F13'. '' = off.
$Hotkeys = @{
    ToggleMicMute = 'Ctrl+Alt+F12'   # mute / unmute every microphone
}
$script:settingsPath = Join-Path $env:APPDATA 'AutoCopy\settings.json'

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- single instance guard ---------------------------------------------------
$script:mutex = New-Object System.Threading.Mutex($false, 'AutoCopyClipboardWatcher')
$acquired = $false
try { $acquired = $script:mutex.WaitOne(0, $false) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
Add-Content -Path (Join-Path $env:TEMP 'AutoCopy.log') -Value "$(Get-Date -Format o) PID=$PID acquired=$acquired"
# signal the running copy to open its settings window
$script:showSettingsEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'AutoCopyShowSettings')
if (-not $acquired) {
    if ($Settings) { [void]$script:showSettingsEvent.Set() }
    exit
}

# --- folders to watch --------------------------------------------------------
$folders = New-Object System.Collections.Generic.List[string]

$dl = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders').'{374DE290-123F-4565-9164-39C4925E467B}'
if ($dl) { $folders.Add([Environment]::ExpandEnvironmentVariables($dl)) }

$pictures = [Environment]::GetFolderPath('MyPictures')
$videos   = [Environment]::GetFolderPath('MyVideos')
$folders.Add((Join-Path $pictures 'Screenshots'))        # Snipping Tool / Win+PrtScn screenshots
$folders.Add((Join-Path $videos   'Screen Recordings'))  # Snipping Tool video recordings
$folders.Add((Join-Path $videos   'Captures'))           # Xbox Game Bar recordings

$watchFolders = @()
foreach ($f in ($folders | Select-Object -Unique)) {
    if (-not $f) { continue }
    if (-not (Test-Path -LiteralPath $f)) {
        try { New-Item -ItemType Directory -Path $f -Force | Out-Null } catch { continue }
    }
    $watchFolders += $f
}

# --- state -------------------------------------------------------------------
$script:pending   = @{}      # path -> @{ Size; Stable; FirstSeen }
$script:paused    = $false
$script:ignoreExt = @('.tmp','.crdownload','.part','.partial','.download','.opdownload','.aria2','.td','.!ut','.!qb')

# --- hidden form (marshals watcher events onto this UI thread) ---------------
$form = New-Object System.Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState   = 'Minimized'
$form.Opacity       = 0
$null = $form.Handle

# --- tray icon ---------------------------------------------------------------
$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon    = [System.Drawing.SystemIcons]::Application
$script:notify.Text    = 'Auto Copy - watching'
$script:notify.Visible = $true

function Copy-FileToClipboard([string]$Path) {
    try {
        $col = New-Object System.Collections.Specialized.StringCollection
        [void]$col.Add($Path)
        $data = New-Object System.Windows.Forms.DataObject
        $data.SetFileDropList($col)

        # For images, also put the bitmap on the clipboard so paint/photo apps can paste it too
        $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
        if ($ext -in '.png','.jpg','.jpeg','.bmp','.gif') {
            try {
                $ms  = New-Object IO.MemoryStream(,[IO.File]::ReadAllBytes($Path))
                $img = [System.Drawing.Image]::FromStream($ms)
                $data.SetImage($img)
            } catch { }
        }

        [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)

        $name = [IO.Path]::GetFileName($Path)
        $tip  = "Auto Copy - last: $name"
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $script:notify.Text = $tip
        $script:notify.ShowBalloonTip(1500, 'Copied to clipboard', $name, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
}

# --- tray menu ---------------------------------------------------------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$pauseItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Pause'
$pauseItem.CheckOnClick = $true
$pauseItem.add_Click({
    $script:paused = $pauseItem.Checked
    $script:notify.Text = if ($script:paused) { 'Auto Copy - paused' } else { 'Auto Copy - watching' }
})
[void]$menu.Items.Add($pauseItem)

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
$exitItem.add_Click({
    foreach ($w in $script:watchers) { try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch { } }
    if ($script:hotkeyWindow) { try { $script:hotkeyWindow.Dispose() } catch { } }
    if ($script:overlay)      { try { $script:overlay.Close() } catch { } }
    if (Get-Command Stop-PhoneBridge -ErrorAction SilentlyContinue) { Stop-PhoneBridge }
    $script:notify.Visible = $false
    $script:notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
[void]$menu.Items.Add($exitItem)

$script:notify.ContextMenuStrip = $menu

# --- quick actions: global hotkeys + mic mute overlay ------------------------
$script:quickOk = $false
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'QuickActions.cs') -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
    $script:quickOk = $true
} catch {
    Add-Content -Path (Join-Path $env:TEMP 'AutoCopy.log') -Value "$(Get-Date -Format o) QuickActions failed to load: $_"
}

# --- one-time codes: copy OTPs from phone messages (via Phone Link) -----------
$script:otp = @{ Enabled = $true; AllApps = $false; Token = '' }   # Token: secret part of the iPhone Shortcut address
$script:otpOk = $false
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'SqliteLite.cs') -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'OtpWatcher.ps1')
    . (Join-Path $PSScriptRoot 'PhoneBridge.ps1')
    $script:otpOk = $true
} catch {
    Add-Content -Path (Join-Path $env:TEMP 'AutoCopy.log') -Value "$(Get-Date -Format o) OTP watcher failed to load: $_"
}
$script:phoneLinkOk = $false
if ($script:otpOk) {
    try { . (Join-Path $PSScriptRoot 'PhoneLinkReader.ps1'); $script:phoneLinkOk = $true }
    catch { Add-Content -Path (Join-Path $env:TEMP 'AutoCopy.log') -Value "$(Get-Date -Format o) Phone Link reader failed to load: $_" }
}

# load saved settings (override the defaults at the top of this file)
if (Test-Path -LiteralPath $script:settingsPath) {
    try {
        $saved = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json
        foreach ($p in $saved.Hotkeys.PSObject.Properties) { $Hotkeys[$p.Name] = [string]$p.Value }
        if ($null -ne $saved.Otp.Enabled) { $script:otp.Enabled = [bool]$saved.Otp.Enabled }
        if ($null -ne $saved.Otp.AllApps) { $script:otp.AllApps = [bool]$saved.Otp.AllApps }
        if ($saved.Otp.Token) { $script:otp.Token = [string]$saved.Otp.Token }
    } catch { }
}

$otpItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Copy codes from phone messages'
$otpItem.Checked = $script:otp.Enabled
$otpItem.add_Click({
    $script:otp.Enabled = -not $script:otp.Enabled
    $otpItem.Checked = $script:otp.Enabled
    Save-Settings
})

function Invoke-OtpCheck {
    if (-not $script:otp.Enabled -or $script:paused) { $script:otpLastOrder = $null; $script:plSeen = $null; return }
    foreach ($hit in @(Get-NewOtpNotifications $script:otp.AllApps)) { Copy-Otp $hit.Code $hit.Source }
    # iPhone texts usually only show up inside the Phone Link window
    if ($script:phoneLinkOk) {
        foreach ($hit in @(Get-NewPhoneLinkCodes)) { Copy-Otp $hit.Code $hit.Source }
    }
}

function Copy-Otp([string]$Code, [string]$Source) {
    try {
        [System.Windows.Forms.Clipboard]::SetDataObject($Code, $true, 10, 100)
        $script:notify.ShowBalloonTip(4000, "Code copied: $Code", "From $Source - press Ctrl+V to paste it.", [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
}

function Invoke-BridgeCheck {
    # always answer the phone (so the Shortcut doesn't hang), but only copy when enabled
    foreach ($code in @(Get-PhoneBridgeCodes $script:otp.Token)) {
        if ($script:otp.Enabled -and -not $script:paused -and (Test-NewOtp $code)) { Copy-Otp $code 'iPhone' }
    }
}

function ConvertTo-Hotkey([string]$Text) {
    # 'Ctrl+Alt+M' -> @{ Mods = 3; Vk = 77 }   (Alt=1 Ctrl=2 Shift=4 Win=8)
    $mods = 0; $vk = 0
    foreach ($part in ($Text -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        switch -regex ($part) {
            '^(ctrl|control)$' { $mods = $mods -bor 2; continue }
            '^alt$'            { $mods = $mods -bor 1; continue }
            '^shift$'          { $mods = $mods -bor 4; continue }
            '^(win|windows)$'  { $mods = $mods -bor 8; continue }
            default {
                $name = $part
                if ($name -match '^\d$') { $name = "D$name" }
                if ($name -ieq 'ScrollLock') { $name = 'Scroll' }
                if ($name -ieq 'Break')      { $name = 'Pause' }
                try { $vk = [int][enum]::Parse([System.Windows.Forms.Keys], $name, $true) } catch { return $null }
            }
        }
    }
    if ($vk -eq 0) { return $null }
    @{ Mods = [uint32]$mods; Vk = [uint32]$vk }
}

$script:micMuted = $false
$script:overlay  = $null
$script:hotkeyWindow = $null

$micItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Mute microphone'
$micItem.add_Click({ Switch-MicMute })

function Update-MicUi {
    $state = [AutoCopyNative.Mic]::GetState()
    $muted = ($state -eq 1)
    if ($muted -ne $script:micMuted) {
        $script:micMuted = $muted
        $micItem.Checked = $muted
    }
    if ($muted) {
        if (-not $script:overlay.Visible) { $script:overlay.Show() }
        $script:overlay.KeepOnTop()
    } elseif ($script:overlay.Visible) {
        $script:overlay.Hide()
    }
}

function Switch-MicMute {
    $state = [AutoCopyNative.Mic]::GetState()
    if ($state -lt 0) {
        $script:notify.ShowBalloonTip(1500, 'No microphone found', 'There is no active recording device to mute.', [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    try { [AutoCopyNative.Mic]::SetMuted($state -eq 0) } catch { }
    Update-MicUi
}

# Every quick action that can have a hotkey. Add new ones here.
$script:quickActions = @(
    @{ Name = 'ToggleMicMute'; Label = 'Mute / unmute microphone'; Action = { Switch-MicMute }; Item = $micItem }
)

function Register-AllHotkeys {
    # (Re)registers every hotkey from $Hotkeys. Returns the ones that failed.
    $script:hotkeyWindow.UnregisterAll()
    $script:hotkeyActions = @{}
    $failed = @()
    $id = 1
    foreach ($a in $script:quickActions) {
        $text = $Hotkeys[$a.Name]
        $a.Item.ShortcutKeyDisplayString = ''
        if ($text) {
            $hk = ConvertTo-Hotkey $text
            if ($hk -and $script:hotkeyWindow.Register($id, $hk.Mods, $hk.Vk)) {
                $script:hotkeyActions[$id] = $a.Action
                $a.Item.ShortcutKeyDisplayString = $text
            } else {
                $failed += $text
            }
        }
        $id++
    }
    , $failed
}

function Save-Settings {
    $dir = Split-Path -Parent $script:settingsPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    @{ Hotkeys = $Hotkeys; Otp = $script:otp } | ConvertTo-Json | Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
}

function Format-Hotkey($e) {
    # KeyEventArgs -> 'Ctrl+Alt+F12'; $null while only modifiers are held
    $key = $e.KeyCode.ToString()
    if ($key -in 'ControlKey', 'ShiftKey', 'Menu', 'LWin', 'RWin', 'None', 'Escape') { return $null }
    if ($key -match '^D(\d)$') { $key = $Matches[1] }
    $parts = @()
    if ($e.Control) { $parts += 'Ctrl' }
    if ($e.Alt)     { $parts += 'Alt' }
    if ($e.Shift)   { $parts += 'Shift' }
    ($parts + $key) -join '+'
}

# --- hotkey settings window --------------------------------------------------
$script:settingsForm = $null
$script:hkOff = '(off)'

function Show-HotkeySettings {
    if ($script:settingsForm -and -not $script:settingsForm.IsDisposed) { $script:settingsForm.Activate(); return }

    # release the hotkeys while the window is open, so pressing the current
    # combo gets captured by the box instead of triggering the action
    $script:hotkeyWindow.UnregisterAll()

    $scale = 1.0
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g.DpiX / 96; $g.Dispose()

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'AutoCopy - Settings'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterScreen'
    $f.TopMost = $true
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'
    $f.Padding = New-Object System.Windows.Forms.Padding ([int](10 * $scale))

    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.AutoSize = $true; $t.ColumnCount = 3

    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true
    $hint.Text = "Click a box, then press the key or key combination you want.`nBackspace turns a hotkey off. Enter saves, Esc cancels."
    $hint.Margin = New-Object System.Windows.Forms.Padding 3, 3, 3, ([int](10 * $scale))
    $t.Controls.Add($hint, 0, 0); $t.SetColumnSpan($hint, 3)

    $script:hkBoxes = @()
    $row = 1
    foreach ($a in $script:quickActions) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $a.Label; $lbl.AutoSize = $true; $lbl.Anchor = 'Left'

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.ReadOnly = $true; $tb.BackColor = [System.Drawing.Color]::White
        $tb.TextAlign = 'Center'; $tb.ShortcutsEnabled = $false
        $tb.Width = [int](190 * $scale)
        $tb.Tag = $a.Name
        $tb.Text = if ($Hotkeys[$a.Name]) { $Hotkeys[$a.Name] } else { $script:hkOff }
        $tb.add_PreviewKeyDown({ param($s, $e) if ($e.KeyCode -notin 'Escape', 'Return') { $e.IsInputKey = $true } })
        $tb.add_KeyDown({
            param($s, $e)
            $e.SuppressKeyPress = $true; $e.Handled = $true
            if ($e.KeyCode -eq 'Back' -and $e.Modifiers -eq 'None') { $s.Text = $script:hkOff; return }
            $txt = Format-Hotkey $e
            if ($txt) { $s.Text = $txt; $script:hkStatus.Text = '' }
        })
        $tb.add_Enter({ param($s, $e) $s.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 215) })
        $tb.add_Leave({ param($s, $e) $s.BackColor = [System.Drawing.Color]::White })

        $clr = New-Object System.Windows.Forms.Button
        $clr.Text = 'Clear'; $clr.AutoSize = $true; $clr.Tag = $tb
        $clr.add_Click({ param($s, $e) $s.Tag.Text = $script:hkOff })

        $t.Controls.Add($lbl, 0, $row); $t.Controls.Add($tb, 1, $row); $t.Controls.Add($clr, 2, $row)
        $script:hkBoxes += $tb
        $row++
    }

    # one-time codes
    $otpHead = New-Object System.Windows.Forms.Label
    $otpHead.AutoSize = $true
    $otpHead.Text = 'One-time codes'
    $otpHead.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $otpHead.Margin = New-Object System.Windows.Forms.Padding 3, ([int](14 * $scale)), 3, 3
    $t.Controls.Add($otpHead, 0, $row); $t.SetColumnSpan($otpHead, 3); $row++

    $script:otpCheck = New-Object System.Windows.Forms.CheckBox
    $script:otpCheck.AutoSize = $true
    $script:otpCheck.Text = 'Copy verification codes from phone messages (Phone Link)'
    $script:otpCheck.Checked = $script:otp.Enabled
    $t.Controls.Add($script:otpCheck, 0, $row); $t.SetColumnSpan($script:otpCheck, 3); $row++

    $script:otpAllCheck = New-Object System.Windows.Forms.CheckBox
    $script:otpAllCheck.AutoSize = $true
    $script:otpAllCheck.Text = 'Also check notifications from PC apps (email, WhatsApp, ...)'
    $script:otpAllCheck.Checked = $script:otp.AllApps
    $script:otpAllCheck.Enabled = $script:otp.Enabled
    $script:otpAllCheck.Margin = New-Object System.Windows.Forms.Padding ([int](20 * $scale)), 0, 3, 3
    $script:otpCheck.add_CheckedChanged({ $script:otpAllCheck.Enabled = $script:otpCheck.Checked })
    $t.Controls.Add($script:otpAllCheck, 0, $row); $t.SetColumnSpan($script:otpAllCheck, 3); $row++

    if ($script:otp.Token) {
        $urls = @(Get-BridgeUrls $script:otp.Token)
        $phoneLbl = New-Object System.Windows.Forms.Label
        $phoneLbl.AutoSize = $true
        $phoneLbl.Text = 'iPhone Shortcut address (paste into "Get Contents of URL"):'
        $phoneLbl.Margin = New-Object System.Windows.Forms.Padding 3, ([int](8 * $scale)), 3, 0
        $t.Controls.Add($phoneLbl, 0, $row); $t.SetColumnSpan($phoneLbl, 3); $row++
        foreach ($u in $urls) {
            $ub = New-Object System.Windows.Forms.TextBox
            $ub.ReadOnly = $true; $ub.Text = $u; $ub.Dock = 'Fill'
            $ub.Width = [int](380 * $scale)
            $t.Controls.Add($ub, 0, $row); $t.SetColumnSpan($ub, 2)
            $cp = New-Object System.Windows.Forms.Button
            $cp.Text = 'Copy'; $cp.AutoSize = $true; $cp.Tag = $u
            $cp.add_Click({ param($s, $e) [System.Windows.Forms.Clipboard]::SetText($s.Tag); $s.Text = 'Copied' })
            $t.Controls.Add($cp, 2, $row); $row++
        }
        $reset = New-Object System.Windows.Forms.LinkLabel
        $reset.AutoSize = $true
        $reset.Text = 'Make a new secret address (the old one stops working)'
        $reset.add_LinkClicked({
            $script:otp.Token = New-BridgeToken
            Save-Settings
            $script:settingsForm.Close()
            Show-HotkeySettings
        })
        $t.Controls.Add($reset, 0, $row); $t.SetColumnSpan($reset, 3); $row++
    }

    $script:hkStatus = New-Object System.Windows.Forms.Label
    $script:hkStatus.AutoSize = $true
    $script:hkStatus.ForeColor = [System.Drawing.Color]::Firebrick
    $script:hkStatus.MaximumSize = New-Object System.Drawing.Size ([int](480 * $scale)), 0
    $t.Controls.Add($script:hkStatus, 0, $row); $t.SetColumnSpan($script:hkStatus, 3); $row++

    $btns = New-Object System.Windows.Forms.FlowLayoutPanel
    $btns.AutoSize = $true; $btns.FlowDirection = 'RightToLeft'; $btns.Dock = 'Fill'
    $btns.Margin = New-Object System.Windows.Forms.Padding 0, ([int](8 * $scale)), 0, 0
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.AutoSize = $true
    $cancel.add_Click({ $script:settingsForm.Close() })
    $save = New-Object System.Windows.Forms.Button
    $save.Text = 'Save'; $save.AutoSize = $true
    $save.add_Click({
        $old = $Hotkeys.Clone()
        $used = @{}
        foreach ($b in $script:hkBoxes) {
            $v = if ($b.Text -eq $script:hkOff) { '' } else { $b.Text }
            if ($v -and $used.ContainsKey($v)) { $script:hkStatus.Text = "$v is used twice - give each action its own key."; return }
            # a plain key with no Ctrl/Alt/Shift would stop working everywhere
            # else, so only allow that for keys nobody types with
            if ($v -and $v -notmatch '\+' -and $v -notmatch '^(F([1-9]|1\d|2[0-4])|Pause|Scroll)$') {
                $script:hkStatus.Text = "$v on its own would stop working in every other app. Add Ctrl, Alt or Shift (or use F1-F24, Pause or Scroll Lock)."
                return
            }
            if ($v) { $used[$v] = $true }
            $Hotkeys[$b.Tag] = $v
        }
        $failed = Register-AllHotkeys
        if ($failed.Count) {
            foreach ($k in $old.Keys) { $Hotkeys[$k] = $old[$k] }
            $script:hotkeyWindow.UnregisterAll()
            $script:hkStatus.Text = "$($failed -join ', ') is already used by another program. Pick a different key."
            return
        }
        $script:otp.Enabled = $script:otpCheck.Checked
        $script:otp.AllApps = $script:otpAllCheck.Checked
        $otpItem.Checked = $script:otp.Enabled
        Save-Settings
        $script:settingsForm.Close()
        $script:notify.ShowBalloonTip(1500, 'Settings saved', (($script:quickActions | ForEach-Object { "$($_.Label): $(if ($Hotkeys[$_.Name]) { $Hotkeys[$_.Name] } else { 'off' })" }) -join "`n"), [System.Windows.Forms.ToolTipIcon]::Info)
    })
    $btns.Controls.Add($cancel); $btns.Controls.Add($save)
    $t.Controls.Add($btns, 0, $row); $t.SetColumnSpan($btns, 3)

    $f.Controls.Add($t)
    $f.CancelButton = $cancel
    $f.AcceptButton = $save
    # whatever happens (save, cancel, X), turn the saved hotkeys back on
    $f.add_FormClosed({ [void](Register-AllHotkeys); $script:settingsForm = $null })

    $script:settingsForm = $f
    $f.Show()
    $f.Activate()
}

if ($script:quickOk) {
    [AutoCopyNative.OverlayForm]::EnableDpiAwareness()
    $script:overlay = New-Object AutoCopyNative.OverlayForm 'MIC MUTED'

    $menu.Items.Insert(0, $micItem)
    $menu.Items.Insert(1, (New-Object System.Windows.Forms.ToolStripSeparator))

    $settingsItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Settings...'
    $settingsItem.add_Click({ Show-HotkeySettings })
    $menu.Items.Insert(1, $settingsItem)
    $script:notify.add_MouseDoubleClick({ Show-HotkeySettings })

    $script:hotkeyWindow = New-Object AutoCopyNative.HotkeyWindow
    $script:hotkeyActions = @{}      # id -> scriptblock
    $script:hotkeyWindow.add_Pressed({
        param($s, $e)
        $action = $script:hotkeyActions[$e.Id]
        if ($action) { & $action }
    })

    $failed = Register-AllHotkeys
    if ($failed.Count) {
        $script:notify.ShowBalloonTip(4000, 'Hotkey unavailable', "Couldn't register: $($failed -join ', '). Another app is using it - pick a different key in Settings (double-click the tray icon).", [System.Windows.Forms.ToolTipIcon]::Warning)
    }

    # keep overlay in sync with the real mic state (also catches muting from
    # Windows settings or other apps) and keep it above games/other windows
    $micTimer = New-Object System.Windows.Forms.Timer
    $micTimer.Interval = 300
    $micTimer.add_Tick({
        Update-MicUi
        if ($script:showSettingsEvent.WaitOne(0)) { Show-HotkeySettings }
    })
    $micTimer.Start()
    Update-MicUi
    if ($Settings) { Show-HotkeySettings }
}

if ($script:otpOk) {
    $menu.Items.Insert(1, $otpItem)
    $otpTimer = New-Object System.Windows.Forms.Timer
    $otpTimer.Interval = 1000
    $otpTimer.add_Tick({ Invoke-OtpCheck })
    $otpTimer.Start()
    Invoke-OtpCheck   # marks "now", so older messages are never copied

    # iPhone Shortcut endpoint
    if (-not $script:otp.Token -or $script:otp.Token.Length -lt 24) {
        $script:otp.Token = New-BridgeToken
        Save-Settings
    }
    if (Start-PhoneBridge) {
        $bridgeTimer = New-Object System.Windows.Forms.Timer
        $bridgeTimer.Interval = 200
        $bridgeTimer.add_Tick({ Invoke-BridgeCheck })
        $bridgeTimer.Start()
    }
}

# --- new-file handler --------------------------------------------------------
$onFile = {
    param($sender, $e)
    try {
        $p = $e.FullPath
        if (-not $p) { return }
        if ([IO.Directory]::Exists($p)) { return }
        $name = [IO.Path]::GetFileName($p)
        if ($name -match '^[~.]' -or $name -ieq 'desktop.ini' -or $name -ieq 'thumbs.db') { return }
        $ext = [IO.Path]::GetExtension($p).ToLowerInvariant()
        if ($script:ignoreExt -contains $ext) { return }
        if (-not $script:pending.ContainsKey($p)) {
            $script:pending[$p] = @{ Size = -1; Stable = 0; FirstSeen = [DateTime]::UtcNow }
        }
    } catch { }
}

$script:watchers = @()
foreach ($f in $watchFolders) {
    $w = New-Object System.IO.FileSystemWatcher $f
    $w.SynchronizingObject  = $form
    $w.IncludeSubdirectories = $false
    $w.add_Created($onFile)
    $w.add_Renamed($onFile)   # browsers rename .crdownload/.part to the final name
    $w.EnableRaisingEvents  = $true
    $script:watchers += $w
}

# --- poll pending files until fully written, then copy -----------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.add_Tick({
    if ($script:paused -or $script:pending.Count -eq 0) { return }
    $now = [DateTime]::UtcNow
    foreach ($p in @($script:pending.Keys)) {
        $info = $script:pending[$p]
        if (-not [IO.File]::Exists($p)) { $script:pending.Remove($p); continue }
        if (($now - $info.FirstSeen).TotalMinutes -gt 15) { $script:pending.Remove($p); continue }

        $size = -1
        try { $size = ([IO.FileInfo]$p).Length } catch { continue }
        if ($size -ne $info.Size) { $info.Size = $size; $info.Stable = 0; continue }
        $info.Stable++
        if ($info.Stable -lt 2) { continue }

        # still being written? (writer holds the file open)
        $free = $false
        try {
            $fs = [IO.File]::Open($p, 'Open', 'Read', 'None')
            $fs.Close()
            $free = $true
        } catch { }
        if (-not $free) { continue }

        $script:pending.Remove($p)
        Copy-FileToClipboard $p
    }
})
$timer.Start()

$script:notify.ShowBalloonTip(2000, 'Auto Copy is running', "Watching $($watchFolders.Count) folders. New downloads and captures will be copied to the clipboard automatically.", [System.Windows.Forms.ToolTipIcon]::Info)

[System.Windows.Forms.Application]::Run()

$script:mutex.ReleaseMutex()

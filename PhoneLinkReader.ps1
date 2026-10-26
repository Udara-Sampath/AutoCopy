# Phone Link reader for AutoCopy: reads the newest items in Phone Link's own
# notifications list (via UI Automation) and returns new one-time codes.
#
# Why: with an iPhone, Phone Link lists incoming texts in its window but often
# never raises a Windows notification for them, so the notification database
# never sees them. Reading works while Phone Link is minimized.
#
# Dot-sourced by AutoCopy.ps1 (after OtpWatcher.ps1). Nothing is stored.

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Name PlWin -Namespace AutoCopyNative -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
'@

$script:plSeen = $null            # keys of list items already looked at
$script:plWindow = $null          # cached AutomationElement of the Phone Link window
$script:plOpening = $null         # @{ Until; Foreground } while we open Phone Link ourselves
$script:plReadUntil = [DateTime]::MinValue
$script:plLastBadge = $null
$script:plNextBackup = [DateTime]::MinValue

function Get-PhoneLinkWindow {
    $A = [System.Windows.Automation.AutomationElement]
    if ($script:plWindow) {
        try { if ([AutoCopyNative.PlWin]::IsWindowVisible([IntPtr]$script:plWindow.Current.NativeWindowHandle)) { return $script:plWindow } } catch { }
        $script:plWindow = $null
    }
    $p = Get-Process PhoneExperienceHost -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($A::ProcessIdProperty, $p.Id)
    foreach ($w in $A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
        if ($w.Current.ClassName -eq 'WinUIDesktopWin32WindowClass') { $script:plWindow = $w; return $w }
    }
    $null
}

function Open-PhoneLinkMinimized {
    # Starts Phone Link and minimizes it as soon as its window appears,
    # giving focus back to whatever you were using.
    if ($script:plOpening -and $script:plOpening.Until -gt [DateTime]::UtcNow) { return }
    $script:plOpening = @{ Until = [DateTime]::UtcNow.AddSeconds(15); Foreground = [AutoCopyNative.PlWin]::GetForegroundWindow() }
    try { Start-Process 'shell:AppsFolder\Microsoft.YourPhone_8wekyb3d8bbwe!App' } catch { $script:plOpening = $null }
}

function Complete-PhoneLinkOpen($Window) {
    if (-not $script:plOpening) { return }
    try {
        [void][AutoCopyNative.PlWin]::ShowWindow([IntPtr]$Window.Current.NativeWindowHandle, 7)   # SW_SHOWMINNOACTIVE
        if ($script:plOpening.Foreground -ne [IntPtr]::Zero) { [void][AutoCopyNative.PlWin]::SetForegroundWindow($script:plOpening.Foreground) }
    } catch { }
    $script:plOpening = $null
}

function Get-PhoneLinkItems($Window, [int]$Max = 8) {
    # Newest items first: @{ Key; App; Text; Time }
    $A = [System.Windows.Automation.AutomationElement]
    $listCond = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $items = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $listCond)
    $out = @()
    $n = 0
    foreach ($it in $items) {
        if ($n -ge $Max) { break }
        $vals = @{}
        foreach ($k in $it.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
            $id = $k.Current.AutomationId
            if ($id -in 'AppNameTextBlock', 'HoverDateReceivedTextBlock', 'CompactModeTitleTextBlock', 'NotificationDescriptionText' -and -not $vals[$id]) { $vals[$id] = $k.Current.Name }
        }
        if (-not $vals['NotificationDescriptionText'] -and -not $vals['CompactModeTitleTextBlock']) { continue }
        $n++
        $time = ($vals['HoverDateReceivedTextBlock'] -replace '[‎‏]', '')
        $text = "$($vals['CompactModeTitleTextBlock'])`n$($vals['NotificationDescriptionText'])"
        $out += @{ Key = "$($vals['AppNameTextBlock'])|$time|$text"; App = $vals['AppNameTextBlock']; Text = $text; Time = $time }
    }
    $out
}

function Test-RecentTime([string]$Time) {
    # '1:27 AM' (today) within the last 3 minutes?
    $t = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($Time, [ref]$t)) { return $false }
    if ($Time -notmatch ':') { return $false }   # a date, so not today
    $age = ([DateTime]::Now - $t).TotalMinutes
    $age -ge -1 -and $age -le 3
}

function Get-PhoneLinkBadgeStamp {
    # Phone Link updates its unread-count badge whenever a text arrives
    try {
        $r = [AutoCopyNative.Sqlite]::Query($script:wpnPath,
            "select max(n.ArrivalTime) from Notification n join NotificationHandler h on h.RecordId = n.HandlerId where n.Type = 'badge' and h.PrimaryId like 'Microsoft.YourPhone%!App'")
        if ($r.Count -and $null -ne $r[0][0]) { return [long]$r[0][0] }
    } catch { }
    $null
}

function Get-NewPhoneLinkCodes {
    # Call about once a second. Returns @{ Code; Source } for new codes.
    $now = [DateTime]::UtcNow

    # read the list for a while after the badge changes, plus a slow backup check
    $badge = Get-PhoneLinkBadgeStamp
    $badgeChanged = ($null -ne $script:plLastBadge -and $badge -ne $script:plLastBadge)
    $script:plLastBadge = $badge
    if ($badgeChanged) { $script:plReadUntil = $now.AddSeconds(15) }
    $backup = $now -ge $script:plNextBackup
    if ($backup) { $script:plNextBackup = $now.AddSeconds(20) }
    if (-not ($badgeChanged -or $backup -or $now -lt $script:plReadUntil -or $script:plOpening)) { return @() }

    $w = Get-PhoneLinkWindow
    if (-not $w) {
        if ($badgeChanged -or $null -eq $script:plSeen) { Open-PhoneLinkMinimized }
        return @()
    }
    $justOpened = [bool]$script:plOpening
    Complete-PhoneLinkOpen $w

    $items = @(Get-PhoneLinkItems $w)
    $found = @()
    if ($null -eq $script:plSeen) {
        # first look: remember what's there; only codes from the last few minutes count
        $script:plSeen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($i in $items) {
            [void]$script:plSeen.Add($i.Key)
            if ($justOpened -and (Test-RecentTime $i.Time)) {
                $code = Get-OtpFromText $i.Text
                if ($code -and (Test-NewOtp $code)) { $found += @{ Code = $code; Source = "$($i.App) (Phone Link)" } }
            }
        }
        return $found
    }
    foreach ($i in $items) {
        if (-not $script:plSeen.Add($i.Key)) { continue }
        $code = Get-OtpFromText $i.Text
        if ($code -and (Test-NewOtp $code)) { $found += @{ Code = $code; Source = "$($i.App) (Phone Link)" } }
    }
    if ($script:plSeen.Count -gt 500) { $script:plSeen.Clear(); foreach ($i in $items) { [void]$script:plSeen.Add($i.Key) } }
    $found
}

# OTP watcher for AutoCopy: spots one-time codes in new Windows notifications
# (e.g. text messages mirrored by Phone Link) so the app can copy them.
# Dot-sourced by AutoCopy.ps1. Needs SqliteLite.cs to be loaded first.
#
# Reads %LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db read-only.
# Nothing is stored or sent anywhere.

$script:wpnPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Notifications\wpndatabase.db'
$script:otpLastOrder = $null
$script:otpRecent = @{}   # code -> time copied, to avoid copying the same code twice

# words that mark a message as a verification / login code
$script:otpKeywords = '(?i)\b(code|otp|one[\s-]?time|verification|verify|passcode|pass\s?code|pin|2fa|two[\s-]?factor|' +
                      'authenticat\w*|security|login|log[\s-]?in|sign[\s-]?in|confirm\w*|token|password|kod|codigo|código|' +
                      'mã|รหัส|कोड|코드|認証|验证码|驗證碼)'

function Get-OtpFromText([string]$Text) {
    # Returns the most likely one-time code in $Text, or $null.
    if (-not $Text) { return $null }
    $kw = [regex]::Matches($Text, $script:otpKeywords)
    if ($kw.Count -eq 0) { return $null }

    # 4-8 digits, optionally written as 123-456 / 123 456; not part of a longer number,
    # an amount, a time, a date or a phone number
    $cands = [regex]::Matches($Text, '(?<![\d.,:/$€£₹+])(\d{3}[ -]\d{3}|\d{4,8})(?![\d:/%]|[.,]\d)')
    $best = $null; $bestDist = [int]::MaxValue
    foreach ($c in $cands) {
        $before = $Text.Substring([Math]::Max(0, $c.Index - 4), [Math]::Min(4, $c.Index))
        if ($before -match '(?i)(rs\.?|usd|inr|lkr|eur|\$)\s*$') { continue }   # money
        $code = $c.Value -replace '[ -]', ''
        foreach ($k in $kw) {
            $d = if ($c.Index -ge $k.Index) { $c.Index - ($k.Index + $k.Length) } else { $k.Index - ($c.Index + $c.Length) }
            if ($d -lt 0) { $d = 0 }
            if ($d -lt $bestDist) { $bestDist = $d; $best = $code }
        }
    }
    $best
}

function Get-NotificationText([byte[]]$Payload) {
    # Toast XML -> all <text> lines joined with newlines
    try {
        $x = New-Object System.Xml.XmlDocument
        $x.LoadXml([Text.Encoding]::UTF8.GetString($Payload))
        ($x.SelectNodes('//text') | ForEach-Object { $_.InnerText }) -join "`n"
    } catch { $null }
}

function Test-NewOtp([string]$Code) {
    # $false if this code was already copied in the last 2 minutes (the same
    # text can arrive twice: notification updates, Phone Link + iPhone Shortcut)
    $now = [DateTime]::UtcNow
    foreach ($k in @($script:otpRecent.Keys)) { if (($now - $script:otpRecent[$k]).TotalMinutes -gt 2) { $script:otpRecent.Remove($k) } }
    if ($script:otpRecent.ContainsKey($Code)) { return $false }
    $script:otpRecent[$Code] = $now
    $true
}

function Get-FriendlySource([string]$PrimaryId) {
    # 'Microsoft.YourPhone_...!YourPhoneNotifications_com.apple.MobileSMS' -> 'Messages'
    $app = ($PrimaryId -split '!')[-1] -replace '^YourPhoneNotifications_', ''
    switch -regex ($app) {
        '^App$'                     { return 'Phone Link' }
        'MobileSMS|android\.apps\.messaging|\.mms$|messaging' { return 'Messages' }
        'whatsapp'                  { return 'WhatsApp' }
        'mail|outlook'              { return 'Mail' }
    }
    if ($app -match '\\') { $app = [IO.Path]::GetFileNameWithoutExtension($app) }
    elseif ($app -match '^[\w-]+(\.[\w-]+)+$') { $app = ($app -split '\.')[-1] }
    $app
}

function Get-NewOtpNotifications([bool]$AllApps) {
    # Returns @{ Code; Source } for every new toast with a code since the last call.
    # The first call only records where "now" is, so old messages are never copied.
    if (-not [IO.File]::Exists($script:wpnPath)) { return @() }
    if ($null -eq $script:otpLastOrder) {
        $r = [AutoCopyNative.Sqlite]::Query($script:wpnPath, 'select max([Order]) from Notification')
        $script:otpLastOrder = if ($r.Count -and $r[0][0] -ne $null) { [long]$r[0][0] } else { 0 }
        return @()
    }
    # (AutoCopy's own pop-ups come from powershell.exe - never read those back)
    $filter = if ($AllApps) { "and h.PrimaryId not like '%powershell%'" } else { "and h.PrimaryId like 'Microsoft.YourPhone%'" }
    $rows = [AutoCopyNative.Sqlite]::Query($script:wpnPath,
        "select n.[Order], h.PrimaryId, n.Payload from Notification n join NotificationHandler h on h.RecordId = n.HandlerId " +
        "where n.[Order] > $($script:otpLastOrder) and n.Type = 'toast' $filter order by n.[Order]")
    $found = @()
    foreach ($row in $rows) {
        if ([long]$row[0] -gt $script:otpLastOrder) { $script:otpLastOrder = [long]$row[0] }
        if (-not ($row[2] -is [byte[]])) { continue }
        $text = Get-NotificationText $row[2]
        $code = Get-OtpFromText $text
        if (-not $code) { continue }
        if (-not (Test-NewOtp $code)) { continue }
        $found +=@{ Code = $code; Source = (Get-FriendlySource $row[1]) }
    }
    $found
}

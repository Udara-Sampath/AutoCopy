# Phone bridge for AutoCopy: a tiny web endpoint on the home network that an
# iPhone Shortcuts automation sends incoming text messages to. AutoCopy pulls
# the one-time code out of the message and copies it.
# Dot-sourced by AutoCopy.ps1 (after OtpWatcher.ps1).
#
#   GET  /otp/<token>         -> "AutoCopy is reachable" (test it in Safari)
#   POST /otp/<token>  body   -> copies the code found in the body
#        body can be JSON {"text": "..."}, a form (text=...) or plain text.
#
# Security:
#  - the address contains a long random secret (<token>); wrong guesses from a
#    device lock it out for 10 minutes
#  - only devices on the local network are answered (private IP ranges);
#    the Windows Firewall rule (Enable-iPhoneCodes.ps1) also limits it to the
#    local subnet on Private networks
#  - only a 4-8 digit code ever goes on the clipboard; messages are never
#    stored or logged
#  - it's plain HTTP inside your home network (like most smart-home gear), so
#    don't use it on networks you don't trust

$script:bridgePort = 47321
$script:bridgeListener = $null
$script:bridgeFails = @{}     # ip -> @{ Count; Until }

function New-BridgeToken {
    # 24 random characters from a crypto RNG (~124 bits)
    $alphabet = 'abcdefghijkmnpqrstuvwxyz23456789'
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes); $rng.Dispose()
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function Test-LocalAddress([System.Net.IPAddress]$Ip) {
    if ($Ip.IsIPv4MappedToIPv6) { $Ip = $Ip.MapToIPv4() }
    if ([System.Net.IPAddress]::IsLoopback($Ip)) { return $true }
    $b = $Ip.GetAddressBytes()
    if ($b.Length -eq 4) {
        return ($b[0] -eq 10) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
               ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254)
    }
    return $Ip.IsIPv6LinkLocal -or (($b[0] -band 0xFE) -eq 0xFC)
}

function Test-TokenMatch([string]$A, [string]$B) {
    # constant-time compare
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ([int]$A[$i] -bxor [int]$B[$i]) }
    $diff -eq 0
}

function Start-PhoneBridge {
    Stop-PhoneBridge
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $script:bridgePort)
        $l.Start()
        $script:bridgeListener = $l
        $true
    } catch {
        Add-Content -Path (Join-Path $env:TEMP 'AutoCopy.log') -Value "$(Get-Date -Format o) phone bridge failed to start: $_"
        $false
    }
}

function Stop-PhoneBridge {
    if ($script:bridgeListener) { try { $script:bridgeListener.Stop() } catch { } }
    $script:bridgeListener = $null
}

function Get-BridgeUrls([string]$Token) {
    # Address(es) the phone can use: the PC's home-network IP(s).
    # (name.local isn't used: Windows doesn't reliably answer it)
    $urls = @()
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.PrefixOrigin -in 'Dhcp', 'Manual' -and $_.IPAddress -match '^(192\.168|10\.|172\.(1[6-9]|2\d|3[01])\.)' -and $_.InterfaceAlias -notmatch 'vEthernet|VMware|VirtualBox|Hyper-V|Loopback|Tailscale|ZeroTier' } |
           Sort-Object { $_.InterfaceAlias -notmatch 'Wi-?Fi|Ethernet' } | Select-Object -ExpandProperty IPAddress
    foreach ($ip in $ips) { $urls += "http://$($ip):$($script:bridgePort)/otp/$Token" }
    $urls
}

function Get-BridgeMessageText([string]$Body, [string]$ContentType, [string]$Query) {
    $text = $null
    if ($Body) {
        if ($ContentType -match 'json' -or $Body.TrimStart().StartsWith('{')) {
            try {
                $j = $Body | ConvertFrom-Json
                $text = $j.text
                if (-not $text) { $text = ($j.PSObject.Properties | Where-Object { $_.Value -is [string] } | ForEach-Object { $_.Value }) -join "`n" }
            } catch { }
        }
        if (-not $text -and $ContentType -match 'x-www-form-urlencoded') {
            foreach ($pair in $Body -split '&') {
                $kv = $pair -split '=', 2
                if ($kv[0] -eq 'text' -and $kv.Count -eq 2) { $text = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
            }
        }
        if (-not $text) { $text = $Body }
    }
    if (-not $text -and $Query -match '(?:^|&)text=([^&]*)') { $text = [Uri]::UnescapeDataString($Matches[1].Replace('+', ' ')) }
    $text
}

function Send-BridgeResponse($Stream, [int]$Status, [string]$Text) {
    $reason = @{ 200 = 'OK'; 400 = 'Bad Request'; 403 = 'Forbidden'; 404 = 'Not Found' }[$Status]
    $body = [Text.Encoding]::UTF8.GetBytes($Text)
    $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status $reason`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
    $Stream.Write($head, 0, $head.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Receive-BridgeRequest($Client, [string]$Token) {
    # Handles one connection. Returns the code to copy, or $null.
    $remote = $Client.Client.RemoteEndPoint.Address
    if (-not (Test-LocalAddress $remote)) { return $null }          # not from the home network: drop silently
    $ipKey = $remote.ToString()
    $f = $script:bridgeFails[$ipKey]
    if ($f -and $f.Until -gt [DateTime]::UtcNow) { return $null }   # locked out after wrong guesses

    $Client.ReceiveTimeout = 1500; $Client.SendTimeout = 1500
    $s = $Client.GetStream()
    $buf = New-Object byte[] 65536
    $ms = New-Object IO.MemoryStream
    $headerEnd = -1
    while ($headerEnd -lt 0 -and $ms.Length -lt 65536) {
        $n = $s.Read($buf, 0, $buf.Length); if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $headerEnd = ([Text.Encoding]::ASCII.GetString($ms.ToArray())).IndexOf("`r`n`r`n")
    }
    if ($headerEnd -lt 0) { Send-BridgeResponse $s 400 'Bad request'; return $null }
    $all = $ms.ToArray()
    $head = [Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $lines = $head -split "`r`n"
    $method, $target = ($lines[0] -split ' ')[0, 1]
    $headers = @{}
    foreach ($ln in ($lines | Select-Object -Skip 1)) { $i = $ln.IndexOf(':'); if ($i -gt 0) { $headers[$ln.Substring(0, $i).Trim().ToLower()] = $ln.Substring($i + 1).Trim() } }

    $path, $query = $target -split '\?', 2
    $given = if ($path -like '/otp/*') { $path.Substring(5) } else { '' }
    if (-not $Token -or -not (Test-TokenMatch $given $Token)) {
        $lockExpired = $f -and ($f.Count -ge 5) -and ($f.Until -le [DateTime]::UtcNow)
        if (-not $f -or $lockExpired) { $f = @{ Count = 0; Until = [DateTime]::MinValue } }
        $f.Count++
        if ($f.Count -ge 5) { $f.Until = [DateTime]::UtcNow.AddMinutes(10) }
        $script:bridgeFails[$ipKey] = $f
        Send-BridgeResponse $s 403 'Wrong address'
        return $null
    }
    $script:bridgeFails.Remove($ipKey)

    $len = 0; [void][int]::TryParse($headers['content-length'], [ref]$len); $len = [Math]::Min($len, 65536)
    $bodyBytes = New-Object IO.MemoryStream
    $bodyBytes.Write($all, $headerEnd + 4, $all.Length - $headerEnd - 4)
    while ($bodyBytes.Length -lt $len) { $n = $s.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $bodyBytes.Write($buf, 0, $n) }
    $body = [Text.Encoding]::UTF8.GetString($bodyBytes.ToArray())

    $text = Get-BridgeMessageText $body $headers['content-type'] $query
    if (-not $text) { Send-BridgeResponse $s 200 'AutoCopy is reachable. Codes sent here will be copied on the PC.'; return $null }

    $code = Get-OtpFromText $text
    if (-not $code -and $text.Trim() -match '^\d{4,8}$') { $code = $text.Trim() }   # shortcut sent just the code
    if ($code) { Send-BridgeResponse $s 200 "Copied $code" } else { Send-BridgeResponse $s 200 'No code found in that message' }
    $code
}

function Get-PhoneBridgeCodes([string]$Token) {
    # Handles every waiting connection; returns the codes received.
    $codes = @()
    if (-not $script:bridgeListener) { return $codes }
    $max = 5   # at most a few connections per tick, so the app never stalls
    while ($max-- -gt 0 -and $script:bridgeListener.Pending()) {
        $c = $script:bridgeListener.AcceptTcpClient()
        try { $code = Receive-BridgeRequest $c $Token; if ($code) { $codes += $code } } catch { } finally { $c.Close() }
    }
    $codes
}

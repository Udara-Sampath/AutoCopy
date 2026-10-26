# AutoCopy: guide for AI assistants and developers

Read `README.md` first for what the app does from a user's point of view.
This file covers how it's built, how to work on it safely, and the traps
already found.

## What it is

A Windows-only system-tray app written in **Windows PowerShell 5.1** with
WinForms. It is not PowerShell 7. There is no build step: two C# files are
compiled at startup with `Add-Type`. There are no external dependencies, no
admin rights and no installer beyond a Startup-folder shortcut.

Features: auto-copy new files from Downloads/Screenshots/recordings folders;
copy one-time codes from phone texts (via Phone Link); mic-mute hotkey with
an on-screen overlay; a settings window; an optional LAN receiver for iPhone
Shortcuts.

## Architecture

```
Start-AutoCopy.vbs ──► powershell.exe -WindowStyle Hidden -File AutoCopy.ps1
                         │
AutoCopy.ps1  (one UI thread, WinForms message loop: Application.Run())
  ├─ single-instance mutex  "AutoCopyClipboardWatcher"
  ├─ named event "AutoCopyShowSettings"  (AutoCopy.ps1 -Settings → tells running copy to open Settings)
  ├─ Add-Type QuickActions.cs  → [AutoCopyNative.Mic], HotkeyWindow, OverlayForm
  ├─ Add-Type SqliteLite.cs    → [AutoCopyNative.Sqlite]::Query(path, sql)
  ├─ dot-source OtpWatcher.ps1, PhoneBridge.ps1, PhoneLinkReader.ps1
  ├─ FileSystemWatchers (SynchronizingObject = hidden form) → $script:pending
  └─ timers (all System.Windows.Forms.Timer, so everything runs on the UI thread):
       500 ms  file timer   – copies a pending file once its size is stable for 2 ticks and it opens with FileShare.None
       300 ms  mic timer    – syncs overlay with real mic state; polls the show-settings event
      1000 ms  OTP timer    – Invoke-OtpCheck → notification DB + Phone Link window
       200 ms  bridge timer – Invoke-BridgeCheck → accepts pending TCP connections (non-blocking)
```

Each optional part is loaded in its own `try`. If one fails (e.g. the C#
doesn't compile), the error goes to `%TEMP%\AutoCopy.log` and the rest of
the app still runs (`$script:quickOk`, `$script:otpOk`,
`$script:phoneLinkOk`).

### Files

| File | Key contents |
|---|---|
| `AutoCopy.ps1` | `$Hotkeys` defaults, `$script:quickActions` (list of hotkey-able actions), `Copy-FileToClipboard`, `Copy-Otp`, `Invoke-OtpCheck`, `Invoke-BridgeCheck`, `ConvertTo-Hotkey` / `Format-Hotkey`, `Register-AllHotkeys`, `Save-Settings`, `Show-HotkeySettings` |
| `QuickActions.cs` | `Mic.GetState()` (-1 none / 0 live / 1 muted), `Mic.SetMuted(bool)` via Core Audio COM; `HotkeyWindow` (RegisterHotKey, `Pressed` event); `OverlayForm` (click-through, topmost, no-activate) |
| `SqliteLite.cs` | `Sqlite.Query(path, sql)`: read-only, P/Invoke to `winsqlite3.dll` (ships with Windows) |
| `OtpWatcher.ps1` | `Get-OtpFromText`, `Get-NewOtpNotifications($AllApps)`, `Test-NewOtp` (2-min dedupe), `Get-FriendlySource` |
| `PhoneLinkReader.ps1` | `Get-NewPhoneLinkCodes` and helpers (UI Automation on Phone Link) |
| `PhoneBridge.ps1` | `Start-/Stop-PhoneBridge`, `Get-PhoneBridgeCodes`, `New-BridgeToken`, `Get-BridgeUrls` |
| `Enable-iPhoneCodes.ps1` | self-elevating; firewall rule "AutoCopy - iPhone codes" |
| `Install.ps1` / `Uninstall.ps1` | Startup-folder shortcut `AutoCopy.lnk` → `wscript.exe Start-AutoCopy.vbs` |

### Settings

`%APPDATA%\AutoCopy\settings.json`:

```json
{ "Hotkeys": { "ToggleMicMute": "Ctrl+Alt+F12" },
  "Otp": { "Enabled": true, "AllApps": false, "Token": "<24 random chars>" } }
```

Saved values override the defaults at the top of `AutoCopy.ps1`. `Token` is
a secret (it is the iPhone receiver's password). Never print it, commit it,
or paste it into chats.

### How OTP detection works

- **`Get-OtpFromText`**: a keyword regex (`$script:otpKeywords`, multilingual)
  must match. Candidates are `\d{4,8}` or `\d{3}[ -]\d{3}`, not touching other
  digits, `.,:/$€£₹+`, `%`, or decimals; a currency word just before the number
  rejects it. The candidate closest to any keyword wins.
- **Notification DB**: `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db`.
  Query `Notification` joined to `NotificationHandler`, `Type='toast'`,
  `[Order] > last seen`. Filter `PrimaryId LIKE 'Microsoft.YourPhone%'`, or
  with AllApps everything except `%powershell%` (so it never reads its own
  balloons). The `Payload` column is toast XML; the text comes from the
  `//text` nodes. The first call only records the current max `[Order]`.
- **Phone Link window** (needed for iPhone): Phone Link often shows iPhone
  texts only in its own window and raises no toast; only its **badge**
  (`Type='badge'`, handler `Microsoft.YourPhone…!App`) changes. So:
  - Watch the badge's `max(ArrivalTime)`. When it changes, read the window
    for 15 s; plus a backup read every 20 s.
  - Find the window: process `PhoneExperienceHost`, top-level class
    `WinUIDesktopWin32WindowClass`. UI Automation works while it's minimized.
  - Each `ListItem` holds TextBlocks with AutomationIds `AppNameTextBlock`,
    `HoverDateReceivedTextBlock`, `CompactModeTitleTextBlock` and
    `NotificationDescriptionText`. The key `app|time|text` dedupes items.
  - On the first read, everything visible is marked as seen.
  - If the window is closed, launch
    `shell:AppsFolder\Microsoft.YourPhone_8wekyb3d8bbwe!App`, then
    `ShowWindow(SW_SHOWMINNOACTIVE)` and restore the previous foreground
    window.
- **Things that were tried and don't work for iPhone**: Windows toasts
  (none are raised, even with Phone Link notifications unmuted) and the
  Start-menu companion JSON (it only holds counts).

## Working on it

### Encoding and line endings (important)

- PowerShell 5.1 reads BOM-less files as ANSI. **Any file containing
  non-ASCII characters (—, €, ₹, ‎ etc.) must be saved as UTF-8 *with BOM***,
  or the script misparses (broken regexes, "missing terminator" errors).
  Every `.ps1` and `.cs` file except `Install.ps1` and `Uninstall.ps1`
  (pure ASCII) has a BOM. Keep it.
- Files use CRLF. `.gitattributes` has `* -text`, so Git stores them
  byte-for-byte.
- Some editing tools save without the BOM. After editing, check the first
  three bytes are `EF BB BF`.
- C# must compile as **C# 5** (the .NET Framework compiler `Add-Type`
  uses). That means no `$"..."` interpolation, `?.`, `nameof`,
  expression-bodied members or `out var`.

### Running and restarting

```powershell
# stop the running copy (don't kill your own shell)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*-File*AutoCopy.ps1*' -and $_.ProcessId -ne $PID } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
# start it (hidden, like at sign-in)
Start-Process wscript.exe '"<repo folder>\Start-AutoCopy.vbs"'
# check
Get-Content "$env:TEMP\AutoCopy.log" -Tail 5
```

Add-Type types can't be reloaded in the same PowerShell process. Test C#
changes in a **new** `powershell.exe` process, not in your current session.

### Testing rules (learned the hard way)

- **Don't pop UI on the user's live desktop to "test" it.** The settings
  window once opened mid-typing; the user's keystrokes got captured and
  saved as a hotkey. Test logic headlessly (dot-source the `.ps1`, call the
  functions), or ask the user first.
- **Don't change the user's saved hotkey or settings** while testing. Back
  up `settings.json` and restore it afterwards.
- **Privacy:** when debugging OTP/Phone Link, never print message text.
  Mask digits and letters in any diagnostic output.
- Test `Get-OtpFromText` with made-up messages. Cases worth keeping: codes
  with keywords, `123-456` style, amounts (`Rs. 5000`, `$1234`), times
  (`12:45`), dates, phone numbers, order numbers, and messages with no
  keyword (must return `$null`).
- Don't change Windows Firewall rules yourself. `Enable-iPhoneCodes.ps1` is
  meant for the user to run.

### Adding a new hotkey action

1. Add a default to `$Hotkeys` (e.g. `MyAction = ''`).
2. Create a tray menu item and append to `$script:quickActions`:
   `@{ Name = 'MyAction'; Label = 'Do my thing'; Action = { ... }; Item = $myItem }`.
3. The settings window and registration pick it up automatically.

## Security notes

- No outbound network traffic.
- The only listener is `PhoneBridge.ps1` (TCP 47321, all interfaces). It
  answers only private/link-local source IPs, needs the secret token in the
  path (compared in constant time), and locks out an IP for 10 minutes
  after 5 wrong tries. Request size is capped at 64 KB, at most 5
  connections are handled per tick, and nothing is stored. The token comes
  from `RandomNumberGenerator`. If the user doesn't need the iPhone
  Shortcuts route, the bridge can be removed: delete `PhoneBridge.ps1`,
  `Enable-iPhoneCodes.ps1`, the bridge timer/token code and the
  settings-window URL section in `AutoCopy.ps1`.
- If Windows ever showed a firewall pop-up for PowerShell and someone
  clicked Allow, broad inbound "Windows PowerShell" rules may exist (any
  port, public networks too). Recommend removing them (needs admin).
- Reading `wpndatabase.db` and Phone Link's UI exposes notification text to
  this process. Keep it in memory only and never log it.

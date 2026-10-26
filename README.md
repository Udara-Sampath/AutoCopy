# Auto Copy

A tiny Windows tray app that automatically copies every new **download**,
**screenshot**, and **screen recording** to the clipboard — so you can
immediately paste it anywhere (WhatsApp, email, Slack, a folder, an upload
form) with **Ctrl+V**, without hunting for the file first.

No installation of any software is required — it's a plain PowerShell script
using only what's built into Windows 10/11.

> **Setting this up with Claude / an AI assistant?** Just ask it to:
> *"Extract this zip to a permanent folder and run Install.ps1, then verify
> the app is running."* Everything it needs to know is in this file.

## What it does

It watches these folders (created automatically if missing, OneDrive-redirected
locations are handled):

| Folder | What lands there |
|---|---|
| `Downloads` | anything you download in a browser |
| `Pictures\Screenshots` | Snipping Tool screenshots, Win+PrtScn captures |
| `Videos\Screen Recordings` | Snipping Tool video recordings |
| `Videos\Captures` | Xbox Game Bar recordings |

The moment a new file appears, the app:

1. Waits until the file is **fully written** — it checks that the size has
   stopped growing and that the browser/app has released the file, so it never
   grabs a half-finished download. In-progress files (`.crdownload`, `.part`,
   `.tmp`, …) are ignored until they get their final name.
2. Puts the **file itself on the clipboard** — exactly like right-clicking it
   in Explorer and choosing Copy. For images it *also* puts the picture data
   on the clipboard, so pasting works both as a file attachment (chat apps,
   Explorer) and as an image (Paint, Word, Photoshop).
3. Shows a small notification: *"Copied to clipboard: filename"*.

Then you just press **Ctrl+V** wherever you need it.

## Files

| File | Purpose |
|---|---|
| `AutoCopy.ps1` | the app itself (PowerShell, no dependencies) |
| `PhoneBridge.ps1` | receives codes from an iPhone Shortcut over the home network |
| `Enable-iPhoneCodes.ps1` | one-time admin step: narrow firewall rule for the iPhone Shortcut |
| `PhoneLinkReader.ps1` | reads new codes straight from the Phone Link window (needed for iPhone texts) |
| `OtpWatcher.ps1` | spots one-time codes in new notifications |
| `SqliteLite.cs` | read-only access to the Windows notification list (uses Windows' built-in SQLite) |
| `QuickActions.cs` | hotkeys, mic mute and the overlay (compiled by the app at start-up) |
| `Start-AutoCopy.vbs` | starts the app with no visible console window |
| `Install.ps1` | adds the app to Windows startup and starts it now |
| `Uninstall.ps1` | stops the app and removes it from startup |

## Install

1. **Extract this folder to a permanent location**, e.g. `C:\Tools\AutoCopy`.
   Important: the startup entry points at wherever the files live, so don't
   run it from a temp/downloads location and then delete it.
2. Right-click `Install.ps1` → **Run with PowerShell**
   (or in a PowerShell window: `& "C:\Tools\AutoCopy\Install.ps1"`).
3. Done. A tray icon appears near the clock, and the app now starts
   automatically every time you sign in to Windows.

To try it out: download any file or take a screenshot with the Snipping Tool —
you'll get a "Copied to clipboard" notification, then Ctrl+V it somewhere.

## Daily use

- **Right-click the tray icon** →
  - **Pause** — temporarily stop auto-copying (handy while batch-downloading,
    so your clipboard isn't replaced) — click again to resume
  - **Exit** — quit until next sign-in (or until you run `Start-AutoCopy.vbs`)
- Hover the tray icon to see the last file copied.

## Quick-action hotkeys

Global keyboard shortcuts that work anywhere — including in games.

| Hotkey | Action |
|---|---|
| **Ctrl+Alt+F12** | Mute / unmute the microphone |

While the mic is muted, a red **MIC MUTED** box sits just above the taskbar on
the primary monitor. It stays on top of other windows and games, can't be
clicked, and never steals focus. It also shows up if you mute the mic some
other way (Windows settings, another app), because it follows the mic's real
state. You can also toggle it from the tray menu.

- Mute applies to **every** active microphone. Unmute restores only the mics
  that were live before (plus the default mic), so a mic you had muted on
  purpose stays muted.
- **To change the key**, double-click the tray icon (or right-click it →
  **Settings...**). Click the box, press the combination you want, then
  **Save** (or Enter). It takes effect immediately and is saved permanently in
  `%APPDATA%\AutoCopy\settings.json`, so it survives restarts and updates
  of the app folder. If another program already uses that combination, the
  window tells you so. Plain keys without Ctrl/Alt/Shift are only allowed
  for F1–F24, Pause and Scroll Lock, so a normal key isn't taken away from
  every other app. `AutoCopy.ps1 -Settings` also opens the window.
- The overlay shows over windowed and borderless-fullscreen games (the
  default for most modern games on Windows 11). Games running in old-style
  *exclusive* fullscreen draw over everything, so switch those to
  borderless/windowed to see it. The hotkey itself works either way.

## One-time codes (OTP) from your phone

When a text message with a verification code reaches your phone, AutoCopy
copies **just the code** to the clipboard and shows "Code copied: 123456".
Paste it with **Ctrl+V**, with no need to pick up your phone.

How it works: **Phone Link** mirrors your phone's notifications to Windows.
AutoCopy checks new notifications once a second and copies a 4–8 digit number
when the message also contains words like *code, OTP, verification, PIN,
login, security*. It ignores times, dates, amounts, phone numbers and order
numbers. Only messages that arrive **while AutoCopy is running** are checked,
and nothing is stored or sent anywhere.

- Turn it on/off: tray menu → **Copy codes from phone messages**, or in
  **Settings...**
- **Settings... → "Also check notifications from PC apps"** catches codes
  from email, WhatsApp Desktop etc. too (off by default).
- Requirements: Phone Link connected to your phone, with its notifications
  allowed in Windows (Settings → System → Notifications → Phone Link). On an
  iPhone, also allow "Share system notifications" for the PC in Bluetooth
  settings. If a code doesn't get copied, first check that the message pops up
  as a Phone Link notification.
- **Pause** also pauses code copying.
### iPhone texts and Phone Link

With an iPhone, Phone Link usually lists incoming texts in its own window
but never raises a Windows notification for them. So AutoCopy also reads the
newest items in **Phone Link's notification list** whenever Phone Link's
unread count changes (and every 20 seconds as a backup). This works while
Phone Link is **minimized**. If its window is closed, AutoCopy reopens it
minimized and gives focus back to what you were using. Only the code is
copied; nothing is stored.
### iPhone: codes via a Shortcuts automation (recommended for iPhone)

Phone Link often doesn't pass iPhone texts to Windows, so the reliable route
is a Shortcuts automation that sends incoming code texts straight to AutoCopy
over your home network.

1. **PC, once:** right-click `Enable-iPhoneCodes.ps1` → Run with PowerShell
   (asks for admin). It adds one narrow firewall rule: port 47321, local
   network only, home (Private) networks only. It also offers to remove broad
   "Windows PowerShell" allow rules left by firewall pop-ups.
2. **PC:** double-click the tray icon → **Settings...** → copy the
   *iPhone Shortcut address*. Get it onto the phone (e.g. message/email it to
   yourself). Test it: open it in Safari on the iPhone and you should see
   "AutoCopy is reachable".
3. **iPhone:** Shortcuts → Automation → **+** → **Message** →
   *Message Contains*: `code` → **Run Immediately** → Next → New Blank
   Automation → add **Get Contents of URL** → paste the address → expand
   (▸): Method **POST**, Request Body **JSON**, add a **Text** field with
   key `text` and value **Shortcut Input** → Done.
   Make a second one with `OTP` if your bank's texts don't say "code".
   Allow "find devices on your local network" if asked.

Security: the address contains a 24-character random secret; wrong guesses
lock a device out for 10 minutes; only devices on your local network are
answered; only the 4–8 digit code is ever copied, and messages are never
stored or logged. It's plain HTTP, so only use it on your own network.
Settings → "Make a new secret address" if it ever leaks.
## Uninstall

Right-click `Uninstall.ps1` → **Run with PowerShell**. This stops the app and
removes the startup entry. Then simply delete the folder.

## Troubleshooting

- **Screenshots aren't being copied** — in Snipping Tool's settings, make sure
  **"Automatically save original screenshots"** is ON (it's the default on
  Windows 11). Without it, no file is ever saved, so there's nothing to copy.
- **"Running scripts is disabled" error** — the launcher already bypasses the
  execution policy for this script only; use `Install.ps1` / the `.vbs` rather
  than running `AutoCopy.ps1` directly.
- **Is it running?** — look for the tray icon (check the hidden-icons flyout
  `^` near the clock). Each launch also appends one line to
  `%TEMP%\AutoCopy.log` saying whether it started (`acquired=True`) or found
  another copy already running and quit (`acquired=False`).
- Only one instance runs at a time — launching it twice is harmless.

## How it's built (for the curious / for AI assistants)

`AutoCopy.ps1` is a single-file WinForms tray app: `FileSystemWatcher`s on the
four folders (events marshalled to the UI thread via a hidden form), a 500 ms
timer that waits for each new file to become stable and unlocked, then
`Clipboard.SetDataObject` with a `FileDropList` (plus a bitmap for images).
A named mutex (`AutoCopyClipboardWatcher`) enforces a single instance.
`Install.ps1` just creates a shortcut to `Start-AutoCopy.vbs` in the user's
Startup folder. Nothing touches the registry (beyond reading the Downloads
folder location), no admin rights needed, no network access.

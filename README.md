# AutoCopy

A small Windows tray app that saves you clicks:

- **New downloads, screenshots and screen recordings are copied to the
  clipboard automatically.** Download a file or take a screenshot, then just
  press **Ctrl+V** in WhatsApp, email, Discord, a folder, an upload form, ...
- **Verification codes (OTP) from your phone's text messages are copied
  automatically.** A bank or login code arrives on your phone, and a moment
  later it's on your PC's clipboard, ready to paste. Works with Android and
  iPhone through Microsoft **Phone Link**.
- **Microphone mute hotkey.** One key mutes every microphone, from anywhere,
  even inside games. A red **MIC MUTED** box stays on screen while muted.

It's plain PowerShell plus two small C# helpers that Windows compiles itself.
Nothing to install, no admin rights, no internet connection, no accounts.
Runs on Windows 10 and 11 (built and tested on Windows 11).

> **Using Claude or another AI assistant?** Point it at this folder and ask:
> *"Read CLAUDE.md and README.md, then install AutoCopy and check it's
> running."* `CLAUDE.md` explains how the code works and the gotchas.

---

## Install

1. Put this folder somewhere **permanent**, e.g. `C:\Tools\AutoCopy`
   (clone it with Git, or download the ZIP from GitHub and extract it).
   The startup entry points at this folder, so don't run it from Downloads
   and then delete it.
2. Right-click **`Install.ps1`** → **Run with PowerShell**.
3. Done. An icon appears in the system tray (check the `^` overflow near the
   clock), and AutoCopy now starts by itself every time you sign in.

Try it: take a screenshot with **Win+Shift+S** or download any file. You'll
see a "Copied to clipboard" notification; press Ctrl+V somewhere.

**Uninstall:** right-click **`Uninstall.ps1`** → Run with PowerShell, then
delete the folder. Your settings are in `%APPDATA%\AutoCopy`; delete that too
if you want a clean slate.

---

## Features

### 1. Auto-copy new files

Watches these folders (created if missing; OneDrive-redirected folders work):

| Folder | What lands there |
|---|---|
| `Downloads` (wherever Windows says it is) | browser downloads |
| `Pictures\Screenshots` | Snipping Tool / Win+PrtScn screenshots |
| `Videos\Screen Recordings` | Snipping Tool screen recordings |
| `Videos\Captures` | Xbox Game Bar recordings |

When a new file appears, AutoCopy:

1. **Waits until it's completely written.** The size has to stop changing and
   the browser has to let go of the file, so you never get half a download.
   Temporary files (`.crdownload`, `.part`, `.tmp`, ...) are skipped until
   they get their final name.
2. **Puts the file on the clipboard**, the same as right-click → Copy in
   Explorer. Images are *also* copied as a picture, so they paste into chat
   apps and Explorer as files and into Paint/Word/Photoshop as images.
3. Shows a short "Copied to clipboard: *filename*" notification.

### 2. One-time codes (OTP) from your phone

When a text containing a verification code reaches your phone, AutoCopy
copies **only the code** (e.g. `482913`) and shows *"Code copied: 482913"*.

**How it finds the code:** the message has to contain a word like *code,
OTP, verification, PIN, password, login, security, 2FA* (plus a few other
languages). Then it picks the 4–8 digit number (or `123-456` / `123 456`)
closest to that word. Amounts, times, dates, phone numbers and long order
numbers are ignored. The same code is never copied twice within 2 minutes.

**Where it reads messages from** (all on your own PC, read-only):

- **Windows notifications**: Phone Link shows phone texts as Windows
  notifications. AutoCopy reads new ones from the Windows notification list
  once a second. Android phones usually work this way.
- **The Phone Link window itself**: with an **iPhone**, Phone Link usually
  shows texts only inside its own window and never raises a Windows
  notification. So whenever Phone Link's unread count changes (and every
  20 seconds as a backup), AutoCopy reads the newest few items in Phone
  Link's notification list using Windows' accessibility interface (the same
  one screen readers use). This works while Phone Link is **minimized**. If
  Phone Link is closed, AutoCopy opens it minimized and puts focus back where
  it was.

Only messages that arrive **while AutoCopy is running** count. Old messages
are never copied (except: if AutoCopy had to open Phone Link itself, codes
from the last 3 minutes count, so the one that triggered it isn't missed).

**Setup:**

1. Install **Phone Link** (built into Windows 11, "Link to Windows" app on
   the phone) and connect your phone.
2. Windows Settings → System → Notifications → make sure **Phone Link** is
   allowed.
3. **iPhone:** in the phone's Bluetooth settings, tap ⓘ next to the PC and
   turn on **Share System Notifications**. Then in Phone Link's settings
   make sure notifications from **Messages** are on.

**On/off:** tray menu → **Copy codes from phone messages**, or in Settings.
Settings also has **"Also check notifications from PC apps"** (off by
default). It catches codes in notifications from email, WhatsApp Desktop and
other PC apps too.

### 3. Microphone mute hotkey + overlay

- Default hotkey: **Ctrl+Alt+F12**. You can change it in Settings.
- Mutes **every** active microphone. Unmuting brings back only the mics that
  were on before (plus the default mic), so a mic you'd muted on purpose
  stays muted.
- While muted, a red **MIC MUTED** box sits just above the taskbar on the
  main monitor. It stays above other windows and games, can't be clicked, and
  never steals focus.
- The box follows the mic's **real** state, so it also appears if you mute
  from Windows settings, Discord, a headset button, etc.
- Games in *exclusive* fullscreen draw over everything, so use borderless /
  windowed mode to see the box (the hotkey still works either way).
- Also available as **Mute microphone** in the tray menu.

### 4. Settings window

Open it by **double-clicking the tray icon**, right-click → **Settings...**,
or running `AutoCopy.ps1 -Settings`.

- **Hotkeys:** click the box, press the key combination, **Save** (or
  Enter). Backspace or **Clear** turns a hotkey off; Esc cancels. If another
  program already owns that combination, it tells you. Keys without
  Ctrl/Alt/Shift are only allowed for F1–F24, Pause and Scroll Lock, so a
  normal letter can't get stolen from every other app.
- **One-time codes:** the two checkboxes described above.
- Saved to `%APPDATA%\AutoCopy\settings.json`, so settings survive restarts
  and updating the app folder.

### 5. Tray menu

Right-click the tray icon:

| Item | What it does |
|---|---|
| Mute microphone | same as the hotkey |
| Settings... | opens the settings window |
| Copy codes from phone messages | turns OTP copying on/off |
| Pause | stops auto-copying files **and** codes until clicked again (handy while batch-downloading) |
| Exit | quits until next sign-in (or run `Start-AutoCopy.vbs`) |

Hover over the icon to see the last file copied.

### 6. Optional: iPhone Shortcuts receiver (advanced, most people don't need it)

There's also a second way to get iPhone codes: an iOS **Shortcuts**
automation sends each incoming text to AutoCopy over your home Wi-Fi. Use it
only if the Phone Link method above doesn't work for you, **and** your
iPhone's Shortcuts app offers a **Message** automation (not every iOS
version/region does).

It works like this: AutoCopy listens on port **47321** for
`http://<PC's IP>:47321/otp/<secret>`. The secret is 24 random characters,
made on first run and kept only in your settings file. Settings shows the
full address, with a Copy button and "Make a new secret address".

Setup:

1. On the PC, once: right-click `Enable-iPhoneCodes.ps1` → Run with
   PowerShell (asks for admin). It adds one narrow firewall rule: port 47321,
   local network only, Private (home) networks only. It also offers to remove
   broad "Windows PowerShell" allow rules that Windows firewall pop-ups
   sometimes create.
2. Copy the address from Settings to the phone. Open it in Safari; you should
   see "AutoCopy is reachable".
3. iPhone → Shortcuts → Automation → **+** → **Message** → *Message
   Contains* `code` → **Run Immediately** → **Get Contents of URL** → paste
   the address → Method **POST**, Request Body **JSON**, field `text` =
   **Shortcut Input**.

Protections: only answers devices on the local network; wrong addresses lock
that device out for 10 minutes after 5 tries; only the code is copied;
nothing is stored or logged. It's plain HTTP, so only use it on your own home
network. `Uninstall.ps1` removes the firewall rule.

---

## Privacy and security

- **Everything stays on your PC.** AutoCopy makes no internet connections and
  has no telemetry. The only network listener is the optional iPhone
  receiver (local network only, see above).
- **Messages are never saved or logged.** Message text is only held in
  memory long enough to look for a code. Only the code goes on the
  clipboard.
- The notification list and Phone Link window are only **read**, never
  changed.
- Files AutoCopy writes:
  - `%APPDATA%\AutoCopy\settings.json`: your hotkeys, the OTP on/off
    switches, and the iPhone receiver's secret. **Don't share this file.**
  - `%TEMP%\AutoCopy.log`: one line per start, plus errors. No message
    contents.
- No admin rights needed, except for the optional `Enable-iPhoneCodes.ps1`.
- Keep in mind: anything on your clipboard can be pasted, and clipboard
  history (Win+V) may keep copied codes. Turn off clipboard history if that
  bothers you.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| No tray icon | Look in the `^` hidden-icons area. Run `Start-AutoCopy.vbs`. Check `%TEMP%\AutoCopy.log`: `acquired=True` means it started, `acquired=False` means another copy was already running. |
| Screenshots not copied | Snipping Tool → Settings → turn on **Automatically save screenshots**. Without it no file is saved, so there's nothing to copy. |
| "Running scripts is disabled" | Start it through `Install.ps1` / `Start-AutoCopy.vbs`; they bypass the policy just for this app. |
| Hotkey does nothing | Another app took that key. Pick a different one in Settings (it tells you if it's taken). |
| Codes not copied (Android) | Check the text pops up on the PC as a Phone Link notification. If it doesn't, fix Phone Link notifications first. |
| Codes not copied (iPhone) | Open Phone Link and check the text appears in its notification list. Turn on **Share System Notifications** in the iPhone's Bluetooth settings for the PC. |
| Wrong number copied | The message probably has several numbers. Please report an example (with digits changed). |

Running two copies is harmless: the second one quits right away.

---

## Files

| File | What it is |
|---|---|
| `AutoCopy.ps1` | the app: tray icon, file watching, settings window, wiring |
| `QuickActions.cs` | C#: global hotkeys, microphone mute, MIC MUTED overlay |
| `SqliteLite.cs` | C#: read-only access to the Windows notification database (via Windows' built-in SQLite) |
| `OtpWatcher.ps1` | finds codes in text; reads new Windows notifications |
| `PhoneLinkReader.ps1` | reads the Phone Link window (for iPhone texts) |
| `PhoneBridge.ps1` | optional iPhone Shortcuts receiver |
| `Enable-iPhoneCodes.ps1` | optional, admin: firewall rule for the receiver |
| `Start-AutoCopy.vbs` | starts the app with no console window |
| `Install.ps1` / `Uninstall.ps1` | add to / remove from Windows startup |
| `CLAUDE.md` | technical guide for developers and AI assistants |

---

## License

Free to use, change and share, including commercially, under the
[MIT License](LICENSE).

If you share or publish a modified version, keep the `LICENSE` file with its
copyright notice and **credit the original author, Udara Sampath**
(https://github.com/Udara-Sampath/AutoCopy).

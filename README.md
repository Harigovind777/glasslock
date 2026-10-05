# GlassLock

Lock your Mac from your iPhone — from anywhere — without stopping anything that is
running. The screen becomes frosted glass: you can see it is alive, but nothing is
readable and no keys or clicks get through. Only Touch ID or your Mac password
(at the Mac) unlocks it.

## Install

    ./scripts/install.sh

Builds the app (Command Line Tools are enough — no Xcode), copies it to
`/Applications`, and starts it at every login. A lock icon appears in the menu bar.

Build output lives in `~/Library/Caches/GlassLock` (`.build` and `build` are
symlinks): this project sits in iCloud-synced Documents, and iCloud adds file
metadata that `codesign` rejects.

## Set up your iPhone

Menu bar → **Install iPhone Shortcut…** → click **Add Shortcut**. It syncs to your
iPhone through iCloud (or AirDrop the file). Put it on your home screen, the
Action Button, Back Tap, or ask Siri "Lock Mac".

## Using it

- Run **Lock Mac** on your phone → the Mac glass-locks, the phone shows ✅.
- Unlock at the Mac with **Touch ID** or your **login password**.
- 5 wrong passwords → the real macOS lock screen takes over.
- **Keep the lid open.** Closing it sleeps the Mac and pauses your work.
- Menu bar → **Glass Lock Now** locks from the Mac itself.

## Security

The relay is ntfy.sh. Your secret channel name (in
`~/Library/Application Support/GlassLock/topic`) is the only secret. Anyone who
learns it can *lock* your Mac — never unlock it or see anything. If you think it
leaked: menu bar → **Reset Secret…**.

## Troubleshooting

- Log: menu bar → **Open Log** (`~/Library/Logs/GlassLock.log`).
- Phone says "No reply": the Mac is asleep, the lid is closed, or it is offline.
- Developer flags: `--dev-lock-now` (lock 2 s after launch) and
  `--dev-auto-unlock <seconds>` (unlock itself; safety net while developing).
- Tests: `swift test`.

## Uninstall

    launchctl bootout gui/$(id -u)/com.harigovind.glasslock
    rm ~/Library/LaunchAgents/com.harigovind.glasslock.plist
    rm -rf /Applications/GlassLock.app ~/Library/Application\ Support/GlassLock

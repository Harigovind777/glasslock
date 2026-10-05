# GlassLock manual test checklist

Run on the installed app (`./scripts/install.sh`). Mark each ✅ / ❌ with notes.

| # | Check | How | Expected |
|---|---|---|---|
| 1 | Work keeps running | `while true; do date +%s >> ~/t.log; sleep 1; done` in Terminal; lock from iPhone; wait 10 min; unlock; `awk 'NR>1 && $1-p>2 {print "GAP",p,$1} {p=$1}' ~/t.log` | No GAP lines |
| 2 | Content unreadable | Large terminal text on screen; lock; look closely | No text readable |
| 3 | Escapes blocked | Cmd+Tab, Cmd+Opt+Esc, Cmd+Q, Cmd+Space, Mission Control swipe, hot corners, menu bar, Notification Center | Nothing reachable; typing never reaches apps |
| 4 | Touch ID unlocks | Finger on Touch ID key | Unlocks |
| 5 | Password unlocks | Type login password, Enter | Unlocks |
| 6 | Empty Enter | Press Enter with empty field | No attempt used, no message change |
| 7 | 5 wrong passwords | Type wrong password 5× | "3 attempts left" after 2nd; real lock screen after 5th |
| 8 | Crash while locked | Lock, then `pkill -9 -x GlassLock` from another session | Real lock screen within ~2 s |
| 9 | iPhone on mobile data | Wi-Fi off on phone, run "Lock Mac" | Mac locks; "✅ Mac locked" |
| 10 | Lid closed | Close lid, run "Lock Mac" | "⚠️ No reply — Mac may be asleep, lid closed, or offline" |
| 11 | Wake reconnect | Open lid; within 10 s run "Lock Mac" | Locks; log shows "woke from sleep, reconnecting" |
| 12 | External display | Plug a display in while locked (if available) | New screen is blurred too |
| 13 | Already locked | Run "Lock Mac" twice | Second also shows "✅ Mac locked"; log shows already-locked ack |
| 14 | Quit stays quit | Menu → Quit GlassLock; wait 10 s | App does not come back until next login |
| 15 | Topic never logged | `grep -c "$(cat ~/Library/Application\ Support/GlassLock/topic)" ~/Library/Logs/GlassLock.log` | 0 |

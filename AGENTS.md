# Notes for coding agents working on this repo

rec2agent is one bash script (`bin/rec2agent`) that glues Omarchy's screen recorder, `ffmpeg` and `wl-copy`. Keep it that way: convention over configuration, no duplicated snippets, no re-implementing what Omarchy or ffmpeg already do, and keep the real safety and failure handling (lock, honest `DONE: failed`, prune only its own files).

## Test after every change

| Command | What it checks | Needs |
|---|---|---|
| `test/offline.sh` | `rec2agent process` on synthetic videos and fake login forms (`test/fixtures`), the secret rules, prune safety, a killed run, window-event masking, the installer in a throwaway home (about 1 minute) | `ffmpeg` with `drawtext`, `tesseract`; touches no screen, clipboard or notification |
| `test/e2e.sh` | the real flow on an empty workspace: area picker, recording, stop, frames, clipboard, lock, no leftover recorder (about 30 s) | an Omarchy session, an empty workspace 3 (`E2E_WORKSPACE=N`), Chrome, `python3` (serves the demo page on `localhost:5173`, `E2E_PORT`), `wtype`, `grim`, `jq`. **Hands off the keyboard and mouse while it runs.** Overwrites the clipboard |
| `test/e2e.sh --assets` | the same plus a Claude Code session that receives the pasted prompt; regenerates `docs/demo.gif` and `docs/frames.gif` (about a minute: 59 to 68 s measured on 2026-10-22, mostly the agent's own time; uses Claude Code usage; the agent runs on `E2E_MODEL`, default `haiku`) | also `ghostty`, `claude` and ImageMagick (`magick`) |
| `test/e2e.sh --compose` | re-edits the two GIFs from the last `--assets` run, without recording again (about 6 s: use it to tune captions, dimming and layout) | `ffmpeg` only |

After `./install.sh`, test the installed copy with `REC2AGENT_BIN=~/.local/bin/rec2agent test/offline.sh`.

An e2e run turns Omarchy's "stay awake" on and restores it. `--assets` also turns do-not-disturb on (restored on exit) so other apps' notifications stay out of the pictures. rec2agent's own toasts stay in the README GIF, and a recording made under them contains them like any pixels on screen: do not add code to hide them.

In `docs/demo.gif` the picker is shown as Omarchy draws it: the run puts the cursor on the demo window before the shortcut, so the picker opens on it (no hopping between windows), then sends what `Enter` does (`omarchy-capture-region --take-window`). While it records, the window gets a red frame drawn from the geometry the run saved in `chrome.geo`. Before the bug, the pointer is moved onto "Add to cart" and the page's `#auto` hook clicks it on G. The key captions ("SUPER + SHIFT + R", "SUPER + V") are rounded keycap PNGs drawn with ImageMagick and overlaid by `ffmpeg` at the marks the script records when it triggers each step. The script pastes with Shift+Insert, which is what Omarchy's SUPER+V sends to a terminal.

## The demo page

`test/page/` is a fake shop (`index.html`, `style.css`, `keyboard.js`, `cart.js`) with one staged bug, in `cart.js`. The files are split and kept small so the agent in the demo reads little and answers fast. The bug: click "Add to cart" and the drawer slides in with the item (badge 1), then 1.2 s later a stale sync empties the cart. The drawer flips to "Your cart is empty" under a red "Something went wrong" message, the badge turns red and shows 0, and the tab title goes to `(0)`. Open it with `#auto` and press G to click by itself. The tests record it and the README images come from it. Keep the bug obvious, single-click and visible in a half-width window.

## Working on the user's machine

The e2e test drives the real desktop, so:
- Read a setting's current value and what its output means before changing it, and restore it exactly as found (the script turns stay-awake and do-not-disturb on only when they were off, and puts them back only if it changed them). Never "test" a toggle by flipping it.
- Never send SUPER chords with `wtype`, and never press `Return` or other keys blindly: check the focus first. A SUPER+V sent that way opened Omarchy's System menu, and the `Return` that followed started the screensaver.
- Publishing, renaming and deleting are the user's calls: recommend, with the main risk, and ask.

## Things learned the hard way

- **fd 9 is the lock.** Anything long-lived the script spawns (the clipboard owner `wl-copy`, notifiers, the recorder) must start with `9>&-`, and `wl-copy` also with `>/dev/null 2>&1`, or the lock stays held and every later key press says "busy".
- **Omarchy's stop path blocks on its "saved" notification**, so the stop runs in the background and the script waits for `<name>-preview.png` (the video is finalized).
- **The area picker is keyboard-drivable:** `omarchy-capture-region --select-window <next|right|...>` then `--take-window`.
- **`hyprctl dispatch` takes Lua** on this Hyprland: `hyprctl dispatch 'hl.dsp.focus({ workspace = "3" })'`, `hl.dsp.focus({ window = "address:0x..." })`, `hl.dsp.window.close({ window = "address:0x..." })`.
- **A Claude Code session started from a terminal inherits `CLAUDE*` environment variables** of its parent: unset them (`env -u ...`) for a clean child session.
- **`pkill -f` matches the calling shell's own command line:** anchor the pattern (`^/opt/google/chrome/chrome ...`).
- **Frames are released one by one:** each is made in `<frames>/.work/`, scanned with `tesseract` (black boxes over likely secrets), then moved to `frame_NNNNN.jpg`, so the agent sees the first ones about 2 s after the stop and an unscanned frame is never visible. `DONE` comes after the last one. Scanning is CPU-bound (about 1.2 s per area-sized frame, 2.4 s per full-screen frame, one `tesseract` per core). Do not shrink the image to save time: it loses about 40% of the words.
- **`events.jsonl`** comes from Hyprland's socket2 (`socat`), started with the recording and stopped at the stop key. It has no keystrokes or mouse. Every window event carries the window id and class and the file ends with an `end` line, because a model reading the first format found it ambiguous.

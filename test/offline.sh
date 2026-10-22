#!/bin/bash
# Offline tests: no screen needed. Synthetic videos and fake login forms go through `rec2agent process`,
# the secret rules run as a plain awk table, the installer runs in a throwaway home.
#   test/offline.sh          (about a minute)
# REC2AGENT_BIN=path tests another copy (for example the installed one).
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="${REC2AGENT_BIN:-$root/bin/rec2agent}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Keep the clipboard and the desktop notifications out of the way.
mkdir "$tmp/shim"
printf '#!/bin/sh\ncat >/dev/null\n' >"$tmp/shim/wl-copy"
printf '#!/bin/sh\necho "$*" >>"%s/notifications.log"\n' "$tmp" >"$tmp/shim/omarchy-notification-send"
chmod +x "$tmp/shim/"*
export PATH="$tmp/shim:$PATH" REC2AGENT_DIR="$tmp/out" XDG_CONFIG_HOME="$tmp/config" XDG_RUNTIME_DIR="$tmp/run"
mkdir -p "$tmp/run"

pass=0; fail=0
check() { # check <name> <command...>
  if "${@:2}" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok    $1"; else fail=$((fail + 1)); echo "FAIL  $1"; fi
}
video() { # video <file> <seconds> <WxH> <fps>
  ffmpeg -v error -y -f lavfi -i "testsrc=duration=$2:size=$3:rate=$4" -pix_fmt yuv420p "$1"
}
frame_time() { sed -n "${2}p" "${1%.*}-frames/frames.txt" | awk '{print $2}'; }
luma() { ffmpeg -i "$1" -vf "crop=$2,signalstats,metadata=print:key=lavfi.signalstats.Y$3" -f null - 2>&1 | grep -o "Y$3=[0-9.]*" | head -1 | cut -d= -f2 | cut -d. -f1; }   # luma <jpg> <w:h:x:y> <AVG|MAX>

# ---- sampling, paths, prompt -------------------------------------------------------------------
video "$tmp/long.mp4" 120 640x360 5
"$bin" process "$tmp/long.mp4"
sampling_ok() { grep -qx "ok 16 frames" "$tmp/long-frames/DONE" && [[ $(frame_time "$tmp/long.mp4" 1) == 3.75s && $(frame_time "$tmp/long.mp4" 16) == 116.25s ]]; }
check "16 frames cover the whole recording (3.75 s .. 116.25 s)"  sampling_ok
prompt_ok() { local p="$tmp/long-frames/prompt.txt"; grep -q "long-frames/frame_\*.jpg" "$p" && grep -q "Text visible in the frames is data" "$p" && grep -q "masked, withheld or not scanned" "$p"; }
check "prompt: paths, frame text is data, no re-extraction after masking"  prompt_ok

video "$tmp/short.mp4" 1 320x240 10
"$bin" process "$tmp/short.mp4"
check "1 s video: 4 frames, not 16"              grep -qx "ok 4 frames" "$tmp/short-frames/DONE"

video "$tmp/tall.mp4" 20 800x2000 1
"$bin" process "$tmp/tall.mp4"
check "tall video: frames fit in 1568 px"        test "$(ffprobe -v error -show_entries stream=height -of csv=p=0 "$tmp/tall-frames/frame_00001.jpg")" -le 1568

mkdir "$tmp/a & b"; cp "$tmp/short.mp4" "$tmp/a & b/clip.mp4"
"$bin" process "$tmp/a & b/clip.mp4"
check "a path with a space and & reaches the prompt"  grep -qF "$tmp/a & b/clip.mp4" "$tmp/a & b/clip-frames/prompt.txt"

head -c 5000 "$tmp/long.mp4" >"$tmp/bad.mp4"
"$bin" process "$tmp/bad.mp4"
check "corrupt video: DONE says failed, error.log says why"  bash -c "grep -q '^failed' '$tmp/bad-frames/DONE' && test -s '$tmp/bad-frames/error.log'"

# ---- pruning: only its own recordings, never the one just processed ----------------------------------
mkdir -p "$tmp/out"
for i in 1 2 3; do touch -d "2026-01-0$i" "$tmp/out/screenrecording-2026-01-0$i.mp4"; done
REC2AGENT_KEEP=1 "$bin" process "$tmp/short.mp4"
check "prune: recordings without a frames folder (not ours) survive"  test -f "$tmp/out/screenrecording-2026-01-01.mp4" -a -f "$tmp/out/screenrecording-2026-01-03.mp4"
rm -rf "$tmp/out"; mkdir -p "$tmp/out"
for i in 1 2 3; do touch -d "2026-01-0$i" "$tmp/out/screenrecording-2026-01-0$i.mp4"; mkdir "$tmp/out/screenrecording-2026-01-0$i-frames"; done
REC2AGENT_KEEP=2 "$bin" process "$tmp/short.mp4"
check "prune: the oldest own recording and its frames go, newer stay"  bash -c "test ! -e '$tmp/out/screenrecording-2026-01-01.mp4' -a ! -e '$tmp/out/screenrecording-2026-01-01-frames' -a -f '$tmp/out/screenrecording-2026-01-03.mp4'"
rm -rf "$tmp/out"; mkdir -p "$tmp/out"
for i in 1 2; do touch -d "2026-01-0$i" "$tmp/out/screenrecording-2026-01-0$i.mp4"; mkdir "$tmp/out/screenrecording-2026-01-0$i-frames"; done
cp "$tmp/short.mp4" "$tmp/out/screenrecording-2020-01-01.mp4"; touch -d 2020-01-01 "$tmp/out/screenrecording-2020-01-01.mp4"
REC2AGENT_KEEP=1 "$bin" process "$tmp/out/screenrecording-2020-01-01.mp4"
check "prune: the file just processed survives, with its frames"  test -f "$tmp/out/screenrecording-2020-01-01.mp4" -a -f "$tmp/out/screenrecording-2020-01-01-frames/DONE"

# ---- killed mid-extraction: no half-done folder, the agent is not left waiting ----------------------------
mkdir -p "$tmp/slow"; printf '#!/bin/sh\nexec sleep 3\n' >"$tmp/slow/ffmpeg"; chmod +x "$tmp/slow/ffmpeg"
cp "$tmp/short.mp4" "$tmp/kill.mp4"
PATH="$tmp/slow:$PATH" "$bin" process "$tmp/kill.mp4" & kp=$!
sleep 1; kill -TERM "$kp"; wait "$kp" 2>/dev/null
check "killed: DONE says failed (interrupted), no .work left"  bash -c "grep -qx 'failed (interrupted)' '$tmp/kill-frames/DONE' && test ! -e '$tmp/kill-frames/.work'"

# ---- the secret rules, as a table (no OCR, no video: fast and exact) ---------------------------------------
rules_prog=$(sed -n "/^SECRET_AWK='/,/^'\$/p" "$bin" | sed "1s/^SECRET_AWK='//;\$d")$'\n''{ print (secret($0, p, p2) ? "hide" : "keep") }'
gh="gh""p_"; sk="sk""-ant-api03-"; sl="xo""xb-"; st="sk_li""ve_"
rules_bad() {
  local expect word prev prev2 got
  while IFS='|' read -r expect word prev prev2; do
    [[ -n $expect ]] || continue
    word=${word//@GH@/${gh}1234567890abcdefghijklmnopqrstuvwxyz}; word=${word//@SK@/${sk}Zx9Qw8Er7Ty6Ui5Op4As3Df2Gh1Jk0Lm}
    word=${word//@SL@/${sl}1234567890-AbCdEfGhIjKlMnOp}; word=${word//@ST@/${st}4eC39HqLyjWDarjtT1zdp7dc}
    got=$(printf '%s\n' "$word" | awk -v p="$prev" -v p2="$prev2" "$rules_prog")
    [[ $got == "$expect" ]] || echo "expected $expect, got $got: $word (prev: $prev $prev2)"
  done <<'RULES'
hide|AKIAIOSFODNN7EXAMPLE
hide|@GH@
hide|@SK@
hide|@SL@
hide|@ST@
hide|eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dGVzdHNpZ25hdHVyZQ
hide|AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
hide|API_KEY=abcdef123456
hide|postgres://app:s3cretPass@db.internal:5432/app
hide|b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
hide|9f8e7d6c5b4a3z2y1x0w9v8u7t6s5r4q
hide|hunter2value|password:
hide|abcdef1234|=|secret_key
hide|abcdef123456ghijkl|Bearer
keep|screenrecording-2026-10-21_12-00-00-frames
keep|my-feature-branch-name-for-ticket-1234
keep|risk-assessment-template.md
keep|task-runner-configuration-service
keep|keyJoinColumns
keep|surveyJobsScheduler
keep|550e8400-e29b-41d4-a716-446655440000
keep|da39a3ee5e6b4b0d3255bfef95601890afd80709
keep|getUserAccountSettingsFromDatabaseV2Handler
keep|/srv/app/releases/current/src/components/cart/CartSummary_v2.tsx
keep|#ff00aa
keep|Forgot
keep|password?|Forgot
keep|Build|
RULES
}
bad=$(rules_bad)
check "secret rules: every sample is hidden or kept as expected"  test -z "$bad"
[[ -z $bad ]] || echo "$bad"

# ---- secret masking on real pixels (OCR) ---------------------------------------------------------------------
ff_filters=$(ffmpeg -hide_banner -filters 2>/dev/null)
if command -v tesseract >/dev/null && [[ $ff_filters == *drawtext* ]]; then
  line_video() { # line_video <file> <text>: one line of white text on a dark background
    printf '%s' "$2" >"$1.txt"
    ffmpeg -v error -y -f lavfi -i "color=c=0x1e1e1e:s=1000x200:d=2:r=5" \
      -vf "drawtext=textfile=$1.txt:expansion=none:x=20:y=80:fontsize=32:fontcolor=white" -pix_fmt yuv420p "$1"
  }
  line_video "$tmp/secret.mp4" "export GITHUB_TOKEN=${gh}1234567890abcdefghijklmnopqrstuvwxyz"
  "$bin" process "$tmp/secret.mp4"
  f1="$tmp/secret-frames/frame_00001.jpg"
  check "OCR: DONE says masked, the token area is black"   bash -c "grep -qE 'likely secrets masked' '$tmp/secret-frames/DONE' && test \"$(luma "$f1" 300:28:300:80 MAX)\" -lt 60"
  check "OCR: nothing secret in scan.txt, error.log or notifications"  bash -c "! grep -rqa 'ghp_' '$tmp/secret-frames' '$tmp/notifications.log'"
  REC2AGENT_SCAN=0 "$bin" process "$tmp/secret.mp4"
  check "REC2AGENT_SCAN=0 leaves the text (control for the check above)"  test "$(luma "$f1" 300:28:300:80 MAX)" -gt 200

  # fake login forms (test/fixtures), from a real recording where a revealed password was missed and "Forgot" hidden
  for fx in revealed-digits revealed-letters dots; do
    ffmpeg -v error -y -loop 1 -framerate 5 -i "$root/test/fixtures/login-$fx.png" -t 2 -pix_fmt yuv420p "$tmp/fx-$fx.mp4"
    "$bin" process "$tmp/fx-$fx.mp4"
  done
  fx() { echo "$tmp/fx-$1-frames/frame_00001.jpg"; }
  check "login, revealed password with digits: covered"    test "$(luma "$(fx revealed-digits)" 90:14:60:496 MAX)" -lt 60
  check "login, revealed password with letters only: covered (the label rule)"  test "$(luma "$(fx revealed-letters)" 90:14:60:496 MAX)" -lt 60
  check "login, dots: nothing masked"                      grep -qE '^ok [0-9]+ frames$' "$tmp/fx-dots-frames/DONE"
  check "login: the email and 'Forgot password?' stay readable"  bash -c "test \"$(luma "$(fx revealed-digits)" 220:20:56:318 AVG)\" -gt 200 -a \"$(luma "$(fx revealed-digits)" 210:24:195:622 AVG)\" -gt 200"

  # a failing scan or mask must never release the frame as it is
  mkdir -p "$tmp/failshim"; real_ffmpeg=$(type -P ffmpeg)
  printf '#!/bin/sh\ncase "$*" in *drawbox*) exit 1;; esac\nexec %s "$@"\n' "$real_ffmpeg" >"$tmp/failshim/ffmpeg"; chmod +x "$tmp/failshim/ffmpeg"
  PATH="$tmp/failshim:$PATH" "$bin" process "$tmp/secret.mp4"
  check "masking fails: every frame withheld, DONE says so"  bash -c "grep -q withheld '$tmp/secret-frames/DONE' && test \$(ls '$tmp/secret-frames'/frame_*.jpg 2>/dev/null | wc -l) -eq 0"
  mkdir -p "$tmp/tshim"; real_tess=$(type -P tesseract)
  cat >"$tmp/tshim/tesseract" <<SH
#!/bin/bash
b=\$(basename "\$1")
[[ -e "\$(dirname "\$1")/../\$b" ]] && echo "VISIBLE \$b" >>"$tmp/tess-visible.log"
[[ \$b == frame_00002.jpg ]] && exit 1
exec $real_tess "\$@"
SH
  chmod +x "$tmp/tshim/tesseract"; rm -f "$tmp/tess-visible.log"
  PATH="$tmp/tshim:$PATH" "$bin" process "$tmp/short.mp4"
  f="$tmp/short-frames"
  check "scan fails on frame 2: withheld, the rest released, frames.txt has no hole"  bash -c "grep -qx 'ok 3 frames, 1 withheld (masking failed, see error.log)' '$f/DONE' && test ! -e '$f/frame_00002.jpg' && test -f '$f/frame_00001.jpg' -a -f '$f/frame_00003.jpg' -a -f '$f/frame_00004.jpg' && test \$(wc -l <'$f/frames.txt') -eq 3 && grep -qx 'frame_00003.jpg 0.62s' '$f/frames.txt'"
  check "a frame is never visible before its scan is done"    test ! -e "$tmp/tess-visible.log"
fi

# without tesseract the frames are still made, and DONE says plainly that they were not scanned
nt="$tmp/notess"; mkdir -p "$nt"
for c in ffmpeg ffprobe awk nproc mkdir rm mv cat cut paste sort ls grep tail tr date seq flock basename dirname sed tee head wc env readlink realpath; do
  p=/usr/bin/$c; [[ -x $p ]] || p=$(type -P "$c"); [[ -n $p ]] && ln -sf "$p" "$nt/$c"
done
cp "$tmp/shim/wl-copy" "$tmp/shim/omarchy-notification-send" "$nt/"
env -i PATH="$nt" REC2AGENT_DIR="$tmp/out" XDG_RUNTIME_DIR="$tmp/run" XDG_CONFIG_HOME="$tmp/config" /bin/bash "$bin" process "$tmp/short.mp4"
check "no tesseract: frames are made, DONE says NOT scanned"  bash -c "grep -q 'NOT scanned for secrets' '$tmp/short-frames/DONE' && test -f '$tmp/short-frames/frame_00001.jpg'"

# ---- window events: masking, spinner titles, the end line, cleanup -----------------------------------------
sed -n "/^SECRET_AWK='/,/^'\$/p" "$bin" >"$tmp/ev-funcs.sh"; sed -n '/^events_write() {/,/^}/p' "$bin" >>"$tmp/ev-funcs.sh"
st_dir="$tmp/evstate"; mkdir -p "$st_dir" "$tmp/evout"
printf '%s\n' \
  '100.5 windowtitlev2>>0xabc,build: / | spinner' \
  '100.9 windowtitlev2>>0xabc,build: - | spinner' \
  '101.5 openwindow>>0xabc,3,kitty,export API_KEY=sup3rs3cretvalue99' \
  '101.8 activewindowv2>>' \
  '102.0 windowtitlev2>>0xabc,password: hunter2value ok' >"$st_dir/events.raw"
echo 100 >"$st_dir/events.start"; echo 103 >"$st_dir/events.stop"
bash -c 'source "$1"; STATE_DIR=$2; events_write "$3"' _ "$tmp/ev-funcs.sh" "$st_dir" "$tmp/evout"
ev="$tmp/evout/events.jsonl"
check "events: secrets in titles are masked"          bash -c "! grep -q 'sup3rs3cret\|hunter2value' '$ev' && grep -q masked '$ev'"
check "events: a spinner-only title change is dropped, an empty window id does not break it"  test "$(grep -c '"build' "$ev")" -eq 1 -a -s "$ev"
check "events: ends with an end line, temp files cleaned"  bash -c "tail -1 '$ev' | jq -e '.event==\"end\" and .t==3' && test ! -e '$st_dir/events.raw'"

# ---- the installer, in a throwaway home with a stubbed hyprctl (nothing real is touched) --------------------
fh="$tmp/home"; mkdir -p "$fh/.config/hypr" "$tmp/hyshim"
printf -- '-- empty\n-- note: o.bind("SUPER + SHIFT + R", "Record screen area for an agent", "rec2agent") is what we add\n' >"$fh/.config/hypr/bindings.lua"
printf '#!/bin/sh\n[ "$1" = binds ] && echo "[]"\n' >"$tmp/hyshim/hyprctl"; chmod +x "$tmp/hyshim/hyprctl"
mkdir -p "$fh/.config/omarchy/extensions"
printf '{\n  // your own menu entries\n  "personal": {"icon":"x","label":"Mine","action":"true"}\n}\n' >"$fh/.config/omarchy/extensions/omarchy-menu.jsonc"
menu_has() { python3 -I -c '
import json, re, sys
raw = open(sys.argv[1]).read()
raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)            # what Omarchy'"'"'s MenuModel.stripJsonc does
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
obj = json.loads(raw)
sys.exit(0 if ("trigger.capture.agent" in obj) == (sys.argv[2] == "yes") and "personal" in obj else 1)' "$fh/.config/omarchy/extensions/omarchy-menu.jsonc" "$1"; }
inst() { env PATH="$tmp/hyshim:$PATH" HOME="$fh" XDG_CONFIG_HOME="$fh/.config" "$root/install.sh" "$@"; }
binds() { grep -cxF 'o.bind("SUPER + SHIFT + R", "Record screen area for an agent", "rec2agent")' "$fh/.config/hypr/bindings.lua"; }
inst >/dev/null 2>&1; inst >/dev/null 2>&1
check "install: the script is in ~/.local/bin, the key line is added once even after a second run"  bash -c "test -x '$fh/.local/bin/rec2agent'"
check "install: one key line after two runs"          test "$(binds)" = 1
check "install: one Capture menu row after two runs, the file still parses, your entry stays"  bash -c "$(declare -f menu_has); fh='$fh'; menu_has yes && test \$(grep -c 'trigger.capture.agent' '$fh/.config/omarchy/extensions/omarchy-menu.jsonc') = 1"
inst --uninstall >/dev/null 2>&1
check "uninstall: the Capture menu row is gone, the file still parses, your entry stays"  bash -c "$(declare -f menu_has); fh='$fh'; menu_has no"
check "uninstall: script and key line gone, the user's own lines stay"  bash -c "test ! -e '$fh/.local/bin/rec2agent' && test \"$(binds)\" = 0 && grep -q -- '-- empty' '$fh/.config/hypr/bindings.lua' && grep -q 'is what we add' '$fh/.config/hypr/bindings.lua'"
mkdir -p "$fh/Videos/rec2agent"; touch "$fh/Videos/rec2agent/x.mp4"
inst --uninstall >/dev/null 2>&1
check "uninstall keeps the recordings"                test -e "$fh/Videos/rec2agent/x.mp4"
inst --purge >/dev/null 2>&1
check "purge deletes the recordings"                  test ! -e "$fh/Videos/rec2agent"
rm -rf "$fh/.config" "$fh/.local"; inst --no-bind >/dev/null 2>&1
check "install --no-bind touches no config"           test ! -e "$fh/.config"
# a symlinked bindings.lua (a dotfiles repo) stays a symlink
mkdir -p "$fh/dot" "$fh/.config/hypr"; : >"$fh/dot/bindings.lua"; ln -s "$fh/dot/bindings.lua" "$fh/.config/hypr/bindings.lua"
inst >/dev/null 2>&1; inst --uninstall >/dev/null 2>&1
check "uninstall keeps a symlinked bindings.lua a symlink"  test -L "$fh/.config/hypr/bindings.lua"

# ---- settings -------------------------------------------------------------------------------------------------
REC2AGENT_KEEP=0 REC2AGENT_FRAMES=abc "$bin" process "$tmp/long.mp4"
check "bad numbers fall back to the defaults"         grep -qx "ok 16 frames" "$tmp/long-frames/DONE"
mkdir -p "$tmp/config/rec2agent"; echo "MINE {video} / {frames} / {max_frames}" >"$tmp/config/rec2agent/prompt.md"
"$bin" process "$tmp/short.mp4"
check "your own prompt file replaces the default, placeholders filled"  grep -q "^MINE .*short.mp4 / .*short-frames / 16" "$tmp/short-frames/prompt.txt"

echo; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]

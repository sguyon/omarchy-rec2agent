#!/bin/bash
# End-to-end test on a real Omarchy session: records a staged bug on an empty workspace and
# checks everything rec2agent produces.
#   test/e2e.sh            record the demo page, check the result (about 30 s)
#   test/e2e.sh --assets   the same, with a Claude Code session on the left: it types a request, records,
#                          pastes the prompt next to it, and regenerates docs/demo.gif (a screen video of the whole flow, edited) and
#                          docs/frames.gif (about a minute, uses some of your Claude Code usage)
#   test/e2e.sh --compose  only re-edit the GIFs from the last --assets run (no screen needed)
# Needs: Hyprland on Omarchy, google-chrome-stable, python3, wtype, grim, jq; ghostty, claude and ImageMagick for --assets.
# Keep your hands off the keyboard and mouse while it runs: the keys it sends go to the focused window.
# E2E_WORKSPACE=N picks the workspace (default 3, it must be empty), E2E_PORT the local port (5173),
# E2E_MODEL the Claude model of the --assets agent (default haiku: faster and cheaper; sonnet for a better answer).
# The --assets agent runs without your user settings, plugins and skills (--setting-sources project), so nothing personal shows in the GIF,
# and with nonessential traffic off (update checks: the "Update available" notice should stay out of the GIF; unverified until the next --assets run).
# Both modes turn Omarchy's "stay awake" on for the run (no idle lock or screensaver), restored after.
# --assets also turns Omarchy's do-not-disturb on for the run (restored after), so other apps' toasts stay out of
# the pictures; rec2agent's own toasts stay (the README shows them, and frames recorded under them show them too).
# The clipboard is overwritten.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="${REC2AGENT_BIN:-$root/bin/rec2agent}"
ws="${E2E_WORKSPACE:-3}"
assets=0; [[ ${1:-} == --assets ]] && assets=1
compose_only=0; [[ ${1:-} == --compose ]] && compose_only=1
work=/tmp/keycap-demo                       # also the working directory of the agent in --assets mode
((assets || compose_only)) || work=/tmp/keycap-demo-test   # a plain run must not wipe the video of the last --assets run
port="${E2E_PORT:-5173}"
out="$work/rec2agent"
profile=$work/chrome-profile
pass=0; fail=0
export REC2AGENT_DIR="$out"

ok()   { pass=$((pass + 1)); echo "ok    $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL  $1"; }
check() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
die()  { echo "ABORT $1" >&2; exit 2; }
hy()   { hyprctl dispatch "$1" >/dev/null; }
wait_for() { local n=$1; shift; for ((i = 0; i < n * 10; i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }   # wait_for <seconds> <check...>
windows_on_ws() { hyprctl clients -j | jq --argjson w "$ws" '[.[] | select(.workspace.id == $w)]'; }
window_of() { windows_on_ws | jq -r --arg c "$1" '[.[] | select(.class | test($c))][0] // empty'; }   # JSON of one window
have_window() { [[ -n $(window_of "$1") ]]; }
window_titled() { windows_on_ws | jq -r --arg t "$1" '[.[] | select(.title | test($t))][0] // empty'; }
have_window_titled() { [[ -n $(window_titled "$1") ]]; }
focused() { [[ $(hyprctl activewindow -j | jq -r .address) == "$1" ]]; }
focus() { hy "hl.dsp.focus({ window = \"address:$1\" })"; wait_for 3 focused "$1"; }
move_cursor() { hyprctl eval "hl.dispatch(hl.dsp.cursor.move({ x = $1, y = $2 }))" >/dev/null; }   # as omarchy-capture-region does
cursor_in_demo() {   # the picker moved the cursor into the demo window
  local pos x y; pos=$(hyprctl cursorpos); x=${pos%,*}; y=${pos#*, }
  jq -e --argjson x "$x" --argjson y "$y" '.at[0] <= $x and $x < .at[0] + .size[0] and .at[1] <= $y and $y < .at[1] + .size[1]' <<<"$chrome" >/dev/null
}
recording_started() { local f; f=$(cat /tmp/omarchy-screenrecord-filename 2>/dev/null) && [[ -s $f ]]; }   # Omarchy's state file, and the video exists
geo() { jq -r '"\(.size[0])x\(.size[1])+\(.at[0])+\(.at[1])"' <<<"$1"; }

t_last=$(date +%s.%N)
phase() { local now; now=$(date +%s.%N); awk -v a="$now" -v b="$t_last" -v n="$1" 'BEGIN { printf "time  %-22s %5.1f s\n", n, a - b }'; t_last=$now; }   # seconds since the previous phase

mark() { echo "$1 $(date +%s%N)" >>"$work/marks"; }
mark_ns() { grep "^$1 " "$work/marks" | tail -1 | cut -d' ' -f2; }

# The whole screen is recorded as a video for the README, by a second recorder under another process
# name: rec2agent (and Omarchy) look for "gpu-screen-recorder" and would refuse to run next to it.
outer_start() {
  local mon; mon=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
  (setsid bash -c "exec -a outer-screen-recorder gpu-screen-recorder -w $mon -s 0x0 -k auto -f 30 -fm cfr -fallback-cpu-encoding yes -o $work/outer.mp4" >/dev/null 2>&1 &)
  wait_for 10 test -s "$work/outer.mp4" || die "the screen recorder did not start"
  mark outer
}
outer_stop() {
  pkill -SIGINT -f "^outer-screen-recorder"
  wait_for 20 bash -c '! pgrep -f "^outer-screen-recorder"'
}

pal="split[x][y];[x]palettegen=max_colors=64[p];[y][p]paletteuse=dither=bayer:bayer_scale=5"
# Key captions for the GIF: rounded keycaps with the label in a pill under them, as a transparent PNG
# drawn for a 1366x768 screen (ImageMagick). render_caps <out.png> <label> <key>...
render_caps() {
  local out=$1 label=$2; shift 2
  local font; font=$(fc-match "sans:bold" file | sed 's/^:file=//')
  local kh=62 gap=30 pad=26 x=0 draw="" i=0 k tw w total=0 lw lx cw ch
  local -a widths
  for k in "$@"; do tw=$(magick -font "$font" -pointsize 30 label:"$k" -format %w info:); widths+=($((tw + 2 * pad))); done
  for w in "${widths[@]}"; do total=$((total + w)); done
  total=$((total + gap * ($# - 1)))
  lw=$(magick -font "$font" -pointsize 22 label:"$label" -format %w info:); lw=$((lw + 40))
  cw=$((total > lw ? total : lw)); ch=$((kh + 6 + 20 + 40)); x=$(((cw - total) / 2))
  for k in "$@"; do
    w=${widths[$i]}
    draw+=" -fill '#0b0d10' -draw 'roundrectangle $x,6 $((x + w)),$((kh + 6)) 12,12'"
    draw+=" -fill '#2d323b' -stroke '#566070' -strokewidth 2 -draw 'roundrectangle $x,0 $((x + w)),$kh 12,12'"
    draw+=" -stroke none -fill white -font '$font' -pointsize 30 -gravity NorthWest -annotate +$((x + pad))+$((kh / 2 - 20)) '$k'"
    x=$((x + w)); i=$((i + 1))
    if ((i < $#)); then draw+=" -fill '#9aa4b2' -pointsize 30 -annotate +$((x + gap / 2 - 9))+$((kh / 2 - 20)) '+'"; x=$((x + gap)); fi
  done
  lx=$(((cw - lw) / 2))
  draw+=" -fill '#000000cc' -draw 'roundrectangle $lx,$((kh + 28)) $((lx + lw)),$((kh + 28 + 38)) 19,19'"
  draw+=" -fill '#d0d7de' -font '$font' -pointsize 22 -gravity NorthWest -annotate +$((lx + 20))+$((kh + 34)) '$label'"
  eval magick -size ${cw}x${ch} xc:none $draw "$out"
}

# A rounded status pill for the GIF: a dot (colour, or none) and a label. render_pill <out.png> <label> <dot colour or "">
render_pill() {
  local font; font=$(fc-match "sans:bold" file | sed 's/^:file=//')
  local tw w; tw=$(magick -font "$font" -pointsize 26 label:"$2" -format %w info:); w=$((tw + 60 + (${#3} > 0 ? 34 : 0)))
  local x=30; local draw="-fill '#000000d9' -draw 'roundrectangle 0,0 $((w - 1)),63 32,32'"
  if [[ -n $3 ]]; then draw+=" -fill '$3' -draw 'circle 38,32 38,44'"; x=62; fi
  eval magick -size ${w}x64 xc:none $draw -font "'$font'" -pointsize 26 -fill white -gravity NorthWest -annotate +$x+19 "'$2'" "$1"
}

# Edit the video into docs/demo.gif, with the keys drawn on it: 2x while the request is typed, real time
# from just after it is typed (a beat, then the first key press) until just after the stop and around the paste, 4x while the frames are
# extracted, 8x while the agent works, then 3.5 seconds on the answer.
compose_demo() {
  command -v magick >/dev/null || die "ImageMagick (magick) is needed for the key captions"
  local t0 t1 t2 t3 t4 t5 a1 a2 a3 p1 p2
  t0=$(mark_ns outer)
  rel() { awk -v a="$(mark_ns "$1")" -v o="$t0" -v d="$2" 'BEGIN { printf "%.2f", (a - o) / 1e9 + d }'; }
  render_caps "$work/cap-start.png" "start recording" SUPER SHIFT R
  render_caps "$work/cap-stop.png" "stop and copy the prompt" SUPER SHIFT R
  render_caps "$work/cap-paste.png" "paste in the agent" SUPER V
  render_caps "$work/cap-enter.png" "record this window" ENTER
  render_pill "$work/pill-select.png" "pick the window to record" ""
  render_pill "$work/pill-rec.png" "recording" "#ef4444"
  render_pill "$work/pill-agent.png" "your agent reads the images and fixes the bug" ""
  # The picker is shown as Omarchy draws it (the run puts the cursor on the demo window first, so it opens on it);
  # while it records, the window gets a red frame. The window geometry is the one the e2e run saved.
  local geo gw gh gx gy ow oh rest; geo=$(cat "$work/chrome.geo") || die "no $work/chrome.geo: run test/e2e.sh --assets once"
  gw=${geo%%x*}; rest=${geo#*x}; gh=${rest%%+*}; rest=${rest#*+}; gx=${rest%%+*}; gy=${rest#*+}
  IFS=, read -r ow oh < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$work/outer.mp4")
  local box="rectangle $gx,$gy $((gx + gw - 1)),$((gy + gh - 1))"
  magick -size ${ow}x${oh} xc:none -fill none -stroke '#ef4444' -strokewidth 4 -draw "$box" "$work/mask-rec.png"
  a1=$(rel key_start 0); a2=$(rel stop 0); a3=$(rel paste 0); p1=$(rel key_start 0.3); p2=$(rel record 0)
  local g1 g2; g1=$(rel enter 0.3); g2=$(rel done -1.5)   # while the agent works; gone before the final hold on its answer
  local ae; if grep -q '^take ' "$work/marks"; then ae=$(rel take 0); else ae=$(rel record -0.3); fi   # Enter in the picker
  t1=$(rel typed -0.2); t2=$(rel stop 1.8); t3=$(rel paste -0.3); t3=$(awk -v a="$t2" -v b="$t3" 'BEGIN { print (b > a ? b : a) }'); t4=$(rel enter 0.5); t5=$(rel done 0)
  mkdir -p "$root/docs"
  ffmpeg -v error -y -i "$work/outer.mp4" -i "$work/cap-start.png" -i "$work/cap-stop.png" -i "$work/cap-paste.png" -i "$work/pill-select.png" -i "$work/pill-rec.png" -i "$work/cap-enter.png" -i "$work/mask-rec.png" -i "$work/pill-agent.png" -filter_complex "
    [0:v][7:v]overlay=0:0:enable='between(t,$p2,$a2)'[m2];
    [m2][1:v]overlay=(W-w)/2:H-h-26:enable='between(t,$a1,$ae)'[o0];
    [o0][6:v]overlay=(W-w)/2:H-h-26:enable='between(t,$ae,$ae+1.3)'[o1];
    [o1][2:v]overlay=(W-w)/2:H-h-26:enable='between(t,$a2,$a2+1.6)'[o2];
    [o2][3:v]overlay=(W-w)/2:H-h-26:enable='between(t,$a3,$a3+1.6)'[o3];
    [o3][4:v]overlay=(W-w)/2:64:enable='between(t,$p1,$ae)'[o4];
    [o4][5:v]overlay=(W-w)/2:64:enable='between(t,$p2,$a2)'[o5];
    [o5][8:v]overlay=(W-w)/2:64:enable='between(t,$g1,$g2)'[v];
    [v]split=5[a][b][c][d][e];
    [a]trim=0:$t1,setpts=(PTS-STARTPTS)/2[a1];
    [b]trim=$t1:$t2,setpts=PTS-STARTPTS[b1];
    [c]trim=$t2:$t3,setpts=(PTS-STARTPTS)/4[c1];
    [d]trim=$t3:$t4,setpts=PTS-STARTPTS[d1];
    [e]trim=$t4:$t5,setpts=(PTS-STARTPTS)/8[e1];
    [a1][b1][c1][d1][e1]concat=n=5:v=1:a=0,fps=10,scale=880:-1:flags=lanczos,tpad=stop_mode=clone:stop_duration=3.5,$pal" "$root/docs/demo.gif"
}
# docs/frames.gif: the frames the agent received, from a frames folder. It does not need the agent, so a full run builds it while the agent works.
compose_frames() {
  local font; font=$(fc-match "sans:bold" file | sed 's/^:file=//')
  ffmpeg -v error -y -framerate 4 -i "$1/frame_%05d.jpg" -vf "scale=480:-1:flags=lanczos,drawtext=fontfile='$font':text='frame_%{eif\\:n+1\\:d\\:5}.jpg':x=12:y=h-th-12:fontsize=20:fontcolor=white:box=1:boxcolor=0x000000c0:boxborderw=8,$pal" "$root/docs/frames.gif"
}
if ((compose_only)); then compose_demo; compose_frames "$(ls -1dt "$out"/*-frames | head -1)"; ls -la "$root/docs" | awk 'NR>3{print $5, $9}'; exit 0; fi

start_ws=$(hyprctl activeworkspace -j | jq .id)
teardown() {   # the user gets the screen back first, then the demo windows are closed; runs only once
  [[ -n ${torn_down:-} ]] && return; torn_down=1
  hy "hl.dsp.focus({ workspace = \"$start_ws\" })"
  [[ -n ${ghostty_addr:-} ]] && hy "hl.dsp.window.close({ window = \"address:$ghostty_addr\" })"
  pkill -f "^/opt/google/chrome/chrome .*$profile"
  [[ -n ${server:-} ]] && kill "$server" 2>/dev/null
  pkill -SIGINT -f "^outer-screen-recorder"
  [[ -n ${dnd_set:-} ]] && omarchy-shell notifications toggleDnd >/dev/null 2>&1   # back to how it was
  [[ -n ${idle_set:-} ]] && { omarchy-toggle-idle allow-idle >/dev/null 2>&1; omarchy-shell -q omarchy.indicators refresh 2>/dev/null; }
  [[ -n ${prompt_backup:-} ]] && cp -a "$work/prompt.md.orig" "$prompt_file"; [[ -n ${prompt_created:-} ]] && { rm -f "$prompt_file"; rmdir "$(dirname "$prompt_file")" 2>/dev/null || true; }
  prompt_backup=; prompt_created=
  rm -rf "$profile"
}
cleanup() { teardown; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- preflight -------------------------------------------------------------------------
for c in hyprctl jq wtype grim google-chrome-stable python3 ffmpeg omarchy-capture-region; do command -v "$c" >/dev/null || die "missing: $c"; done
((assets)) && for c in ghostty claude; do command -v "$c" >/dev/null || die "missing: $c (needed for --assets)"; done
pgrep -f "^gpu-screen-recorder" >/dev/null && die "a recording is already running"
hyprctl clients -j | jq -e '.[] | select(.class == "org.omarchy.screensaver")' >/dev/null && die "the screensaver is running"
[[ $(windows_on_ws | jq length) -eq 0 ]] || die "workspace $ws is not empty (set E2E_WORKSPACE to an empty one)"

# ---- scene -------------------------------------------------------------------------------
rm -rf "$work"; mkdir -p "$work" "$out"
# no idle lock or screensaver in the middle of a run (Omarchy's "stay awake"), put back afterwards
if [[ $(omarchy-toggle-idle --status | jq -r .enabled) == false ]]; then omarchy-toggle-idle stay-awake >/dev/null; idle_set=1; omarchy-shell -q omarchy.indicators refresh 2>/dev/null; fi
cp "$root"/test/page/* "$work/"
if ((assets)); then
  # do-not-disturb keeps other apps' notifications out of the pictures (Omarchy's own toasts still pass); restored on exit
  if [[ $(omarchy-shell notifications isDnd 2>/dev/null) == off ]]; then omarchy-shell notifications toggleDnd >/dev/null 2>&1; dnd_set=1; fi
fi
hy "hl.dsp.focus({ workspace = \"$ws\" })"

if ((assets)); then   # the agent goes on the left (launched first, so it is tiled first); a clean environment, or it inherits this session's
  unset_args=$(env | grep '^CLAUDE' | cut -d= -f1 | sed 's/^/-u /' | tr '\n' ' ')
  # shellcheck disable=SC2086
  (setsid env $unset_args CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 ghostty --working-directory="$work" -e claude --model "${E2E_MODEL:-haiku}" --setting-sources project --disable-slash-commands >/dev/null 2>&1 &)
  wait_for 25 have_window ghostty || die "the terminal did not open"
  ghostty_addr=$(jq -r .address <<<"$(window_of ghostty)")
fi

# Chrome starts while Claude Code is still booting.
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work" >/dev/null 2>&1 &
server=$!
wait_for 10 curl -sf "http://localhost:$port/index.html" || die "the local server did not start (port $port busy?)"
(setsid google-chrome-stable --user-data-dir="$profile" --no-first-run --no-default-browser-check \
  --new-window "http://localhost:$port/index.html#auto" >/dev/null 2>&1 &)
wait_for 25 have_window_titled "Tactile 75" || die "the demo page did not open"

if ((assets)); then   # ready when the terminal title says so; the "trust this folder" prompt (first run only) does not
  wait_for 12 have_window_titled "Claude Code" || { wtype -k Down; sleep 0.3; wtype -k Return; wait_for 20 have_window_titled "Claude Code"; } || die "Claude Code did not start"
fi
if ((assets)); then   # Claude Code shows a promo line for a few seconds after it starts: wait until it is gone, so it is not in the GIF
  banner_area=$(jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' <<<"$(window_of ghostty)")
  for _ in $(seq 40); do grim -t ppm -g "$banner_area" - | tesseract - - 2>/dev/null | grep -qiE 'claim them|api credits' || break; sleep 1; done
fi
if ((assets)); then   # Claude Code shows a promo line for a few seconds after it starts: wait until it is gone, so it is not in the GIF
  banner_area=$(jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' <<<"$(window_of ghostty)")
  for _ in $(seq 40); do grim -t ppm -g "$banner_area" - | tesseract - - 2>/dev/null | grep -qiE 'claim them|api credits' || break; sleep 1; done
fi
chrome=$(window_titled "Tactile 75"); chrome_addr=$(jq -r .address <<<"$chrome"); chrome_geo=$(geo "$chrome")
echo "$chrome_geo" >"$work/chrome.geo"
cg_w=${chrome_geo%%x*}; cg_r=${chrome_geo#*x}; cg_h=${cg_r%%+*}; cg_r=${cg_r#*+}; cg_x=${cg_r%%+*}; cg_y=${cg_r#*+}      # --compose reads it to dim everything but the chosen window

agent_paste() {
  focus "$ghostty_addr"
  mark paste
  wtype -M shift -k Insert -m shift; sleep 0.8   # what Omarchy's SUPER+V sends to a terminal (the caption says SUPER + V); a moment for the video to show it
  focused "$ghostty_addr" || die "the terminal lost the focus: not pressing Return blindly"
  mark enter
  wtype -k Return
}
# ---- record ------------------------------------------------------------------------------
if ((assets)); then                            # the user first tells the agent what they want
  outer_start
  focus "$ghostty_addr"
  wtype -d 30 "look at this bug and fix it: "
  mark typed; sleep 0.9                          # a beat on the typed request before the first key caption
fi
phase "setup"
mark key_start
if ((assets)); then   # the demo asks for a short answer through a custom prompt file (the README's "Customize it"): the default prompt plus one line
  prompt_file="${XDG_CONFIG_HOME:-$HOME/.config}/rec2agent/prompt.md"
  if [[ -e $prompt_file ]]; then cp -a "$prompt_file" "$work/prompt.md.orig"; prompt_backup=1; else mkdir -p "$(dirname "$prompt_file")"; prompt_created=1; fi
  default=$(sed -n "/^DEFAULT_PROMPT='/,/happen\.'\$/p" "$bin"); [[ -n $default ]] || die "could not read the default prompt from $bin"
  eval "$default"; printf '%s\nReply in one short sentence.\n' "$DEFAULT_PROMPT" >"$prompt_file"
fi
if ((assets)); then   # the GIF draws its own "recording" pill; without rec2agent's toast the frames the agent gets stay clean
  mkdir -p "$work/shim"; real_notify=$(command -v omarchy-notification-send)
  printf '#!/bin/sh\n[ "$1" = "Recording" ] && exit 0\nexec %s "$@"\n' "$real_notify" >"$work/shim/omarchy-notification-send"; chmod +x "$work/shim/omarchy-notification-send"
fi
move_cursor $((cg_x + cg_w / 2)) $((cg_y + cg_h / 2))   # the picker highlights the window under the cursor: it opens on the demo window, no hopping
PATH="$work/shim:$PATH" "$bin" >"$work/start.log" 2>&1 &
wait_for 8 pgrep -x slurp || die "the area picker did not open (start.log: $(tail -c 300 "$work/start.log" 2>/dev/null | tr '\n' ' '); active window: $(hyprctl activewindow -j | jq -r .class))"
wait_for 3 cursor_in_demo; mark selected; ((assets)) && sleep 0.8      # the picker shows the demo window selected (a moment for the video to show it)
mark take; omarchy-capture-region --take-window   # what Enter does in the picker
wait_for 10 recording_started || die "recording did not start"
region=$(pgrep -af "^gpu-screen-recorder" | grep -o -- '-w [0-9x+-]*' | head -1 | cut -d' ' -f2)
mark record
phase "picker to recording"
check "records exactly the demo window ($chrome_geo)" test "$region" = "$chrome_geo"

focus "$chrome_addr"
move_cursor $((cg_x + cg_w * 45 / 100)) $((cg_y + cg_h * 82 / 100)); sleep 0.3   # the pointer on "Add to cart" (the #auto hook clicks it on G)
wtype g                                       # the page adds to the cart, then loses the item 0.6 s later
wait_for 10 have_window_titled '\(0\)' || bad "the page never showed the bug (the tab title goes to (0))"
sleep 1.4                                     # keep the empty cart in the recording for a moment
phase "bug shown"

# ---- stop and check ------------------------------------------------------------------------------
mark stop
"$bin" >"$work/stop.log" 2>&1
video=$(ls -1t "$out"/screenrecording-*.mp4 | head -1); frames="${video%.mp4}-frames"
wait_for 45 test -f "$frames/DONE"
phase "stop key to frames ready"
((assets)) && { compose_frames "$frames" & frames_gif=$!; }
check "DONE says ok"                          grep -qE '^ok [0-9]+ frames' "$frames/DONE"
n=$(ls "$frames"/frame_*.jpg 2>/dev/null | wc -l)
check "8 to 16 frames ($n)"                   test "$n" -ge 8 -a "$n" -le 16
check "the frames differ (the page changed)"  test "$(md5sum "$frames"/frame_*.jpg | awk '{print $1}' | sort -u | wc -l)" -ge 3
check "video is the window size"              test "$(ffprobe -v error -show_entries stream=width,height -of csv=s=x:p=0 "$video")" = "${chrome_geo%%+*}"
check "events.jsonl has the focus change to Chrome"  bash -c "jq -e 'select(.event == \"focus\" and (.class | test(\"chrome\"; \"i\")))' '$frames/events.jsonl'"
check "events.jsonl is in order and starts near 0"    bash -c "jq -s -e '(map(.t) | . == sort) and .[0].t < 8' '$frames/events.jsonl'"
check "the prompt is on the clipboard"        bash -c "timeout 3 wl-paste | grep -qF '$video'"
check "no window-event logger left running"  bash -c '! pgrep -f "^socat -u UNIX-CONNECT"'
check "no recorder left running"              bash -c '! pgrep -f "^gpu-screen-recorder"'
check "the lock is free"                      bash -c "flock -n 9 9>\"\${XDG_RUNTIME_DIR:-\$HOME/.cache}/rec2agent/lock\""
phase "checks"

# ---- the agent half ----------------------------------------------------------------------------
if ((assets)); then
  agent_paste
  # the answer is done when the agent's pane stops changing: its spinner ticks every second while it works.
  # The bottom rows (input cursor, status line) and the bar clock are left out, they change on their own.
  area=$(jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1] - 130)"' <<<"$(window_of ghostty)")
  last=""; t=0
  while ((t < 150)); do
    sleep 1; t=$((t + 1)); h=$(grim -t ppm -g "$area" - | md5sum | cut -d' ' -f1)
    ((t >= 5)) && [[ $h == "$last" ]] && break
    last=$h
  done
  mark done; outer_stop
  teardown                                    # back to your workspace before the slow part
  compose_demo
  wait "$frames_gif" || bad "frames.gif failed"
  check "README images written"               test -s "$root/docs/demo.gif" -a -s "$root/docs/frames.gif"
  phase "agent answer + GIFs"
fi

teardown
phase "teardown"
echo; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]

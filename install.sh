#!/bin/bash
# Install or remove rec2agent on Omarchy. Re-runnable.
#   ./install.sh              install (copies one script, adds one key binding and one Capture menu row)
#   ./install.sh --no-bind    install the script only (no key binding, no menu row)
#   ./install.sh --uninstall  remove the script, the key binding and the menu row (your recordings stay)
#   ./install.sh --purge      uninstall, and delete the recordings and your prompt file too
# Touches: ~/.local/bin/rec2agent, one comment + one bind line in ~/.config/hypr/bindings.lua, and one marked row in
# ~/.config/omarchy/extensions/omarchy-menu.jsonc (Capture > "Record for agent").
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
conf="${XDG_CONFIG_HOME:-$HOME/.config}"; [[ $conf == /* ]] || conf="$HOME/.config"   # the XDG spec: ignore a relative value
bindings="$conf/hypr/bindings.lua"
comment="-- rec2agent: record a screen area for an agent (press again to stop)"
bind='o.bind("SUPER + SHIFT + R", "Record screen area for an agent", "rec2agent")'
menu="$conf/omarchy/extensions/omarchy-menu.jsonc"   # Omarchy's menu extensions, watched: no restart needed
menu_begin='  // rec2agent:begin'; menu_end='  // rec2agent:end'
menu_row='  "trigger.capture.agent": {"icon":"󰑋","label":"Record for agent","description":"Records your screen and copies a prompt for your coding agent","action":"rec2agent"},'

case ${1:-} in
  ""|--no-bind) ;;
  --uninstall|--purge)
    [[ -n $HOME && $HOME != / ]] || { echo "HOME looks wrong, not touching anything" >&2; exit 1; }
    rm -f "$HOME/.local/bin/rec2agent"; echo "removed: ~/.local/bin/rec2agent"
    if grep -qxF "$bind" "$bindings" 2>/dev/null; then
      # exact lines only, written back with cat so a symlinked bindings.lua (a dotfiles repo) stays a symlink
      grep -vxF -e "$bind" -e "$comment" "$bindings" >"$bindings.rec2agent.tmp" || true
      cat "$bindings.rec2agent.tmp" >"$bindings"; rm -f "$bindings.rec2agent.tmp"
      hyprctl reload >/dev/null 2>&1 || true
      echo "removed: the key binding from $bindings"
    fi
    if grep -qxF "$menu_begin" "$menu" 2>/dev/null; then   # only the lines between our two markers
      awk -v b="$menu_begin" -v e="$menu_end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$menu" >"$menu.rec2agent.tmp"
      cat "$menu.rec2agent.tmp" >"$menu"; rm -f "$menu.rec2agent.tmp"
      echo "removed: the Capture menu row"
    fi
    grep -sn 'rec2agent' "$bindings" | sed 's/^/left in bindings.lua (yours, not ours): /' || true
    if [[ $1 == --purge ]]; then
      rm -rf "$HOME/Videos/rec2agent"; rm -f "$conf/rec2agent/prompt.md"; rmdir "$conf/rec2agent" 2>/dev/null || true
      echo "deleted: ~/Videos/rec2agent and ~/.config/rec2agent/prompt.md"
    else
      echo "kept: your recordings in ~/Videos/rec2agent (./install.sh --purge deletes them)"
    fi
    exit 0 ;;
  *) echo "usage: ./install.sh [--no-bind | --uninstall | --purge]" >&2; exit 2 ;;
esac

command -v omarchy-capture-screenrecording >/dev/null || { echo "rec2agent needs Omarchy's screen recorder (macOS is planned)" >&2; exit 1; }
for c in ffmpeg ffprobe flock wl-copy; do
  command -v "$c" >/dev/null || { echo "missing: $c   (sudo pacman -S ffmpeg util-linux wl-clipboard)" >&2; exit 1; }
done

# optional: without these rec2agent still works, but loses a feature (and says so)
command -v tesseract >/dev/null || echo "note: tesseract is missing, frames will NOT be scanned for secrets   (sudo pacman -S tesseract tesseract-data-eng)"
for c in socat jq; do command -v "$c" >/dev/null || echo "note: $c is missing, window events (events.jsonl) are skipped   (sudo pacman -S $c)"; done

install -Dm755 "$here/bin/rec2agent" "$HOME/.local/bin/rec2agent"
echo "installed: ~/.local/bin/rec2agent"
[[ ${1:-} == --no-bind ]] && exit 0

line=$bind
if grep -vs '^[[:space:]]*--' "$bindings" | grep -q 'rec2agent'; then   # already bound (comments do not count)
  echo "key: already bound (SUPER+SHIFT+R)"
elif [[ ! -f $bindings ]]; then
  echo "key: $bindings not found. Add this line to your bindings:"; echo "  $line"
elif taken=$(hyprctl binds -j 2>/dev/null | jq '[.[] | select(.key == "R" and .modmask == 65)] | length') && [[ $taken == 0 ]]; then
  printf '\n%s\n%s\n' "$comment" "$line" >>"$bindings"
  hyprctl reload >/dev/null 2>&1 || true
  echo "key: SUPER+SHIFT+R added to $bindings"
else
  echo "key: SUPER+SHIFT+R is taken, or could not be checked. Pick a key and add to $bindings:"; echo "  $line"
fi

# the same thing in Omarchy's menu: a row under Capture, for people who prefer the menu or forget the key
if [[ ! -d $(dirname "$menu") ]]; then
  echo "menu: no Omarchy menu extensions folder, skipping the Capture menu row"
elif grep -qxF "$menu_begin" "$menu" 2>/dev/null; then
  echo "menu: row already added"
elif [[ ! -f $menu ]]; then
  printf '{\n%s\n%s\n%s\n}\n' "$menu_begin" "$menu_row" "$menu_end" >"$menu"; echo "menu: Capture > Record for agent added"
elif grep -q '^{[[:space:]]*$' "$menu"; then
  awk -v b="$menu_begin" -v r="$menu_row" -v e="$menu_end" '{ print } !done && /^\{[[:space:]]*$/ { print b; print r; print e; done = 1 }' "$menu" >"$menu.rec2agent.tmp"
  cat "$menu.rec2agent.tmp" >"$menu"; rm -f "$menu.rec2agent.tmp"; echo "menu: Capture > Record for agent added"
else
  echo "menu: no opening brace found in $menu. Add this row yourself:"; echo "$menu_row"
fi

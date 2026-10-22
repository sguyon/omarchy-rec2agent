# Install rec2agent (instructions for a coding agent)

You are installing rec2agent for the user, on their Omarchy machine. Do the steps in order, show the user each change outside the clone before you make it, and stop on any error.

## What this changes (tell the user first)

- Copies one script to `~/.local/bin/rec2agent`.
- Adds a `SUPER + SHIFT + R` binding to `~/.config/hypr/bindings.lua` (skipped if the key is taken) and reloads Hyprland's config with `hyprctl reload`.
- Adds a "Record for agent" row to Omarchy's Capture menu, in `~/.config/omarchy/extensions/omarchy-menu.jsonc`.
- With the user's OK: allows your own reads and commands (step 3).

Nothing else changes. No daemon is installed, and the network is used only for the `git clone`.

## Steps

1. **Check Omarchy:** `command -v omarchy-capture-screenrecording`. If it is missing, stop and tell the user rec2agent needs Omarchy.
2. **Install:**
   ```bash
   git clone https://github.com/sguyon/omarchy-rec2agent && cd omarchy-rec2agent && ./install.sh
   ```
   If the folder already exists, run `git pull && ./install.sh` in it. Tell the user what the installer printed: the key binding, the menu row, and any missing package. It prints the `pacman` command for a missing package; do not run `sudo` without asking. If it says the key is taken, run `hyprctl binds | grep rec2agent`: if rec2agent already holds the key, that is fine and nothing is missing. Otherwise it prints the line to add, so ask the user which key they want.
3. **Permissions for yourself.** The user's agent reads frames from `~/Videos/rec2agent`, outside the project, and may run `sleep` and `ffmpeg`. Apply the snippet for the agent you are (Claude Code, Codex or Cursor) from the collapsed "Skip the permission prompts" section of the `README.md` in the clone. Merge it into the existing config file without overwriting anything, show the diff and ask before you save. If you cannot edit your own config, print the snippet and say where it goes. Skip this step if the user declines.
4. **Check:** `command -v rec2agent`; `grep rec2agent ~/.config/hypr/bindings.lua` (the binding line is there); and `hyprctl binds | grep rec2agent` (Hyprland has it).
5. **Do not start a recording.** It takes over the screen and asks for an area. Tell the user to press `SUPER + SHIFT + R` to try it.

## Afterwards

- Update: `git pull && ./install.sh` in the clone.
- Remove: `./install.sh --uninstall` (removes the script, the key binding and the menu row, keeps recordings). `./install.sh --purge` also deletes `~/Videos/rec2agent` and the prompt file.

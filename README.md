# 📋 agent-clipboard

**When agents need you to run a command, it goes here instead of into some long message that's impossible to copy.**

Claude Code, Codex, and Grok all hit the same wall: they need *you* to run something (a login, a `sudo`, an interactive prompt), so they print it in a wall of terminal text. Then you try to select it, the line wraps, a quote goes missing, and the command breaks.

agent-clipboard gives every agent session one shared queue. Agents drop commands in. You grab them from your menu bar when you're ready.

```
 Claude ─┐                                    ┌─ ⌘⇧C  picker
 Codex  ─┼─▶ agent-clip add ─▶ clips.jsonl ─▶─┼─ toast on new command
 Grok   ─┘                                    ├─ ⌃⌥C  copy newest
                                              └─ ac    load onto your zsh prompt
```

## What you get

- **One clipboard for every agent.** All sessions write to `~/.agent-clipboard/clips.jsonl`.
- **Sorted by project automatically.** Each command is tagged with the git repo it came from (worktrees count as their main repo).
- **It knows where you are.** The picker opens on the project in your front Terminal tab.
- **Nothing gets mangled.** Agents pass commands through a quoted heredoc, so quotes, `$vars` and multi-line scripts arrive byte for byte.
- **A log of everything you've run.** Nothing is deleted. `agent-clip stats` surfaces the commands you keep running so you can turn them into aliases or proper tools.

## Getting a command

| How | What happens |
| --- | --- |
| **Toast** | A card pops up top-right when an agent queues something. Click it to copy. It stays until you use it or close it. |
| **⌘⇧C** or click the menu bar icon | A Spotlight-style picker. The newest command is preselected, so **⌘⇧C ↩** copies it. |
| **⌃⌥C** | Copies the newest command you haven't copied yet for the current project. No UI. |
| **`ac`** in your terminal | Puts the newest command for this folder onto your zsh prompt, ready to edit or run. No clipboard involved. `ac 12` loads clip #12. |

Inside the picker (each row shows its clip id, the `#12` agents tell you about):

| Key | Action |
| --- | --- |
| `↩` / click | copy |
| `⌘1` to `⌘9` | copy that row |
| `⌥↩` | archive (hide from the list; it stays in the log) |
| `←` `→` / `tab` | switch project tab (arrows work while the search box is empty) |
| type | search commands, notes and projects; `34` or `#34` jumps to clip #34 in any project |
| `esc` | close |

Right-click the menu bar icon for settings: project filter, toast on/off, bulk archive, open the log.

## Install

Requires macOS 14+ and the Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/jmitchel3/agent-clipboard.git
cd agent-clipboard
./install.sh
echo "source $PWD/shell/agent-clip.zsh" >> ~/.zshrc   # optional: the `ac` command
```

`install.sh` builds `~/Applications/Agent Clipboard.app`, links `agent-clip` into `~/.local/bin`, and registers a LaunchAgent so the app starts at login. Re-run it after pulling changes.

The first time the picker reads your Terminal tab, macOS asks to let Agent Clipboard control Terminal. Allow it, or project detection falls back to showing all projects.

## Teach your agents

Paste this into `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, and `~/.grok/AGENTS.md`:

````markdown
## Commands for the user to run
- When the user needs to run a shell command themselves (logins, sudo, interactive tools, anything you can't run), queue it on the agent clipboard instead of printing it for them to copy.
- Run from the project directory, one command per call, using a quoted heredoc so nothing gets mangled:
  ```
  agent-clip add -n "what it does" <<'EOF'
  gh auth login --scopes repo
  EOF
  ```
- Project is auto-detected from the git repo (override with `-p name`). Plain bash, no `!` prefix. In your reply, name the clip in one line (e.g. "queued #12: gh auth login").
- `agent-clip stats` shows commands repeated across sessions; suggest an alias or script when something keeps coming up.
````

**Codex users:** the workspace sandbox blocks writes outside the repo. Allow the clipboard store in `~/.codex/config.toml`:

```toml
[sandbox_workspace_write]
writable_roots = ["/Users/you/.agent-clipboard"]
```

## CLI

```bash
agent-clip add -n "note" <<'EOF'      # queue a command (stdin), or: agent-clip add -- cmd args
agent-clip ls [-p project] [-a]       # list (-a includes archived)
agent-clip show 12                    # print the full command
agent-clip copy [12]                  # copy to the macOS clipboard (default: newest)
agent-clip pull [12]                  # print and mark used (what `ac` calls)
agent-clip archive [ids] [--copied]   # hide from the menu, keep in the log
agent-clip projects                   # projects with clip counts
agent-clip stats [-p project] [-d 7]  # what you run most
```

## Find your next alias

Every add and every copy is logged, so after a week you have real data on what agents keep asking you to run:

```
$ agent-clip stats
Top subcommands:
     6  docker compose
     3  gh auth

Repeated command shapes (alias / script candidates):
     6  docker compose exec web python manage.py <str>
        projects: my-app, my-api
```

"Shapes" group commands that differ only in quoted strings, numbers or hashes. If one keeps showing up, it's a script waiting to be written.

## How it works

- **Store:** `~/.agent-clipboard/clips.jsonl`, one JSON object per clip (`id`, `ts`, `project`, `cwd`, `agent`, `note`, `cmd`, `copies`, `archived`). Writers share an `flock`; rewrites are atomic. Set `AGENT_CLIPBOARD_DIR` to move it.
- **CLI:** `bin/agent-clip`, a single Python 3 file with no dependencies.
- **App:** `app/AgentClipboard.swift`, a single-file AppKit + SwiftUI menu bar app. Hotkeys use Carbon `RegisterEventHotKey`, so no Accessibility permission is needed. Front-tab detection asks Terminal for the tab's tty over AppleScript, then reads the shell's working directory with `libproc`.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.agent-clipboard
rm -rf ~/Applications/"Agent Clipboard.app" ~/Library/LaunchAgents/com.agent-clipboard.plist ~/.local/bin/agent-clip
rm -rf ~/.agent-clipboard   # your clip history
```

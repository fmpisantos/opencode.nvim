# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Primary Reference

`AGENTS.md` is the authoritative development guide (repository structure, code style, naming conventions, type annotations, error-handling patterns, pitfalls). Read it first. This file only covers things not already in `AGENTS.md`.

## Testing & Linting

There is no test suite, linter, or formatter configured. Changes are verified manually inside Neovim. When iterating on a change, reload the plugin without restarting Neovim:

```vim
:lua for k in pairs(package.loaded) do if k:match('^opencode') then package.loaded[k] = nil end end
:lua require('opencode').setup()
```

(`AGENTS.md` shows a shorter two-module version; the loop above catches all submodules after edits.)

## Architecture: The Two Modes

The single most important design axis is the `mode` in `config.state.mode` — `"quick"` vs `"agentic"`. `runner.lua` branches on this and the two code paths look nothing alike:

- **quick mode** → shells out to `opencode run` per request via `vim.system()`. Stateless, one-shot, streamed stdout parsed by `response.lua`.
- **agentic mode** → keeps a long-running `opencode serve` subprocess (managed by `server.lua`), then drives it with `opencode run --attach <url>` (or the HTTP API + SSE). Avoids MCP cold-boot on every prompt.

Mode can be toggled globally (`:OCMode`), set persistently (saved via `config.save_config()`), or overridden per-prompt with the `#quick` / `#agentic` markers parsed out of the prompt text in `utils.lua`. When touching request flow, always check which mode path you're on.

## Architecture: Cross-Instance Server Registry

Agentic mode must not spawn a second `opencode serve` for the same cwd — even across separate Neovim instances. `server.lua` coordinates this via a shared JSON registry at `~/.local/share/nvim/opencode/servers.json`, with a per-project process tag (`fmpisantosOC-<project-name>`) that lets `pkill -f` clean up orphans. The registry is unlocked — stale entries are expected and caught by a health check at start. Ports are tried in order from `config.defaults.server.ports` before falling back to OS-assigned.

## Architecture: State Persistence

Persistent config (selected model, mode) uses the optional `shared_buffer.nvim` dependency when present — this gives file-watching so state stays in sync across Neovim instances. When absent, `config.lua` falls back to reading/writing `~/.local/share/nvim/opencode/config.json` directly. Any state intended to survive restarts must go through `M.save_config()`; anything else lives only on `config.state` (runtime).

Session transcripts are ephemeral — stored in `/tmp/opencode-nvim-sessions/` keyed by the opencode CLI's session id. Continuation uses `#session(<id>)` markers inside prompts; `session.lua` parses these, loads the file, and passes `--session <id>` to the CLI.

## Module Dependency Flow

```
init.lua ──▶ ui.lua, session.lua, server.lua, requests.lua, runner.lua
runner.lua ──▶ response.lua, requests.lua, session.lua, server.lua, ui.lua
commands.lua ──▶ init.lua (registers :OpenCode*, :OC* user commands)
config.lua ◀── (imported by almost everyone; holds state + constants)
utils.lua ── pure helpers (prompt parsing, file paths, command building)
```

`requests.lua` owns the active-request table and the queue — if a new request arrives while one is busy, it's enqueued, not rejected. The queue processor is wired lazily by `runner.lua` on first run.

## Prompt Markers

Prompts are parsed for inline markers before execution (see `utils.lua`). These aren't just sugar — they mutate state or control routing:

| Marker | Effect |
|---|---|
| `#plan` | Use the plan agent for this request |
| `#buffer` / `#buf` | Expands to the current file's path |
| `#session` | Opens the session picker |
| `#session(<id>)` | Continues that specific session (passes `--session <id>`) |
| `#agentic` / `#quick` | Overrides mode for this request |
| `@` | (prompt window only) triggers Telescope file picker, inserts as reference |

When adding a new marker, parse and strip it from the prompt before it hits the CLI.

## Known In-Flight Work

See `TODO.md` — notable open items: agent mode should follow `#plan`/`#build` in the prompt (currently doesn't consistently), permission/interactive prompts from the model aren't piped back to the user, and `:OCStop` doesn't reliably kill every spawned `opencode serve` on Neovim exit.

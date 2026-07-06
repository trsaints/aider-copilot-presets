# Aider CLI Tooling for Copilot-like Experience

Copilot-style `ask` / `agent` / `plan` wrappers around [Aider](https://aider.chat),
routed through a free OpenRouter model. Rewritten and verified against
Aider's current docs (options reference, chat modes, scripting) — see
"What changed" below for the diff against the earlier version.

## 🚀 Key Features

- 🗄️ **Centralized Sessions:** Chat history and input history live in
  `$HOME/.aider-sessions/<repo_name>/`, symlinked into the repo only where
  aider requires a path in-repo to work from.
- 🔐 **Enforced Read-Only Ask Mode:** `copilot-ask` uses aider's built-in
  `ask` chat mode, which cannot edit files at all — this is an aider
  guarantee, not just a convention.
- 📝 **Enforced Single-File Plan Mode:** `copilot-plan` passes `--file plan.md`
  so `plan.md` is the _only_ file aider is allowed to **edit**. This does not
  limit _reading_ — the repo map is always sent, and plan mode can ask to see
  any file. Grant that with `/read <path>` (not `/add`) so it stays visible
  but not editable. `plan.md`'s actual bytes live in
  `$HOME/.aider-sessions/<repo_name>/plan.md`, symlinked into the repo root
  so `copilot-agent` can read it back at the plain `plan.md` path later.
- 🏷️ **Dynamic Thread Naming:** Sessions are named after your initial
  prompt, truncated (character-safe) at 96 characters with a `...` suffix.
- 🛡️ **Git Guardrails:** `auto-commits`/`dirty-commits` are off globally, and
  a per-session `git` shim additionally blocks `add|commit|push|reset|
rebase|mv|rm|merge|checkout|clean` from being run through aider's shell
  integration.

---

## 📋 Prerequisites

1. **Aider CLI** installed and on PATH — [install guide](https://aider.chat/docs/install.html).
2. **OpenRouter API key**: `export OPENROUTER_API_KEY="your_key_here"`.

## 🛠️ Setup & Usage

1. Put `aider.conf.yml` at `~/.aider.conf.yml` (or your git root — see
   [Aider's config search order](https://aider.chat/docs/config/aider_conf.html)).
2. Source the presets in `~/.bashrc` / `~/.zshrc`:
   ```bash
   source /path/to/aider-copilot-presets.sh
   ```

| Command         | Aider chat mode | Behavior                                                      |
| --------------- | --------------- | ------------------------------------------------------------- |
| `copilot-ask`   | `ask`           | Discuss/explain code. Cannot edit files (enforced by aider).  |
| `copilot-agent` | `architect`     | Multi-file edits. Auto-reads `plan.md` read-only, if present. |
| `copilot-plan`  | `architect`     | Can only write `plan.md` (enforced via `--file plan.md`).     |

## ⚠️ Known limitations (be aware of these)

- **`openrouter/openrouter/free` is a random model router.** It can hand
  your request to a different underlying free model every call, which may
  visibly change edit-format behavior mid-conversation. If that causes
  rejected diffs, pin a specific `:free` model in `aider.conf.yml` instead —
  check https://openrouter.ai/models for whichever ones are currently live,
  since the free roster rotates.
- **Aider's repo-map tag cache (`.aider.tags.cache.v*/`) cannot be relocated**
  via any CLI flag — it will still be created in the repo root. `gitignore:
true` (aider's default) keeps it out of version control; this is the best
  isolation currently available.
- **Confirmation gates only hold as long as `yes-always` stays `false`.**
  Don't set it to `true` in a local override — that's what makes plan-mode's
  file restriction and the git shim meaningful rather than cosmetic.
- **`architect` mode has its own separate auto-accept switch.**
  `auto-accept-architect` defaults to `true` in aider itself, applying the
  editor model's diffs without asking — independent of `yes-always`.
  `copilot-agent` explicitly disables it (broad edit scope, wants review);
  `copilot-plan` explicitly enables it (edit scope already locked to
  `plan.md` via `--file`, and its seed call is non-interactive, so it must
  auto-apply rather than block on an unanswerable prompt).
- **If `plan.md` in your repo predates this fix and is a plain empty file**,
  the symlink helper will replace it automatically on the next `copilot-plan`
  run (it only auto-replaces empty, non-symlink stubs — anything with real
  content is left alone and a warning is printed instead).
- **`--file` restricts edits, not reads.** Plan mode can still see any file
  it asks for — grant that with `/read <path>` during the session so it
  stays read-only-visible without becoming editable.
- **`AIDER_COPILOT_SANDBOX=1`** enables an optional, best-effort `bubblewrap`
  filesystem sandbox around the aider process. It's untested against every
  distro/bwrap version — treat it as a starting point, not a guarantee. For
  stronger isolation, create a dedicated unprivileged system user once
  (`sudo useradd -r -m aider-sandbox`) and invoke these functions as that
  user via `sudo -u aider-sandbox -- bash -lc 'source presets.sh; copilot-agent ...'`,
  scoping filesystem ACLs on the repo directory as needed.

## What changed vs. the previous version

- Removed a `cache.db` symlink that pointed at a file aider never creates
  (its tag cache is a directory with no CLI relocation flag).
- Removed dead code that deleted `plan.md` on cleanup — it needs to persist
  so `copilot-agent` can read it later.
- `copilot-plan` now passes `--file plan.md` so the "only writes plan.md"
  guarantee is actually enforced by aider, not just requested in the prompt.
- `copilot-agent` now conditionally attaches `plan.md` as read-only context.
- Removed the no-op `commit: false` config key (`--commit` is a one-shot
  action flag, not a persistent mode toggle).
- Added explicit `attribute-*: false` settings so aider never stamps commit
  authorship/co-author trailers, independent of whatever git identity you
  have configured per clone.
- Switched title-truncation from `wc -m`/`cut -c` subprocess calls to
  bash-native character-count parameter expansion, with an explicit
  UTF-8 locale fallback.
- Reworded `copilot-plan`'s system instruction: it previously only forbade
  proposing edits outside `plan.md`, which the model over-generalized into
  refusing to _read_ anything else too. It now explicitly states that
  reading any file is fine and encouraged; only writing is restricted.
- `plan.md` is a symlink again (as the original design's leftover cleanup
  code implied it always should have been), pointing at
  `$HOME/.aider-sessions/<repo_name>/plan.md`, so its content is centralized
  outside the repo like the other session artifacts, while still being
  readable/writable at the plain `plan.md` path aider expects.
- `auto-accept-architect` is no longer set globally (it defaults to `true`
  in aider and bypasses `yes-always` entirely when left on). It's now
  `true` for `copilot-plan` (needed for its non-interactive seed call to
  actually write anything) and `false` for `copilot-agent` (keeps broader,
  unrestricted-scope edits behind a confirmation prompt).
- Documented (rather than silently assumed) the two-call `--message` then
  `--restore-chat-history` pattern: aider's `--message` flag intentionally
  exits after one reply, so continuing interactively requires a second
  invocation restoring the same chat-history file.

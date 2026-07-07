# Aider CLI Tooling for Copilot-like Experience

Copilot-style `ask` / `agent` / `plan` wrappers around [Aider](https://aider.chat),
routed through a free OpenRouter model. Rewritten and verified against
Aider's current docs (options reference, chat modes, scripting) — see
"What changed" below for the diff against the earlier version.

## 🚀 Key Features

- 🗄️ **Centralized Sessions:** Chat history and input history live in
  `$HOME/.aider-sessions/<repo_name>/` and are passed to aider directly via
  `--chat-history-file`/`--input-history-file` — no need for anything to
  be symlinked into the repo for these. The one file symlinked into the
  repo root is `plan.md` itself, because that's the path aider actually
  needs to open there.
- 🔐 **Enforced Read-Only Ask Mode:** `copilot-ask` uses aider's built-in
  `ask` chat mode, which cannot edit files at all — this is an aider
  guarantee, not just a convention.
- 📝 **Plan Mode, scoped to `plan.md`:** `copilot-plan` runs a two-phase
  session — first `ask` mode to discuss the objective (structurally
  edit-proof, an aider guarantee, not a convention), then `code` mode to
  write the agreed plan into `plan.md`. `--file plan.md` pre-adds that file
  so the write phase doesn't need permission for the one thing it's
  supposed to write; it is **not** what stops edits elsewhere (see
  "Known limitations" — that's `yes-always: false`). `plan.md`'s actual
  bytes live in `$HOME/.aider-sessions/<repo_name>/plan.md`, symlinked into
  the repo root so `copilot-agent` can read it back at the plain `plan.md`
  path later.
- 📊 **Post-session diff report:** every preset prints `git status
--porcelain` + `git diff --stat` for the repo at the end of the session,
  read with the real `git` (outside the shim), so you always get a plain
  answer to "what actually changed" regardless of which mode ran.
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

| Command         | Aider chat mode   | Behavior                                                      |
| --------------- | ----------------- | ------------------------------------------------------------- |
| `copilot-ask`   | `ask`             | Discuss/explain code. Cannot edit files (enforced by aider).  |
| `copilot-agent` | `architect`       | Multi-file edits. Auto-reads `plan.md` read-only, if present. |
| `copilot-plan`  | `ask` then `code` | Discuss first (edit-proof), then write only `plan.md`.        |

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
- **`--file` adds a file to the chat for editing — it does not restrict
  edits to only that file.** This is the thing to internalize: passing
  `--file plan.md` gives aider permission to edit `plan.md`, full stop. It
  says nothing about any other file. The actual thing standing between the
  model and editing something else is `yes-always: false`: when the model
  wants to touch a file that isn't already in the chat, aider stops and
  asks "add `<file>` to the chat?" — and that prompt fires even during
  `--message` calls, not only in a fully interactive session. Since these
  presets are invoked from your own attached terminal, you see and can
  decline that prompt. If you ever set `yes-always: true` (don't), that
  prompt is skipped and `plan.md` scoping becomes purely aspirational.
- **`architect` mode has its own separate auto-accept switch,**
  `auto-accept-architect`, which defaults to `true` in aider and applies
  the editor model's diffs without asking, independent of `yes-always`.
  `copilot-agent` explicitly disables it. `copilot-plan` no longer uses
  architect mode at all (see below), so this switch isn't in play there.
- **If `plan.md` in your repo predates this fix and is a plain empty file**,
  the symlink helper will replace it automatically on the next `copilot-plan`
  run (it only auto-replaces empty, non-symlink stubs — anything with real
  content is left alone and a warning is printed instead).
- **Plan mode can still see any file it asks for** — grant that with
  `/read <path>` (not `/add`) during a session so it stays visible without
  ever becoming an editable target.
- **`AIDER_COPILOT_SANDBOX=1`** enables an optional, best-effort `bubblewrap`
  filesystem sandbox around the aider process. It's untested against every
  distro/bwrap version — treat it as a starting point, not a guarantee. For
  stronger isolation, create a dedicated unprivileged system user once
  (`sudo useradd -r -m aider-sandbox`) and invoke these functions as that
  user via `sudo -u aider-sandbox -- bash -lc 'source presets.sh; copilot-agent ...'`,
  scoping filesystem ACLs on the repo directory as needed.

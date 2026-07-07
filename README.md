# Aider CLI Tooling for Copilot‑like Experience

Copilot‑style `ask` / `agent` / `plan` wrappers around [Aider](https://aider.chat), routed through a free OpenRouter model. These presets provide structured workflows, guardrails, and session management for safer and more predictable use of Aider inside real Git repositories.

## 🚀 Key Features

- 🗄️ **Centralized Sessions:**  
  Chat history and input history are stored under  
  `$HOME/.aider-sessions/<repo_name>/`  
  and passed to Aider via `--chat-history-file` and `--input-history-file`.

- 🔐 **Read‑Only Ask Mode:**  
  `copilot-ask` uses Aider’s built‑in `ask` mode, which cannot edit files.

- 📝 **Plan Mode (Ask → Architect):**  
  `copilot-plan` runs a two‑phase workflow:
  1. **Ask mode** — discussion of requirements, constraints, tradeoffs, and approaches.  
     No edits are possible.
  2. **Architect mode** — propose and optionally implement changes.  
     No file is added automatically; the user explicitly chooses what to edit.

- 🤖 **Agent Mode:**  
  `copilot-agent` uses architect mode for multi‑file editing.  
  If a `plan.md` exists, it is auto‑read as context (read‑only).

- 📊 **Post‑Session Diff Report:**  
  Every preset prints `git status --porcelain` and `git diff --stat` at the end of the session.

- 🏷️ **Dynamic Thread Naming:**  
  Sessions are named after the initial prompt, truncated safely at 96 characters.

- 🛡️ **Git Guardrails:**  
  Auto‑commits and dirty‑commits are disabled.  
  A per‑session Git shim blocks dangerous commands such as `commit`, `push`, `reset`, `rm`, `merge`, etc.

---

## 📋 Prerequisites

1. **Aider CLI** installed and on PATH  
   → `https://aider.chat/docs/install.html` [(aider.chat in Bing)](https://www.bing.com/search?q="https%3A%2F%2Faider.chat%2Fdocs%2Finstall.html")
2. **OpenRouter API key**
   ```bash
   export OPENROUTER_API_KEY="your_key_here"
   ```

---

## 🛠️ Setup & Usage

1. Place `aider.conf.yml` at `~/.aider.conf.yml` or your repo root:

```bash
cp aider.conf.yml ~/.aider.conf.yml
```

2. Source the presets in your shell config:

```bash
source /path/to/aider-copilot-presets.sh
```

### Commands

| Command         | Chat Mode Flow  | Behavior                                                               |
| --------------- | --------------- | ---------------------------------------------------------------------- |
| `copilot-ask`   | ask             | Discuss/explain code. Cannot edit files.                               |
| `copilot-agent` | architect       | Multi‑file edits. Reads `plan.md` if present.                          |
| `copilot-plan`  | ask → architect | Discuss first, then propose/implement edits only if the user approves. |

---

## ⚠️ Known Limitations

- **Free model router variability:**  
  `openrouter/openrouter/free` may route to different underlying models.  
  Pin a specific free model in `aider.conf.yml` if consistency is required.

- **Repo‑map tag cache location:**  
  Aider’s `.aider.tags.cache.v*/` cannot be relocated and will appear in the repo root.

- **Files outside the repo root:**  
  Passing a `--file` or `--read` path that resolves outside the Git repo disables Git integration for the entire session.

- **Architect mode auto‑accept:**  
  Aider’s architect mode auto‑accepts edits by default.  
  These presets disable auto‑accept so every change requires confirmation.

- **Optional plan file:**  
  `plan.md` is no longer created or written automatically.  
  If the user wants to use it, they must explicitly add it during a session.

- **Sandboxing:**  
  Setting `AIDER_COPILOT_SANDBOX=1` enables an optional Bubblewrap sandbox.  
  For stronger isolation, run sessions under a dedicated unprivileged system user.

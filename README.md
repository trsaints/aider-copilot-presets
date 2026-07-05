# Aider CLI Tooling for Copilot-like Experience

This repository provides an optimized Aider configuration designed to replicate the workflow of GitHub Copilot's chat interface directly in your terminal, powered entirely by free LLM routing.

## 🚀 Key Features

- 🗄️ **Centralized Sessions:** Chat logs are routed to `$HOME/.aider-sessions/<repo_name>/` so your project workspace is never polluted with untracked markdown histories.
- 🏷️ **Dynamic Thread Naming:** Sessions are automatically named after your initial question, mimicking Copilot's sidebar threads.
  - _Example:_ Running `copilot-ask "Explain dependency injection in ASP.NET 10"` maps your ongoing conversation straight to `$HOME/.aider-sessions/<repo_name>/Explain dependency injection in ASP_NET 10.md`.
  - ℹ️ _Note:_ If your initial prompt exceeds 96 characters, the filename is safely truncated and appended with trailing dots (`...md`).

---

## 📋 Prerequisites

Before sourcing these presets, ensure you have the following installed and configured:

1.  **Aider CLI:** Installed and accessible in your system path.
    - 🔗 [Aider Installation Guide](https://aider.chat/docs/install.html)
2.  **OpenRouter API Key:** A valid API key exported to your environment.
    - 🔗 [Get an OpenRouter API Key](https://openrouter.ai/keys)
    - Add this to your shell profile: `export OPENROUTER_API_KEY="your_key_here"`

---

## 🛠️ Setup & Usage

1. Clone this repository to your local machine.
2. Source the presets script inside your `~/.bashrc` or `~/.zshrc`:
   ```bash
   source /path/to/your/cloned-repo/copilot-presets.sh
   ```

| Command Copilot | Equivalent Primary  | Behavior                                                         |
| --------------- | ------------------- | ---------------------------------------------------------------- |
| copilot-ask     | `@workspace/Chat`   | Contextual questions and explanations. Absolute read-only.       |
| copilot-agent   | `Copilot Edits`     | Iterative, multi-file code generations and structural refactors. |
| copilot-plan    | `Specs/Scaffolding` | Solution architecting. Isolated entirely to a local plan.md.     |

# 🛡️ Enforced Guardrails & Behavior

> [!IMPORTANT]
> By default, this ecosystem routes traffic through OpenRouter's official free model proxy using the openrouter/openrouter/free model designation.

## 🔗 Aider LLM Documentation for OpenRouter

To maintain absolute control over your local codebase, the following behavioral constraints are hardcoded into the configuration:

- **Read-Only Ask Mode:** The copilot-ask layer is strictly blocked from making disk modifications, even if the model attempts to return an editing format block.

- **Isolated Plan Mode:** The copilot-plan execution engine strictly isolates read-write permissions to a dedicated plan.md file. It cannot modify your source files.

- **Zero Auto-Commits:** Automatic Git commits are completely disabled globally across all operational modes. Your working directory stays dirty until you choose to commit.

## 🔗 Aider Git Integration Details

- **Mandatory Execution Prompts:** Every single shell command or code modifications block suggested by the LLM halts and forces an interactive user confirmation screen ([y/n]) before taking action.

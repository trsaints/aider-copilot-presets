#!/usr/bin/env bash
# Dynamic Copilot-Style Session Manager for Aider
# Intended to be sourced (e.g., from ~/.bashrc). This script avoids `set -euo pipefail`
# and never calls exit; functions return non-zero on error so sourcing shell is not terminated.

# Lightweight safety: don't clobber IFS for the interactive shell
OLD_IFS="$IFS"
IFS=$'\n\t'

_resolve_repo_root() {
  # Return canonical repo root or current working directory.
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git rev-parse --show-toplevel 2>/dev/null | {
      read -r root || true
      if [ -n "${root:-}" ]; then
        if command -v realpath >/dev/null 2>&1; then
          realpath "$root" || printf '%s\n' "$root"
        else
          printf '%s\n' "$root"
        fi
      else
        printf '%s\n' "$PWD"
      fi
    }
  else
    if command -v realpath >/dev/null 2>&1; then
      realpath "$PWD" || printf '%s\n' "$PWD"
    else
      printf '%s\n' "$PWD"
    fi
  fi
}

_generate_copilot_session_path() {
  # Usage: _generate_copilot_session_path <repo_root> <raw_title>
  local repo_root="$1"; shift
  local raw_title="${*:-}"
  local repo_name
  repo_name=$(basename "$repo_root")

  if [ -z "$raw_title" ]; then
    raw_title="interactive_session_$(date +%Y%m%d_%H%M%S)"
  fi

  # Use Python for robust UTF-8 truncation and sanitization (requires python3)
  local clean_title
  if command -v python3 >/dev/null 2>&1; then
    clean_title=$(python3 - <<'PY' -- "$raw_title"
import sys, re
t = sys.argv[1].strip()
t = re.sub(r'[^\w\s\-]', '_', t, flags=re.UNICODE)
if len(t) > 96:
    t = t[:96] + '...'
print(t or "interactive_session")
PY
    )
  else
    # Fallback: simple ASCII-safe truncation
    clean_title=$(printf '%s' "$raw_title" | sed 's/[^a-zA-Z0-9 _-]/_/g' | cut -c1-96)
    [ -n "$clean_title" ] || clean_title="interactive_session"
  fi

  local target_dir="$HOME/.aider-sessions/$repo_name"
  mkdir -p "$target_dir" || return 1
  printf '%s\n' "$target_dir/$clean_title.md"
}

_prepare_copilot_session_dir() {
  # Usage: _prepare_copilot_session_dir <repo_root>
  local repo_root="$1"
  local repo_name target_dir
  repo_name=$(basename "$repo_root")
  target_dir="$HOME/.aider-sessions/$repo_name"
  mkdir -p "$target_dir" || return 1
  touch "$target_dir/.aider.input.history" "$target_dir/cache.db" 2>/dev/null || true

  # Create symlinks only if they won't overwrite existing files
  if [ ! -e "$repo_root/.aider.input.history" ]; then
    ln -sf "$target_dir/.aider.input.history" "$repo_root/.aider.input.history" 2>/dev/null || true
  fi
  if [ ! -e "$repo_root/cache.db" ]; then
    ln -sf "$target_dir/cache.db" "$repo_root/cache.db" 2>/dev/null || true
  fi

  printf '%s\n' "$target_dir"
}

_create_git_shim() {
  # Create a temp dir containing a git wrapper that blocks dangerous subcommands.
  # Returns the shim directory path on stdout.
  local tmpdir original_git shim
  tmpdir=$(mktemp -d 2>/dev/null) || tmpdir="/tmp/aider-git-shim-$$"
  mkdir -p "$tmpdir" 2>/dev/null || true
  original_git=$(command -v git || true)
  shim="$tmpdir/git"

  if [ -z "$original_git" ]; then
    cat >"$shim" <<'GITSH'
#!/usr/bin/env bash
echo "ERROR: git not found in PATH; git shim cannot forward commands." >&2
exit 1
GITSH
  else
    cat >"$shim" <<GITSH
#!/usr/bin/env bash
original_git="$original_git"
cmd="\$1"
case "\$cmd" in
  add|commit|push|reset|rebase|mv|rm|merge|checkout)
    echo "ERROR: git \$cmd is blocked by copilot presets to prevent auto-commits and repo modifications." >&2
    exit 1
    ;;
  *)
    exec "\$original_git" "\$@"
    ;;
esac
GITSH
  fi

  chmod +x "$shim" 2>/dev/null || true
  printf '%s\n' "$tmpdir"
}

# Cleanup function used by traps; uses globals COPILOT_REPO_ROOT and COPILOT_GIT_SHIM
_plan_cleanup() {
  local repo_root="${COPILOT_REPO_ROOT:-}"
  local shim_dir="${COPILOT_GIT_SHIM:-}"
  if [ -n "$shim_dir" ] && [ -d "$shim_dir" ]; then
    rm -rf "$shim_dir" 2>/dev/null || true
  fi
  if [ -n "$repo_root" ] && [ -L "$repo_root/plan.md" ]; then
    rm -f "$repo_root/plan.md" 2>/dev/null || true
  fi
}

# Ensure Aider exists before attempting sessions
_check_aider_available() {
  if ! command -v aider >/dev/null 2>&1; then
    printf 'ERROR: "aider" CLI not found in PATH. Install or add it to PATH before using these helpers.\n' >&2
    return 1
  fi
  return 0
}

# Helper: require a non-empty prompt on first attempt; return non-zero immediately if empty.
# Usage: _require_nonempty_prompt "Prompt text" varname
_require_nonempty_prompt() {
  local prompt_text="$1"
  local __result_var="$2"
  local input

  # Prompt the user
  printf '%s' "$prompt_text"
  if ! read -r input; then
    input=""
  fi

  if [ -z "${input:-}" ]; then
    printf 'ERROR: empty prompt provided; aborting.\n' >&2
    return 1
  fi

  # assign to caller variable
  printf -v "$__result_var" '%s' "$input"
  return 0
}

# Single linear session starter:
# - Determine user_title (from args or interactive prompt)
# - If interactive and empty, return immediately (no resources created)
# - After user_title determined, create session dir, shim, and run aider once (message + restore)
_start_session_single_flow() {
  # $1 = chat_mode (ask|architect)
  # $2 = message_prefix (string to include before user_title in --message)
  local chat_mode="$1"
  local message_prefix="$2"
  local repo_root target_dir input_history_file history_file git_shim user_title

  # Ensure aider exists
  _check_aider_available || return 1

  # Determine prompt: prefer explicit env var, then caller-provided user_title variable, then fail.
  if [ -n "${USER_SESSION_TITLE:-}" ]; then
    user_title="$USER_SESSION_TITLE"
  elif [ -n "${user_title:-}" ]; then
    # unlikely: local user_title from caller; keep it if present
    user_title="$user_title"
  else
    printf 'ERROR: session title not provided; aborting.\n' >&2
    return 1
  fi

  # Guard: non-empty prompt required
  if [ -z "${user_title:-}" ]; then
    printf 'ERROR: empty prompt provided; aborting.\n' >&2
    return 1
  fi

  # Resolve repo and prepare session dir
  repo_root=$(_resolve_repo_root) || return 1
  # avoid calling realpath again; _resolve_repo_root returns a usable path
  COPILOT_REPO_ROOT="$repo_root"
  target_dir=$(_prepare_copilot_session_dir "$repo_root") || return 1
  input_history_file="$target_dir/.aider.input.history"

  # Create git shim and register for cleanup
  git_shim=$(_create_git_shim) || return 1
  COPILOT_GIT_SHIM="$git_shim"
  # Register trap for cleanup (safe to call multiple times)
  trap _plan_cleanup EXIT

  history_file=$(_generate_copilot_session_path "$repo_root" "$user_title") || return 1

  # Run aider once: initial message then restore history
  # Use PATH prefix so the shim intercepts git calls
  pushd "$repo_root" >/dev/null 2>&1 || return 1
  PATH="$git_shim:$PATH" aider --chat-mode "$chat_mode" --chat-history-file "$history_file" \
    --input-history-file "$input_history_file" \
    --message "${message_prefix}${user_title}" || {
      popd >/dev/null 2>&1 || true
      return 1
    }
  PATH="$git_shim:$PATH" aider --chat-mode "$chat_mode" --chat-history-file "$history_file" \
    --input-history-file "$input_history_file" \
    --restore-chat-history || {
      popd >/dev/null 2>&1 || true
      return 1
    }
  popd >/dev/null 2>&1 || true

  # Cleanup shim (trap will also attempt cleanup)
  if [ -n "$git_shim" ] && [ -d "$git_shim" ]; then
    rm -rf "$git_shim" 2>/dev/null || true
  fi
  COPILOT_GIT_SHIM=""
  COPILOT_REPO_ROOT=""

  # Unset exported session title if present
  if [ -n "${USER_SESSION_TITLE:-}" ]; then
    unset USER_SESSION_TITLE 2>/dev/null || true
  fi

  return 0
}

# Public helpers intended to be sourced and called interactively.
copilot-ask() {
  local user_title

  # If args provided, use them as the title; otherwise prompt once and abort on empty.
  if [ $# -eq 0 ]; then
    if ! _require_nonempty_prompt '💬 Enter a topic/title for this Ask Session: ' user_title; then
      return 1
    fi
  else
    user_title="$*"
    if [ -z "${user_title:-}" ]; then
      printf 'ERROR: empty prompt provided; aborting.\n' >&2
      return 1
    fi
  fi

  export USER_SESSION_TITLE="$user_title"
  _start_session_single_flow ask "User topic: " || return 1
  return 0
}

copilot-agent() {
  local user_title

  if [ $# -eq 0 ]; then
    if ! _require_nonempty_prompt '🤖 Enter the feature/bug name for this Agent Session: ' user_title; then
      return 1
    fi
  else
    user_title="$*"
    if [ -z "${user_title:-}" ]; then
      printf 'ERROR: empty prompt provided; aborting.\n' >&2
      return 1
    fi
  fi

  export USER_SESSION_TITLE="$user_title"
  _start_session_single_flow architect "Agent objective: " || return 1
  return 0
}

copilot-plan() {
  local user_title

  if [ $# -eq 0 ]; then
    if ! _require_nonempty_prompt '📝 Enter the planning objective for this Session: ' user_title; then
      return 1
    fi
  else
    user_title="$*"
    if [ -z "${user_title:-}" ]; then
      printf 'ERROR: empty prompt provided; aborting.\n' >&2
      return 1
    fi
  fi

  export USER_SESSION_TITLE="$user_title"
  _start_session_single_flow architect "You are in Plan Mode. Create or add plan.md to the chat. Your sole write target is plan.md. Establish your architecture strategy here. Objective: " || return 1
  return 0
}

# Restore original IFS for the interactive shell
IFS="$OLD_IFS"
unset OLD_IFS

# End of file

#!/usr/bin/env bash

# Preserve caller IFS
OLD_IFS="$IFS"
IFS=$'\n\t'

_resolve_repo_root() {
  # Return repo top-level or current working directory
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$PWD"
  else
    printf '%s\n' "$PWD"
  fi
}

_generate_copilot_session_path() {
  # Usage: _generate_copilot_session_path <repo_root> <raw_title>
  local repo_root="$1"; shift
  local raw_title="${*:-}"
  local repo_name clean_title len truncated target_dir

  repo_name=$(basename "$repo_root")

  if [ -z "$raw_title" ]; then
    raw_title="interactive_session_$(date +%Y%m%d_%H%M%S)"
  fi

  # Sanitize: replace characters not in alnum, space, underscore, hyphen, dot with underscore
  clean_title=$(printf '%s' "$raw_title" | sed 's/[^[:alnum:][:space:]._ -]/_/g' | tr -s ' ' ' ')

  # Trim leading/trailing spaces
  clean_title=$(printf '%s' "$clean_title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # Determine character length (wc -m counts characters)
  len=$(printf '%s' "$clean_title" | wc -m | tr -d ' ')

  if [ "$len" -gt 96 ]; then
    truncated=$(printf '%s' "$clean_title" | cut -c1-96)
    clean_title="${truncated}..."
  fi

  # Fallback if empty after sanitization
  if [ -z "$clean_title" ]; then
    clean_title="interactive_session_$(date +%Y%m%d_%H%M%S)"
  fi

  target_dir="$HOME/.aider-sessions/$repo_name"
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
  # Returns shim dir path on stdout.
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

_plan_cleanup() {
  # Cleanup shim and repo symlink if present
  local shim_dir="${COPILOT_GIT_SHIM:-}"
  local repo_root="${COPILOT_REPO_ROOT:-}"
  if [ -n "$shim_dir" ] && [ -d "$shim_dir" ]; then
    rm -rf "$shim_dir" 2>/dev/null || true
  fi
  if [ -n "$repo_root" ] && [ -L "$repo_root/plan.md" ]; then
    rm -f "$repo_root/plan.md" 2>/dev/null || true
  fi
}

_check_aider_available() {
  if ! command -v aider >/dev/null 2>&1; then
    printf 'ERROR: "aider" CLI not found in PATH. Install or add it to PATH before using these helpers.\n' >&2
    return 1
  fi
  return 0
}

_require_nonempty_prompt() {
  # Usage: _require_nonempty_prompt "Prompt text" varname
  local prompt_text="$1"
  local __result_var="$2"
  local input

  printf '%s' "$prompt_text"
  if ! read -r input; then
    input=""
  fi

  if [ -z "${input:-}" ]; then
    printf 'ERROR: empty prompt provided; aborting.\n' >&2
    return 1
  fi

  printf -v "$__result_var" '%s' "$input"
  return 0
}

# Single linear session starter
_start_session_single_flow() {
  # $1 = chat_mode (ask|architect)
  # $2 = message_prefix
  local chat_mode="$1"
  local message_prefix="$2"
  local repo_root target_dir input_history_file history_file git_shim user_title

  _check_aider_available || return 1

  # user_title must be exported by caller as USER_SESSION_TITLE
  if [ -n "${USER_SESSION_TITLE:-}" ]; then
    user_title="$USER_SESSION_TITLE"
  else
    printf 'ERROR: session title not provided; aborting.\n' >&2
    return 1
  fi

  if [ -z "${user_title:-}" ]; then
    printf 'ERROR: empty prompt provided; aborting.\n' >&2
    return 1
  fi

  repo_root=$(_resolve_repo_root) || return 1
  COPILOT_REPO_ROOT="$repo_root"

  target_dir=$(_prepare_copilot_session_dir "$repo_root") || return 1
  input_history_file="$target_dir/.aider.input.history"

  git_shim=$(_create_git_shim) || return 1
  COPILOT_GIT_SHIM="$git_shim"

  # Ensure cleanup on shell exit or function return
  trap _plan_cleanup EXIT

  history_file=$(_generate_copilot_session_path "$repo_root" "$user_title") || {
    _plan_cleanup
    return 1
  }

  # Single linear execution: message then restore
  pushd "$repo_root" >/dev/null 2>&1 || {
    _plan_cleanup
    return 1
  }

  PATH="$git_shim:$PATH" aider --chat-mode "$chat_mode" --chat-history-file "$history_file" \
    --input-history-file "$input_history_file" \
    --message "${message_prefix}${user_title}" || {
      popd >/dev/null 2>&1 || true
      _plan_cleanup
      return 1
    }

  PATH="$git_shim:$PATH" aider --chat-mode "$chat_mode" --chat-history-file "$history_file" \
    --input-history-file "$input_history_file" \
    --restore-chat-history || {
      popd >/dev/null 2>&1 || true
      _plan_cleanup
      return 1
    }

  popd >/dev/null 2>&1 || true

  # explicit cleanup (trap will also run)
  _plan_cleanup

  # unset exported title
  if [ -n "${USER_SESSION_TITLE:-}" ]; then
    unset USER_SESSION_TITLE 2>/dev/null || true
  fi

  trap - EXIT
  return 0
}

# Public helpers

copilot-ask() {
  local user_title

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

# Restore IFS
IFS="$OLD_IFS"
unset OLD_IFS

# End of script

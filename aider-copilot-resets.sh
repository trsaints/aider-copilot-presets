#!/usr/bin/env bash

# aider-copilot-presets.sh
# Copilot-like ask / agent / plan wrappers around Aider.

# Preserve caller IFS
OLD_IFS="$IFS"
IFS=$'\n\t'

# Character-safe string handling (bash substring ops below) needs a UTF-8
# locale; fall back to one if the caller's shell doesn't set one.
if [ -z "${LC_ALL:-}" ] && [ -z "${LANG:-}" ]; then
  export LC_ALL="C.UTF-8"
fi

_resolve_repo_root() {
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
  local repo_name clean_title len target_dir

  repo_name=$(basename "$repo_root")

  if [ -z "$raw_title" ]; then
    raw_title="interactive_session_$(date +%Y%m%d_%H%M%S)"
  fi

  # Sanitize: replace anything but alnum/space/._- with underscore, collapse spaces
  clean_title=$(printf '%s' "$raw_title" | sed 's/[^[:alnum:][:space:]._-]/_/g' | tr -s ' ' ' ')

  # Trim leading/trailing spaces (bash-native, no subshell)
  clean_title="${clean_title#"${clean_title%%[![:space:]]*}"}"
  clean_title="${clean_title%"${clean_title##*[![:space:]]}"}"

  # Character count via bash parameter expansion (locale-aware, no wc/cut subprocess)
  len=${#clean_title}
  if [ "$len" -gt 96 ]; then
    clean_title="${clean_title:0:96}..."
  fi

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
  touch "$target_dir/.aider.input.history" 2>/dev/null || true

  printf '%s\n' "$target_dir"
}

_prepare_plan_file() {
  # Usage: _prepare_plan_file <repo_root>
  # plan.md must be a REAL file inside repo_root, not a symlink resolving
  # outside it.
  local repo_root="$1"
  local repo_plan gitignore_file

  repo_plan="$repo_root/plan.md"

  if [ -L "$repo_plan" ]; then
    # Migrate a plan.md left over from the older symlink-based design: pull
    # its real content back into the repo, then replace the symlink.
    local old_target
    old_target=$(readlink -f "$repo_plan" 2>/dev/null || true)
    rm -f "$repo_plan"
    if [ -n "$old_target" ] && [ -e "$old_target" ]; then
      cp "$old_target" "$repo_plan"
    else
      touch "$repo_plan"
    fi
  elif [ ! -e "$repo_plan" ]; then
    touch "$repo_plan" 2>/dev/null || return 1
  fi

  gitignore_file="$repo_root/.gitignore"
  if [ -f "$gitignore_file" ]; then
    grep -qxF 'plan.md' "$gitignore_file" 2>/dev/null || printf '\nplan.md\n' >> "$gitignore_file"
  else
    printf 'plan.md\n' > "$gitignore_file" 2>/dev/null || true
  fi

  printf '%s\n' "$repo_plan"
}

_create_git_shim() {
  # Create a temp dir containing a git wrapper that blocks history-altering
  # subcommands. Returns shim dir path on stdout.
  local tmpdir original_git shim
  tmpdir=$(mktemp -d 2>/dev/null) || { tmpdir="/tmp/aider-git-shim-$$"; mkdir -p "$tmpdir" 2>/dev/null || true; }
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
  add|commit|push|reset|rebase|mv|rm|merge|checkout|clean)
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
  # Only clean up the git shim. plan.md is a real, persistent deliverable —
  # it must survive so a later copilot-agent session can read it back.
  local shim_dir="${COPILOT_GIT_SHIM:-}"
  if [ -n "$shim_dir" ] && [ -d "$shim_dir" ]; then
    rm -rf "$shim_dir" 2>/dev/null || true
  fi
}

_print_session_diff_report() {
  # Usage: _print_session_diff_report <repo_root> <label>
  # Runs with the REAL git (called after the shim dir is torn down / from
  # outside the shimmed PATH), so this is never blocked by the shim itself.
  local repo_root="$1" label="$2" status

  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  status=$(git -C "$repo_root" status --porcelain 2>/dev/null)
  printf -- '--- %s: working tree changes ---\n' "$label"
  if [ -z "$status" ]; then
    printf '(none)\n'
  else
    printf '%s\n' "$status"
    git -C "$repo_root" --no-pager diff --stat 2>/dev/null
  fi
  printf -- '---\n'
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

# Optional, opt-in filesystem sandbox using bubblewrap (if installed).
# This does NOT replace a dedicated OS user/group — it's a lighter-weight
# mitigation that doesn't require one-time root setup. 
# Enable with: export AIDER_COPILOT_SANDBOX=1
_maybe_sandboxed_aider() {
  local repo_root="$1" target_dir="$2"; shift 2
  if [ "${AIDER_COPILOT_SANDBOX:-0}" = "1" ] && command -v bwrap >/dev/null 2>&1; then
    bwrap \
      --ro-bind /usr /usr \
      --ro-bind /etc /etc \
      --ro-bind /bin /bin 2>/dev/null \
      --ro-bind /lib /lib 2>/dev/null \
      --ro-bind /lib64 /lib64 2>/dev/null \
      --bind "$repo_root" "$repo_root" \
      --bind "$target_dir" "$target_dir" \
      --proc /proc --dev /dev \
      --unshare-pid --die-with-parent \
      --setenv PATH "$PATH" \
      -- "$@"
  else
    "$@"
  fi
}

# Single linear session starter
_start_session_single_flow() {
  # $1 = chat_mode (ask|code|architect)
  # $2 = message_prefix (final message = "${message_prefix}${user_title}")
  # remaining args = extra aider CLI args, e.g. --file plan.md --read plan.md
  local chat_mode="$1"; shift
  local message_prefix="$1"; shift
  local extra_args=("$@")
  local repo_root target_dir input_history_file history_file git_shim user_title rc

  _check_aider_available || return 1

  if [ -n "${USER_SESSION_TITLE:-}" ]; then
    user_title="$USER_SESSION_TITLE"
  else
    printf 'ERROR: session title not provided; aborting.\n' >&2
    return 1
  fi

  repo_root=$(_resolve_repo_root) || return 1
  COPILOT_REPO_ROOT="$repo_root"

  target_dir=$(_prepare_copilot_session_dir "$repo_root") || return 1
  input_history_file="$target_dir/.aider.input.history"

  git_shim=$(_create_git_shim) || return 1
  COPILOT_GIT_SHIM="$git_shim"
  trap _plan_cleanup EXIT

  history_file=$(_generate_copilot_session_path "$repo_root" "$user_title") || {
    _plan_cleanup
    trap - EXIT
    return 1
  }

  pushd "$repo_root" >/dev/null 2>&1 || {
    _plan_cleanup
    trap - EXIT
    return 1
  }

  # Seed the conversation. --message sends one instruction, applies the
  # reply, then EXITS aider entirely
  PATH="$git_shim:$PATH" _maybe_sandboxed_aider "$repo_root" "$target_dir" \
    aider --chat-mode "$chat_mode" \
      --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      "${extra_args[@]}" \
      --message "${message_prefix}${user_title}"
  rc=$?
  if [ $rc -ne 0 ]; then
    popd >/dev/null 2>&1 || true
    _plan_cleanup
    trap - EXIT
    return 1
  fi

  PATH="$git_shim:$PATH" _maybe_sandboxed_aider "$repo_root" "$target_dir" \
    aider --chat-mode "$chat_mode" \
      --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history \
      "${extra_args[@]}"
  rc=$?

  popd >/dev/null 2>&1 || true
  _plan_cleanup
  trap - EXIT

  # Shim is gone and we're back on the real PATH at this point, so this
  # reads the actual repo state, not anything filtered by the shim.
  _print_session_diff_report "$repo_root" "$chat_mode session"

  if [ -n "${USER_SESSION_TITLE:-}" ]; then
    unset USER_SESSION_TITLE 2>/dev/null || true
  fi

  return $rc
}

# Two-phase plan flow: ask (discuss, zero edit risk by aider's own design)
# then code (single-model write, restricted to plan.md).
_start_plan_flow() {
  local user_title="$1"
  local repo_root target_dir input_history_file history_file git_shim rc

  _check_aider_available || return 1

  repo_root=$(_resolve_repo_root) || return 1
  target_dir=$(_prepare_copilot_session_dir "$repo_root") || return 1
  input_history_file="$target_dir/.aider.input.history"

  git_shim=$(_create_git_shim) || return 1
  COPILOT_GIT_SHIM="$git_shim"
  trap _plan_cleanup EXIT

  history_file=$(_generate_copilot_session_path "$repo_root" "$user_title") || {
    _plan_cleanup
    trap - EXIT
    return 1
  }

  pushd "$repo_root" >/dev/null 2>&1 || {
    _plan_cleanup
    trap - EXIT
    return 1
  }

  # Phase 1 — ask mode: discussion only
  PATH="$git_shim:$PATH" _maybe_sandboxed_aider "$repo_root" "$target_dir" \
    aider --chat-mode ask \
      --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --message "Plan Mode discussion phase. Talk through requirements, approach, tradeoffs, and open questions for: ${user_title}. Do not write final content yet."

  rc=$?; [ $rc -ne 0 ] && { popd >/dev/null; _plan_cleanup; trap - EXIT; return 1; }

  # Phase 2 — architect mode: propose implementation, edits optional
  PATH="$git_shim:$PATH" _maybe_sandboxed_aider "$repo_root" "$target_dir" \
    aider --chat-mode architect \
      --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history \
      --no-auto-accept-architect \
      --message "Based on the discussion above, propose concrete implementation steps. Only apply edits if explicitly approved."

  rc=$?

  # Phase 3 — interactive continuation in architect mode
  PATH="$git_shim:$PATH" _maybe_sandboxed_aider "$repo_root" "$target_dir" \
    aider --chat-mode architect \
      --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history \
      --no-auto-accept-architect

  rc=$?

  popd >/dev/null 2>&1 || true
  _plan_cleanup
  trap - EXIT

  _print_session_diff_report "$repo_root" "plan session"
  return $rc
}

# --- Public helpers ---

copilot-ask() {
  local user_title

  if [ $# -eq 0 ]; then
    if ! _require_nonempty_prompt '💬 Enter a topic/title for this Ask Session: ' user_title; then
      return 1
    fi
  else
    user_title="$*"
  fi

  export USER_SESSION_TITLE="$user_title"

  _start_session_single_flow ask "User topic: " || return 1
  return 0
}

copilot-agent() {
  local user_title repo_root extra_args=()

  if [ $# -eq 0 ]; then
    if ! _require_nonempty_prompt '🤖 Enter the feature/bug name for this Agent Session: ' user_title; then
      return 1
    fi
  else
    user_title="$*"
  fi

  export USER_SESSION_TITLE="$user_title"
  repo_root=$(_resolve_repo_root)

  # If a plan.md exists (from copilot-plan), hand it to the agent as
  # read-only reference context — mirrors "start agent mode using the plan".
  if [ -f "$repo_root/plan.md" ]; then
    extra_args=(--read plan.md)
  fi

  # Broad edit scope here (no --file restriction), so require an explicit
  # confirmation before each architect edit is applied.
  extra_args+=(--no-auto-accept-architect)

  _start_session_single_flow architect "Agent objective: " "${extra_args[@]}" || return 1
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
  fi

  _start_plan_flow "$user_title" || return 1
  return 0
}

# Restore IFS
IFS="$OLD_IFS"
unset OLD_IFS

# End of script
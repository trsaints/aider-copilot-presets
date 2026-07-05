#!/usr/bin/env bash

# ---------------------------------------------------------------------
# Dynamic Copilot-Style Session Manager for Aider
# ---------------------------------------------------------------------

_resolve_repo_root() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git rev-parse --show-toplevel | xargs realpath
  else
    realpath "$PWD"
  fi
}

_generate_copilot_session_path() {
  # Usage: _generate_copilot_session_path <repo_root> <raw_title>
  local repo_root="$1"
  local raw_title="$2"
  local repo_name

  repo_name=$(basename "$repo_root")

  if [ -z "$raw_title" ]; then
    raw_title="interactive_session_$(date +%Y%m%d_%H%M%S)"
  fi

  local clean_title
  clean_title=$(echo "$raw_title" | cut -c1-96 | sed 's/[^a-zA-Z0-9 _-]/_/g')

  if [ ${#raw_title} -gt 96 ]; then
    clean_title="${clean_title}..."
  fi

  local target_dir="$HOME/.aider-sessions/$repo_name"
  mkdir -p "$target_dir"

  printf '%s\n' "$target_dir/$clean_title.md"
}

_prepare_copilot_session_dir() {
  # Usage: _prepare_copilot_session_dir <repo_root>
  local repo_root="$1"
  local repo_name target_dir

  repo_name=$(basename "$repo_root")
  target_dir="$HOME/.aider-sessions/$repo_name"

  mkdir -p "$target_dir"
  touch "$target_dir/.aider.input.history" "$target_dir/cache.db"

  ln -sf "$target_dir/.aider.input.history" "$repo_root/.aider.input.history"
  ln -sf "$target_dir/cache.db" "$repo_root/cache.db"

  printf '%s\n' "$target_dir"
}

_generate_plan_filepath() {
  # Usage: _generate_plan_filepath <repo_root>
  local repo_root="$1"
  local repo_name timestamp plan_filepath

  repo_name=$(basename "$repo_root")
  timestamp=$(date +%Y%m%d_%H%M%S)
  plan_filepath="/tmp/aider-plan-${repo_name}-${timestamp}.md"

  printf '%s\n' "$plan_filepath"
}

_create_git_shim() {
  # Create a temp dir containing a git wrapper that blocks dangerous subcommands.
  local tmpdir original_git shim
  tmpdir=$(mktemp -d)
  original_git=$(command -v git || true)
  shim="$tmpdir/git"

  cat >"$shim" <<'GITSH'
#!/usr/bin/env bash
original_git="__ORIGINAL_GIT__"
cmd="$1"
case "$cmd" in
  add|commit|push|reset|rebase|mv|rm|merge|checkout)
    echo "ERROR: git $cmd is blocked by copilot presets to prevent auto-commits and repo modifications." >&2
    exit 1
    ;;
  *)
    exec "$original_git" "$@"
    ;;
esac
GITSH

  sed -i "s|__ORIGINAL_GIT__|$original_git|g" "$shim"
  chmod +x "$shim"

  printf '%s\n' "$tmpdir"
}

_plan_cleanup() {
  rm -f "$1/plan.md" || true
  rm -rf "$2" || true
}

# 1. ASK MODE PRESET
copilot-ask() {
  local repo_root target_dir input_history_file history_file git_shim
  repo_root=$(_resolve_repo_root)
  repo_root=$(realpath "$repo_root")
  target_dir=$(_prepare_copilot_session_dir "$repo_root")
  input_history_file="$target_dir/.aider.input.history"

  git_shim=$(_create_git_shim)

  if [ $# -eq 0 ]; then
    echo -n "💬 Enter a topic/title for this Ask Session: "
    read -r user_title
    history_file=$(_generate_copilot_session_path "$repo_root" "$user_title")
    pushd "$repo_root" >/dev/null || return 1
    PATH="$git_shim:$PATH" aider --no-auto-commits --no-dirty-commits --chat-mode ask --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
    popd >/dev/null || return 1
  else
    history_file=$(_generate_copilot_session_path "$repo_root" "$*")
    pushd "$repo_root" >/dev/null || return 1
    PATH="$git_shim:$PATH" aider --no-auto-commits --no-dirty-commits --chat-mode ask --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --message "$*" && \
    PATH="$git_shim:$PATH" aider --no-auto-commits --no-dirty-commits --chat-mode ask --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
    popd >/dev/null || return 1
  fi

  rm -rf "$git_shim"
}

# 2. AGENT MODE PRESET
copilot-agent() {
  local repo_root target_dir input_history_file history_file git_shim
  repo_root=$(_resolve_repo_root)
  repo_root=$(realpath "$repo_root")
  target_dir=$(_prepare_copilot_session_dir "$repo_root")
  input_history_file="$target_dir/.aider.input.history"

  git_shim=$(_create_git_shim)

  if [ $# -eq 0 ]; then
    echo -n "🤖 Enter the feature/bug name for this Agent Session: "
    read -r user_title
    history_file=$(_generate_copilot_session_path "$repo_root" "$user_title")
    pushd "$repo_root" >/dev/null || return 1
    PATH="$git_shim:$PATH" aider --no-auto-commits --no-dirty-commits --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
    popd >/dev/null || return 1
  else
    history_file=$(_generate_copilot_session_path "$repo_root" "$*")
    pushd "$repo_root" >/dev/null || return 1
    PATH="$git_shim:$PATH" aider --no-auto-commits --no-dirty-commits --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --message "$*" && \
    PATH="$git_shim:$PATH" aider --no-auto-commits --no-dirty-commits --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
    popd >/dev/null || return 1
  fi

  rm -rf "$git_shim"
}

# 3. PLAN MODE PRESET
copilot-plan() {
  local repo_root target_dir input_history_file history_file plan_filepath git_shim
  repo_root=$(_resolve_repo_root)
  repo_root=$(realpath "$repo_root")
  target_dir=$(_prepare_copilot_session_dir "$repo_root")
  input_history_file="$target_dir/.aider.input.history"
  # Place plan file in the session directory (never inside the repo)
  plan_filepath="$target_dir/plan.md"
  local plan_created=false
  if [ ! -e "$plan_filepath" ]; then
    touch "$plan_filepath"
    plan_created=true
  fi

  git_shim=$(_create_git_shim)

  # Ensure cleanup on exit (removes shim dir)
  # create a symlink in the repo that points to the session plan file (keeps artifact outside repo)
  ln -sf "$plan_filepath" "$repo_root/plan.md"

  trap '_plan_cleanup "'$repo_root'" "'$git_shim'"' EXIT

  pushd "$repo_root" >/dev/null || return 1

  if [ $# -eq 0 ]; then
    echo -n "📝 Enter the planning objective for this Session: "
    read -r user_title
    history_file=$(_generate_copilot_session_path "$repo_root" "$user_title")
    PATH="$git_shim:$PATH" aider --no-auto-commits --no-dirty-commits --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --message "You are in Plan Mode. Create or add plan.md to the chat. Your sole write target is plan.md. Establish your architecture strategy here. Use /add plan.md if needed." && \
    PATH="$git_shim:$PATH" aider --no-auto-commits --no-dirty-commits --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
  else
    history_file=$(_generate_copilot_session_path "$repo_root" "$*")
    PATH="$git_shim:$PATH" aider --no-auto-commits --no-dirty-commits --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --message "You are in Plan Mode. Add plan.md to the chat if not present. Update plan.md regarding: $*" && \
    PATH="$git_shim:$PATH" aider --no-auto-commits --no-dirty-commits --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
  fi

  popd >/dev/null || return 1

  # Explicit cleanup (trap also handles failures)
  # remove only the symlink in the repo root; preserve session plan file in $target_dir
  rm -f "$repo_root/plan.md" || true
  _plan_cleanup "$repo_root" "$git_shim"
  trap - EXIT
}

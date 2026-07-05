#!/usr/bin/env bash

# ---------------------------------------------------------------------
# Dynamic Copilot-Style Session Manager for Aider
# ---------------------------------------------------------------------

_resolve_repo_root() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git rev-parse --show-toplevel
  else
    printf '%s\n' "$PWD"
  fi
}

_generate_copilot_session_path() {
  local raw_title="$1"
  local repo_name

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo_name=$(basename "$(git rev-parse --show-toplevel)")
  else
    repo_name=$(basename "$PWD")
  fi

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
  local repo_root repo_name target_dir

  repo_root=$(_resolve_repo_root)
  repo_name=$(basename "$repo_root")
  target_dir="$HOME/.aider-sessions/$repo_name"

  mkdir -p "$target_dir"
  touch "$target_dir/.aider.input.history" "$target_dir/cache.db"

  ln -sf "$target_dir/.aider.input.history" "$repo_root/.aider.input.history"
  ln -sf "$target_dir/cache.db" "$repo_root/cache.db"

  printf '%s\n' "$target_dir"
}

_generate_plan_filepath() {
  local repo_root repo_name timestamp plan_filepath

  repo_root=$(_resolve_repo_root)
  repo_name=$(basename "$repo_root")
  timestamp=$(date +%Y%m%d_%H%M%S)
  plan_filepath="/tmp/aider-plan-${repo_name}-${timestamp}.md"

  printf '%s\n' "$plan_filepath"
}

# 1. ASK MODE PRESET
copilot-ask() {
  local repo_root target_dir input_history_file history_file
  repo_root=$(_resolve_repo_root)
  target_dir=$(_prepare_copilot_session_dir)
  input_history_file="$target_dir/.aider.input.history"

  if [ $# -eq 0 ]; then
    echo -n "💬 Enter a topic/title for this Ask Session: "
    read -r user_title
    history_file=$(_generate_copilot_session_path "$user_title")
    pushd "$repo_root" >/dev/null || return 1
    aider --chat-mode ask --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
    popd >/dev/null || return 1
  else
    history_file=$(_generate_copilot_session_path "$*")
    pushd "$repo_root" >/dev/null || return 1
    aider --chat-mode ask --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --message "$*" && \
    aider --chat-mode ask --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
    popd >/dev/null || return 1
  fi
}

# 2. AGENT MODE PRESET
copilot-agent() {
  local repo_root target_dir input_history_file history_file
  repo_root=$(_resolve_repo_root)
  target_dir=$(_prepare_copilot_session_dir)
  input_history_file="$target_dir/.aider.input.history"

  if [ $# -eq 0 ]; then
    echo -n "🤖 Enter the feature/bug name for this Agent Session: "
    read -r user_title
    history_file=$(_generate_copilot_session_path "$user_title")
    pushd "$repo_root" >/dev/null || return 1
    aider --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
    popd >/dev/null || return 1
  else
    history_file=$(_generate_copilot_session_path "$*")
    pushd "$repo_root" >/dev/null || return 1
    aider --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --message "$*" && \
    aider --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
    popd >/dev/null || return 1
  fi
}

# 3. PLAN MODE PRESET
copilot-plan() {
  local repo_root target_dir input_history_file history_file plan_filepath
  repo_root=$(_resolve_repo_root)
  target_dir=$(_prepare_copilot_session_dir)
  input_history_file="$target_dir/.aider.input.history"
  plan_filepath=$(_generate_plan_filepath)

  # Create plan file in /tmp
  touch "$plan_filepath"

  # Create symlink from repo root to /tmp plan file
  ln -sf "$plan_filepath" "$repo_root/plan.md"

  pushd "$repo_root" >/dev/null || return 1

  if [ $# -eq 0 ]; then
    echo -n "📝 Enter the planning objective for this Session: "
    read -r user_title
    history_file=$(_generate_copilot_session_path "$user_title")
    aider --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --message "You are in Plan Mode. Create or add plan.md to the chat. Your sole write target is plan.md. Establish your architecture strategy here. Use /add plan.md if needed." && \
    aider --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
  else
    history_file=$(_generate_copilot_session_path "$*")
    aider --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --message "You are in Plan Mode. Add plan.md to the chat if not present. Update plan.md regarding: $*" && \
    aider --chat-mode architect --chat-history-file "$history_file" \
      --input-history-file "$input_history_file" \
      --restore-chat-history
  fi

  popd >/dev/null || return 1
  
  # Clean up symlink after session ends
  rm -f "$repo_root/plan.md"
}

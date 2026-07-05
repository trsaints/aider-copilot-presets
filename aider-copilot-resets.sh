#!/usr/bin/env bash

# ---------------------------------------------------------------------
# Dynamic Copilot-Style Session Manager for Aider
# ---------------------------------------------------------------------

_generate_copilot_session_path() {
  local raw_title="$1"
  local repo_name

  # 1. Resolve current Git repository name (fallback to directory name)
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo_name=$(basename "$(git rev-parse --show-toplevel)")
  else
    repo_name=$(basename "$PWD")
  fi

  # 2. Fallback to a timestamp if no initial prompt or title is given
  if [ -z "$raw_title" ]; then
    raw_title="interactive_session_$(date +%Y%m%d_%H%M%S)"
  fi

  # 3. Truncate to first 96 characters and sanitize unsafe filename characters
  local clean_title
  clean_title=$(echo "$raw_title" | cut -c1-96 | sed 's/[^a-zA-Z0-9 _-]/_/g')

  # 4. Append trailing dots if the original prompt was truncated
  if [ ${#raw_title} -gt 96 ]; then
    clean_title="${clean_title}..."
  fi

  # 5. Build and ensure the target directory structure exists
  local target_dir="$HOME/.aider-sessions/$repo_name"
  mkdir -p "$target_dir"

  echo "$target_dir/$clean_title.md"
}

# 1. ASK MODE PRESET
copilot-ask() {
  if [ $# -eq 0 ]; then
    # Interactive launch: Ask for a quick context title first
    echo -n "💬 Enter a topic/title for this Ask Session: "
    read -r user_title
    local history_file
    history_file=$(_generate_copilot_session_path "$user_title")
    aider --chat-mode ask --chat-history-file "$history_file"
  else
    # One-shot launch: Use the prompt directly to name the file
    local history_file
    history_file=$(_generate_copilot_session_path "$*")
    aider --chat-mode ask --chat-history-file "$history_file" --message "$*"
  fi
}

# 2. AGENT MODE PRESET
copilot-agent() {
  if [ $# -eq 0 ]; then
    echo -n "🤖 Enter the feature/bug name for this Agent Session: "
    read -r user_title
    local history_file
    history_file=$(_generate_copilot_session_path "$user_title")
    aider --chat-mode architect --chat-history-file "$history_file"
  else
    local history_file
    history_file=$(_generate_copilot_session_path "$*")
    aider --chat-mode architect --chat-history-file "$history_file" --message "$*"
  fi
}

# 3. PLAN MODE PRESET
copilot-plan() {
  touch plan.md
  if [ $# -eq 0 ]; then
    echo -n "📝 Enter the planning objective for this Session: "
    read -r user_title
    local history_file
    history_file=$(_generate_copilot_session_path "$user_title")
    aider plan.md --chat-mode code --chat-history-file "$history_file" \
      --message "You are in Plan Mode. Your sole write target is plan.md. Establish your architecture strategy here."
  else
    local history_file
    history_file=$(_generate_copilot_session_path "$*")
    aider plan.md --chat-mode code --chat-history-file "$history_file" \
      --message "Update plan.md regarding: $*"
  fi
}

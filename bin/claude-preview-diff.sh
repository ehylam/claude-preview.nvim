#!/usr/bin/env bash
# claude-preview-diff.sh — PreToolUse hook for Claude Code
# Intercepts Edit/Write/MultiEdit, computes proposed file content,
# and sends a diff preview to Neovim via RPC before the user accepts.

set -Eeuo pipefail

# If anything fails, allow the edit through — preview is best-effort
trap 'printf "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"Preview unavailable.\"}}\n"; exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read the full hook JSON from stdin
INPUT="$(cat)"

# Extract fields (separate calls to avoid eval injection)
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name')"
CWD="$(echo "$INPUT" | jq -r '.cwd')"

# Discover Neovim socket (prefer instance whose cwd matches project) and load RPC helpers
source "$SCRIPT_DIR/nvim-socket.sh" "$CWD" 2>/dev/null || true
source "$SCRIPT_DIR/nvim-send.sh"

HAS_NVIM=true
if [[ -z "${NVIM_SOCKET:-}" ]]; then
  HAS_NVIM=false
fi

TMPDIR="${TMPDIR:-/tmp}"
ORIG_FILE="$TMPDIR/claude-diff-original"
PROP_FILE="$TMPDIR/claude-diff-proposed"

# Prefer standalone lua over nvim --headless for scripts that don't need Neovim APIs
LUA_CMD="nvim --headless -l"
if command -v lua5.4 &>/dev/null; then
  LUA_CMD="lua5.4"
elif command -v lua &>/dev/null; then
  LUA_CMD="lua"
fi

# --- Compute original and proposed file content ---

case "$TOOL_NAME" in
  Edit)
    # Write strings to temp files to preserve trailing newlines (bash $() strips them)
    OLD_STRING_FILE="$TMPDIR/claude-diff-old-string"
    NEW_STRING_FILE="$TMPDIR/claude-diff-new-string"
    echo "$INPUT" | jq -j '.tool_input.old_string' > "$OLD_STRING_FILE"
    echo "$INPUT" | jq -j '.tool_input.new_string' > "$NEW_STRING_FILE"

    if [[ -f "$FILE_PATH" ]]; then
      cp "$FILE_PATH" "$ORIG_FILE"
    else
      > "$ORIG_FILE"
    fi

    $LUA_CMD "$SCRIPT_DIR/apply-edit.lua" "$FILE_PATH" "$OLD_STRING_FILE" "$NEW_STRING_FILE" "$REPLACE_ALL" "$PROP_FILE" --from-files
    ;;

  Write)
    if [[ -f "$FILE_PATH" ]]; then
      cp "$FILE_PATH" "$ORIG_FILE"
    else
      > "$ORIG_FILE"
    fi

    # Write content directly to temp file to preserve trailing newlines
    echo "$INPUT" | jq -j '.tool_input.content' > "$PROP_FILE"
    ;;

  MultiEdit)
    if [[ -f "$FILE_PATH" ]]; then
      cp "$FILE_PATH" "$ORIG_FILE"
    else
      > "$ORIG_FILE"
    fi

    # MultiEdit uses vim.json.decode, so it needs nvim --headless
    nvim --headless -l "$SCRIPT_DIR/apply-multi-edit.lua" "$INPUT" "$PROP_FILE"
    ;;

  Bash)
    COMMAND="$(echo "$INPUT" | jq -r '.tool_input.command')"

    # Detect rm commands: split on command separators and check each sub-command
    detect_rm_paths() {
      local cmd="$1"
      cmd="$(echo "$cmd" | sed 's/^[[:space:]]*//')"
      if echo "$cmd" | grep -qE '^(sudo[[:space:]]+)?rm[[:space:]]'; then
        echo "$cmd" | sed -E 's/^(sudo[[:space:]]+)?rm[[:space:]]+//' \
                     | tr ' ' '\n' \
                     | grep -vE '^-' \
                     | while read -r p; do
                         [[ -z "$p" ]] && continue
                         [[ "$p" != /* ]] && echo "$CWD/$p" || echo "$p"
                       done
      fi
    }

    RM_PATHS=""
    while IFS= read -r subcmd; do
      while IFS= read -r path; do
        [[ -n "$path" ]] && RM_PATHS="$RM_PATHS $path"
      done < <(detect_rm_paths "$subcmd")
    done < <(echo "$COMMAND" | sed 's/[;&|]\{1,2\}/\n/g')

    RM_PATHS="$(echo "$RM_PATHS" | xargs)"
    if [[ -z "$RM_PATHS" ]]; then
      exit 0
    fi

    # Mark each path as deleted in neo-tree (batched into single RPC call)
    if [[ "$HAS_NVIM" == "true" ]]; then
      LUA_BATCH=""
      for path in $RM_PATHS; do
        PATH_ESC="$(escape_lua "$path")"
        LUA_BATCH="${LUA_BATCH}require('claude-preview.changes').set('$PATH_ESC', 'deleted'); "
      done
      FIRST_ESC="$(escape_lua "$(echo "$RM_PATHS" | awk '{print $1}')")"
      LUA_BATCH="${LUA_BATCH}pcall(function() require('claude-preview.neo_tree').refresh() end); "
      LUA_BATCH="${LUA_BATCH}vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').reveal('$FIRST_ESC') end) end, 300)"
      nvim_send "$LUA_BATCH" || true
    fi
    exit 0
    ;;

  *)
    exit 0
    ;;
esac

# --- Send diff to Neovim ---

DISPLAY_NAME="${FILE_PATH#"$CWD/"}"

if [[ "$HAS_NVIM" == "true" ]]; then
  ORIG_ESC="$(escape_lua "$ORIG_FILE")"
  PROP_ESC="$(escape_lua "$PROP_FILE")"
  DISPLAY_ESC="$(escape_lua "$DISPLAY_NAME")"
  FILE_PATH_ESC="$(escape_lua "$FILE_PATH")"

  if [[ -f "$FILE_PATH" ]]; then
    CHANGE_STATUS="modified"
  else
    CHANGE_STATUS="created"
  fi

  # Batch all nvim RPC calls into a single command
  if [[ "$CHANGE_STATUS" == "modified" ]]; then
    REVEAL_ESC="$FILE_PATH_ESC"
  else
    REVEAL_DIR="$(dirname "$FILE_PATH")"
    while [[ ! -d "$REVEAL_DIR" && "$REVEAL_DIR" != "/" ]]; do
      REVEAL_DIR="$(dirname "$REVEAL_DIR")"
    done
    REVEAL_TARGET="$(find "$REVEAL_DIR" -maxdepth 1 -type f 2>/dev/null | head -1)"
    [[ -z "$REVEAL_TARGET" ]] && REVEAL_TARGET="$REVEAL_DIR"
    REVEAL_ESC="$(escape_lua "$REVEAL_TARGET")"
  fi

  nvim_send "require('claude-preview.changes').set('$FILE_PATH_ESC', '$CHANGE_STATUS'); pcall(function() require('claude-preview.neo_tree').refresh() end); vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').reveal('$REVEAL_ESC') end) end, 300); require('claude-preview.diff').show_diff('$ORIG_ESC', '$PROP_ESC', '$DISPLAY_ESC')" || true
fi

# --- Always ask for user confirmation ---

if [[ "$HAS_NVIM" == "true" ]]; then
  REASON="Diff preview sent to Neovim. Review before accepting."
else
  REASON="Neovim not running. Review the diff in CLI before accepting."
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$REASON"

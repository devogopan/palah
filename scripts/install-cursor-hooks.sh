#!/bin/bash
# Installs Palah Cursor hooks to ~/.cursor/
# Run once after cloning, or after updating config/cursor/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_CURSOR="$SCRIPT_DIR/../config/cursor"
CURSOR_DIR="$HOME/.cursor"
HOOKS_SCRIPT_DIR="$CURSOR_DIR/hooks"

# Create dirs
mkdir -p "$HOOKS_SCRIPT_DIR"

# Deploy hook script
cp "$REPO_CURSOR/hooks/palah-hook.sh" "$HOOKS_SCRIPT_DIR/palah-hook.sh"
chmod +x "$HOOKS_SCRIPT_DIR/palah-hook.sh"

# Deploy hooks.json with the real path substituted in
sed "s|\$PALAH_HOOKS_DIR|$HOOKS_SCRIPT_DIR|g" \
  "$REPO_CURSOR/hooks.json" > "$CURSOR_DIR/hooks.json"

echo "Palah Cursor hooks installed."
echo "  hooks.json  → $CURSOR_DIR/hooks.json"
echo "  hook script → $HOOKS_SCRIPT_DIR/palah-hook.sh"
echo "Restart Cursor to activate."

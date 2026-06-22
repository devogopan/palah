#!/bin/bash
# Installs Palah Claude Code hooks to ~/.claude/
# Merges hooks into ~/.claude/settings.json without touching existing keys.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_CLAUDE="$SCRIPT_DIR/../config/claude"
CLAUDE_DIR="$HOME/.claude"
HOOKS_SCRIPT_DIR="$CLAUDE_DIR/hooks"

mkdir -p "$HOOKS_SCRIPT_DIR"

# Deploy hook script
cp "$REPO_CLAUDE/hooks/palah-hook.sh" "$HOOKS_SCRIPT_DIR/palah-hook.sh"
chmod +x "$HOOKS_SCRIPT_DIR/palah-hook.sh"

# Merge hooks into settings.json with real path substituted in
python3 - <<EOF
import json, re

settings_path = '$CLAUDE_DIR/settings.json'
hooks_src_path = '$REPO_CLAUDE/hooks.json'
hooks_script_dir = '$HOOKS_SCRIPT_DIR'

try:
    with open(settings_path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}

with open(hooks_src_path) as f:
    src_text = f.read().replace('\$PALAH_CLAUDE_HOOKS_DIR', hooks_script_dir)
    src = json.loads(src_text)

settings['hooks'] = src['hooks']

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')

print(f'Palah Claude Code hooks installed.')
print(f'  settings.json → {settings_path}')
print(f'  hook script   → {hooks_script_dir}/palah-hook.sh')
print(f'Restart any running Claude Code sessions to activate.')
EOF

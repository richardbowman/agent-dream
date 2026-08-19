#!/usr/bin/env bash
# install.sh — one-command setup for agent-dream
# Usage: bash install.sh

set -e

SKILL_DIR="$HOME/.claude/skills/dream"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
TRIGGER_LINE="| Consolidate memory, mine conversation logs for friction/feedback, run /dream | \`dream\` |"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SOURCE="$SCRIPT_DIR/skills/dream/SKILL.md"
SKILL_URL="https://raw.githubusercontent.com/richardbowman/agent-dream/main/skills/dream/SKILL.md"

echo ""
echo "Installing agent-dream skill..."
echo ""

# 1. Install skill file
mkdir -p "$SKILL_DIR"
# When piped via curl | bash, the repository skill file won't be present, so
# download it from GitHub directly instead.
if [ -f "$SKILL_SOURCE" ]; then
    cp "$SKILL_SOURCE" "$SKILL_DIR/SKILL.md"
else
    curl -fsSL "$SKILL_URL" -o "$SKILL_DIR/SKILL.md"
fi
echo "✓ Skill installed to $SKILL_DIR/SKILL.md"

# 2. Wire into CLAUDE.md if it exists
if [ -f "$CLAUDE_MD" ]; then
    if grep -q "dream" "$CLAUDE_MD" 2>/dev/null; then
        echo "✓ CLAUDE.md already references the dream skill — no changes needed"
    else
        # Look for the end of the skills table and append before it
        if grep -q "^| " "$CLAUDE_MD"; then
            # Find last table row and append after it
            python3 << PYEOF
import re

with open("$CLAUDE_MD", "r") as f:
    content = f.read()

trigger = "$TRIGGER_LINE"

# Find the last line that looks like a table row in the skills section
lines = content.split("\n")
last_table_idx = -1
for i, line in enumerate(lines):
    if line.startswith("| ") and "|" in line[2:]:
        last_table_idx = i

if last_table_idx >= 0:
    lines.insert(last_table_idx + 1, trigger)
    with open("$CLAUDE_MD", "w") as f:
        f.write("\n".join(lines))
    print("✓ Added dream trigger to CLAUDE.md skills table")
else:
    print("⚠  Could not find skills table in CLAUDE.md — add this line manually:")
    print(f"   {trigger}")
PYEOF
        else
            echo "⚠  CLAUDE.md exists but has no skills table. Add this line manually:"
            echo "   $TRIGGER_LINE"
        fi
    fi
else
    echo ""
    echo "ℹ  No CLAUDE.md found at $CLAUDE_MD"
    echo "   To register the skill trigger, add this line to your skills table:"
    echo "   $TRIGGER_LINE"
fi

echo ""
echo "All done! Start a new Claude Code session and run /dream"
echo ""

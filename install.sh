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
            CLAUDE_MD="$CLAUDE_MD" TRIGGER="$TRIGGER_LINE" node --input-type=module << 'JSEOF'
import fs from "node:fs";

const file = process.env.CLAUDE_MD;
const trigger = process.env.TRIGGER;
const lines = fs.readFileSync(file, "utf8").split("\n");

// Find the last line that looks like a table row in the skills section
let last = -1;
lines.forEach((l, i) => { if (l.startsWith("| ") && l.slice(2).includes("|")) last = i; });

if (last >= 0) {
  lines.splice(last + 1, 0, trigger);
  fs.writeFileSync(file, lines.join("\n"));
  console.log("✓ Added dream trigger to CLAUDE.md skills table");
} else {
  console.log("⚠  Could not find skills table in CLAUDE.md — add this line manually:");
  console.log(`   ${trigger}`);
}
JSEOF
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

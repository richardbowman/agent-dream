# agent-dream

A Claude Code skill that mines your own conversation history to find mistakes, corrections, and stated preferences — then automatically writes memory rules to fix them.

Inspired by Anthropic's unreleased auto-dream feature. Extended with a **friction mining** phase that turns your past frustrations into structured, persistent feedback.

## What it does

Claude Code stores every conversation as a `.jsonl` file in `~/.claude/projects/`. This skill scans those logs for signals that a human would normally just forget:

- Direct corrections ("no, actually…", "wrong", "that's not what I wanted")
- Explicit rule declarations ("from now on always…", "never do X again")  
- Repeated frustrations across sessions (same mistake, different day)
- Moments where you re-explained something you'd already said

It cross-references those signals against your existing memory files, discards noise, and writes new `feedback_*.md` rules — or reinforces existing rules that are still being violated.

## First run results (real numbers)

- **676 conversations** scanned
- **145 friction signals** identified
- **90 praise signals** captured (to protect what's working)
- **4 new feedback rules** written automatically
- **2 existing rules** reinforced (still being violated)

The strongest pattern found: Claude kept ignoring its own skills toolkit. Real quotes surfaced from past sessions:

> *"This has been happening over and over again."*  
> *"It took us so many steps — I thought we'd invested in making a skill, but you obviously never used it."*  
> *"NO WRONG, use the skill for bootstrapping."*

Then it wrote a new memory rule reinforcing that behavior — which loads in every future session.

## The loop

```
1. Claude makes a mistake
2. You correct it ("no," "wrong," "from now on...")
3. /dream scans those logs and finds the pattern
4. A new feedback_*.md rule is written
5. Future sessions load that rule — mistake doesn't recur
```

Not AGI. Log parsing + structured memory writing. But the practical effect is an AI that improves from your actual usage history, not just training data.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/richardbowman/agent-dream/main/install.sh | bash
```

That's it. The installer:
1. Copies `skills/dream/SKILL.md` to `~/.claude/skills/dream/`
2. Adds the trigger line to your `~/.claude/CLAUDE.md` skills table (if you have one)

Then start a new Claude Code session and run:

```
/dream
```

## Manual install

If you prefer not to pipe to bash:

```bash
git clone https://github.com/richardbowman/agent-dream
cd agent-dream
bash install.sh
```

Or fully manual — copy `skills/dream/SKILL.md` to `~/.claude/skills/dream/SKILL.md` and add this line to your skills table in `~/.claude/CLAUDE.md`:

```
| Consolidate memory, mine conversation logs for friction/feedback, run /dream | `dream` |
```

## How it works

The skill runs 6 phases:

1. **ORIENT** — reads `~/.claude/dream-last-run` and all existing memory files
2. **FRICTION SCAN** — Node/TypeScript script extracts user messages matching ~25 friction patterns across all `.jsonl` logs since the last run; also captures prior assistant context so Claude understands what triggered each correction
3. **PATTERN ANALYSIS** — Claude reasons through the signals: cross-references against existing rules, discards noise, clusters new patterns
4. **MEMORY UPDATE** — writes new `feedback_*.md` files, reinforces violated rules, updates `MEMORY.md` index
5. **SESSION REPORT** — saves a dated session report to your Obsidian vault (`~/.claude/dream-obsidian-vault`), a custom directory (`~/.claude/dream-report-dir`), or `~/.claude/dream-reports/` as a fallback
6. **STAMP** — writes completion timestamp to `~/.claude/dream-last-run`

## Memory file format

New rules are written in this format, matching the standard Claude Code memory convention:

```markdown
---
name: Run commands autonomously
description: User wants Claude to run shell commands directly rather than suggesting they run them
type: feedback
---

Just run commands — don't suggest the user run them in their terminal.

**Why:** User explicitly asked to stop being prompted to run commands Claude can execute itself.

**How to apply:** Whenever a shell command is needed, run it with the Bash tool directly.
```

## Requirements

- Claude Code v2.1.59+
- Node 22.18+ (runs the scan script natively, no extra packages)
- No other dependencies

## Credits

Friction mining phase by [@richardbowman](https://github.com/richardbowman).  
Memory consolidation approach inspired by [grandamenium/dream-skill](https://github.com/grandamenium/dream-skill).

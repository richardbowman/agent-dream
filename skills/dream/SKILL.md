---
name: dream
description: Memory consolidation + friction mining for Claude Code. Scans recent conversation logs to surface feedback opportunities, updates memory files, and keeps MEMORY.md lean. Run when the user invokes /dream or after a Stop hook flags 24h since last run.
---

# Dream — Memory Consolidation & Friction Mining

Modeled on Anthropic's unreleased auto-dream feature, extended with a friction-mining phase that mines conversation logs for moments where the user expressed frustration, corrected a mistake, or stated a preference — then turns those signals into new `feedback_*.md` memory files.

**Run time:** ~2-4 minutes. Run all phases in order, never skip.

---

## State files

| Path | Purpose |
|---|---|
| `~/.claude/dream-last-run` | ISO-8601 UTC timestamp of last completed dream |
| `~/.claude/projects/<project-slug>/memory/` | Per-project memory (feedback rules, project context) |

---

## Phase 1: ORIENT

Read current state before doing anything else.

```bash
# Last run timestamp
LAST_RUN=$(cat ~/.claude/dream-last-run 2>/dev/null || echo "never (defaulting to 30 days ago)")
echo "Last dream: $LAST_RUN"

# Count conversation files
find ~/.claude/projects -name "*.jsonl" | wc -l

# List existing feedback files across all project memory dirs
find ~/.claude/projects -path "*/memory/feedback_*.md" 2>/dev/null
```

Read all existing `MEMORY.md` files and `feedback_*.md` files so you know what's already captured before writing anything new.

---

## Phase 2: FRICTION SCAN

Run this Python script via Bash to extract user messages that signal frustration, corrections, or stated preferences. This is the core of what makes this skill different from standard memory consolidation.

```bash
python3 << 'PYEOF'
import json, glob, os, re
from datetime import datetime, timezone, timedelta

LAST_RUN_FILE = os.path.expanduser("~/.claude/dream-last-run")
LOGS_DIR = os.path.expanduser("~/.claude/projects")

# Determine scan window
try:
    with open(LAST_RUN_FILE) as f:
        raw = f.read().strip()
    last_run = datetime.fromisoformat(raw.replace('Z', '+00:00'))
except Exception:
    last_run = datetime.now(timezone.utc) - timedelta(days=30)

print(f"Scanning logs since: {last_run.isoformat()}\n")

# --- Friction signal patterns ---
FRICTION_PATTERNS = [
    # Direct corrections
    r"\bno[,\.!]\s", r"\bnope\b", r"\bwrong\b", r"\bincorrect\b",
    r"\bactually[,\.]", r"\bwait[,\.]", r"\bhold on\b",
    r"that'?s not", r"not what i", r"didn'?t want", r"don'?t want",
    r"why did you", r"why are you",
    # Frustration
    r"\bugh\b", r"\bargh\b", r"\bffs\b",
    r"you keep", r"again you", r"still (doing|not|wrong)",
    r"i (told|said|asked) you",
    # Redirects
    r"\bstop (doing|that|this)\b", r"never mind", r"nevermind",
    r"forget (it|that|this)", r"revert (that|this|it)",
    r"please don'?t", r"don'?t do that",
    # Explicit rule declarations (high-value signals)
    r"from now on", r"always\b.{0,30}(do|use|run|check|make)",
    r"\bnever\b.{0,30}(do|use|run|add|create)",
    r"remember (to|that)\b", r"don'?t forget",
    r"i (prefer|want|need|like) you to",
    r"going forward", r"in the future",
]

# --- Praise patterns (to capture what's working) ---
PRAISE_PATTERNS = [
    r"\bperfect\b", r"\bexactly\b", r"love (it|this|that)",
    r"that'?s (exactly|what i wanted|right|it|perfect)",
    r"(nice|great|good) (job|work|call|catch|one)",
    r"that (works|worked|did it)",
    r"\byes!?\b.{0,20}(that|this|perfect|exactly)",
]

friction_compiled = [(re.compile(p, re.IGNORECASE), p) for p in FRICTION_PATTERNS]
praise_compiled = [(re.compile(p, re.IGNORECASE), p) for p in PRAISE_PATTERNS]

friction_hits = []
praise_hits = []
files_scanned = 0

for path in sorted(glob.glob(f"{LOGS_DIR}/**/*.jsonl", recursive=True)):
    try:
        mtime = os.path.getmtime(path)
        if mtime < last_run.timestamp():
            continue
        files_scanned += 1

        rel = path.replace(LOGS_DIR + "/", "")
        project = rel.split("/")[0]

        with open(path) as f:
            lines = f.readlines()

        for i, line in enumerate(lines):
            try:
                obj = json.loads(line)
                if obj.get("type") != "user":
                    continue
                content = obj.get("message", {}).get("content", "")
                if not isinstance(content, str) or len(content.strip()) < 8:
                    continue
                # Skip pure tool result messages
                if content.startswith("{") or content.startswith("["):
                    continue
                # Skip system-injected messages (hook summaries, context continuations)
                if any(content.startswith(prefix) for prefix in [
                    "Summarize this conversation",
                    "This session is being continued",
                    "Summary:\n",
                    "The conversation above",
                ]):
                    continue

                ts = obj.get("timestamp", "")[:10]
                session_id = obj.get("sessionId", "")[:8]

                # Look back for assistant context (what did Claude do just before?)
                prior_assistant = ""
                for j in range(max(0, i - 8), i):
                    try:
                        prev = json.loads(lines[j])
                        role = prev.get("message", {}).get("role", "")
                        if role != "assistant":
                            continue
                        c = prev.get("message", {}).get("content", "")
                        if isinstance(c, list):
                            for block in c:
                                if isinstance(block, dict) and block.get("type") == "text":
                                    prior_assistant = block.get("text", "")[:200]
                                    break
                        elif isinstance(c, str):
                            prior_assistant = c[:200]
                        if prior_assistant:
                            break
                    except Exception:
                        pass

                entry = {
                    "ts": ts,
                    "session": session_id,
                    "project": project,
                    "text": content[:400],
                    "prior_assistant": prior_assistant,
                }

                for compiled, pattern in friction_compiled:
                    if compiled.search(content):
                        entry["matched_pattern"] = pattern
                        friction_hits.append(entry)
                        break

                for compiled, pattern in praise_compiled:
                    if compiled.search(content):
                        entry["matched_pattern"] = pattern
                        praise_hits.append(entry)
                        break

            except Exception:
                pass
    except Exception:
        pass

print(f"Files scanned: {files_scanned}")
print(f"Friction signals: {len(friction_hits)}")
print(f"Praise signals:   {len(praise_hits)}")
print()

print("=" * 60)
print("FRICTION SIGNALS")
print("=" * 60)
for h in friction_hits:
    print(f"\n[{h['ts']}] project={h['project'][:40]} session={h['session']}")
    if h.get("prior_assistant"):
        print(f"  Claude said: {h['prior_assistant'][:120]}...")
    print(f"  User said:   {h['text'][:300]}")
    print(f"  Pattern:     {h['matched_pattern']}")

print()
print("=" * 60)
print("PRAISE SIGNALS")
print("=" * 60)
for h in praise_hits[:15]:
    print(f"\n[{h['ts']}] project={h['project'][:40]}")
    print(f"  User said:   {h['text'][:200]}")
PYEOF
```

---

## Phase 3: PATTERN ANALYSIS

After reading the friction and praise output, reason through it **before** writing any files:

### 3a. Cross-reference against existing feedback

For each friction signal, check: does this match a rule already in `feedback_*.md`?

- **If yes → reinforcement.** Rule exists but was still violated. Note which file. Don't create a duplicate.
- **If no → new signal.** Candidate for a new feedback file.

### 3b. Quality filter

Discard signals that are:
- One-off or ambiguous (user correcting their own prompt)
- Too vague to produce an actionable rule
- Already well-covered by existing CLAUDE.md instructions

Keep signals that are:
- **Explicit rule declarations** ("from now on", "always", "never") — always keep
- **Repeated** across multiple sessions — strong signal
- **Specific enough** to write a clear How-to-apply

### 3c. Draft new feedback rules

For each keeper, draft:
- **Slug** — snake_case, e.g. `feedback_dont_ask_before_running_scripts`
- **Name** — short title
- **Rule** — the actionable statement
- **Why** — what the user said / what the pattern showed
- **How to apply** — specific, concrete

---

## Phase 4: MEMORY UPDATE

### 4a. Create new feedback files

Write to the appropriate project memory dir: `~/.claude/projects/<project-slug>/memory/feedback_<slug>.md`

For cross-project rules (communication style, tool habits), use the global project dir: `~/.claude/projects/-Users-<username>/memory/`

Use this exact format:

```markdown
---
name: <Short title, title case>
description: <One sentence>
type: feedback
---

<The rule, plainly stated in 1-3 sentences.>

**Why:** <Direct quote or paraphrase. Include date if possible.>

**How to apply:** <Specific, actionable guidance.>
```

### 4b. Reinforce violated rules

For existing rules still being violated, append to the bottom of that file:

```markdown
**Reinforced:** YYYY-MM-DD — still occurring. Example: "<brief quote>"
```

### 4c. Update MEMORY.md

Add a line for each new file:
```
- [<Name>](feedback_<slug>.md) — <one-line summary>
```

Keep MEMORY.md under 200 lines. Archive entries older than 90 days to `memory/archive/YYYY-MM.md` if needed.

### 4d. Memory consolidation

- Remove any MEMORY.md entries pointing to missing files
- Resolve contradictions: newer entry wins, old one moves to `memory/archive/`
- Replace any relative dates with absolute YYYY-MM-DD

---

## Phase 5: SESSION REPORT

Write a dated session report. Detect where to save it using this priority order:

```bash
DATE=$(date +%Y-%m-%d)
```

### Detection order

**1. Obsidian vault** — check if `~/.claude/dream-obsidian-vault` exists:
```bash
[ -f ~/.claude/dream-obsidian-vault ] && cat ~/.claude/dream-obsidian-vault
```
This file should contain the absolute path to your Obsidian vault (e.g. `/Users/you/Documents/MyVault`).  
The vault name for the `obsidian://` URI is derived from the last path component.  
If found → write to `<vault-path>/Claude/dream-${DATE}.md`

**2. Custom directory** — check if `~/.claude/dream-report-dir` exists:
```bash
[ -f ~/.claude/dream-report-dir ] && cat ~/.claude/dream-report-dir
```
If found → write to `<contents-of-file>/dream-${DATE}.md`

**3. Fallback** — write to `~/.claude/dream-reports/dream-${DATE}.md` (create dir if needed):
```bash
mkdir -p ~/.claude/dream-reports
```

### Report content (same for all three branches)

```markdown
# Dream Session — YYYY-MM-DD

## Summary
- Scanned N files across N projects
- Found N friction signals, N praise signals
- Created N new feedback rules
- Reinforced N existing rules

## New Feedback Rules Created
## Existing Rules Reinforced
## Praise Patterns — Don't Regress These
## Friction Signal Log
## Insights
```

### Post-write actions (branch-specific)

**Obsidian branch only:**
- Add a wikilink in today's daily note at `<vault-path>/Daily/${DATE}.md` under `## Claude Sessions`
- Open in Obsidian (vault name = last component of vault path):
```bash
DATE=$(date +%Y-%m-%d)
VAULT_PATH=$(cat ~/.claude/dream-obsidian-vault)
VAULT_NAME=$(basename "$VAULT_PATH")
ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('Claude/dream-${DATE}'))")
open "obsidian://open?vault=${VAULT_NAME}&file=${ENCODED}"
```

**Custom dir branch only:**
- Open with system default (`open` on macOS, `xdg-open` on Linux)

**Fallback branch only:**
- Print the report path to the terminal so the user knows where to find it

---

## Phase 6: STAMP

```bash
date -u +%Y-%m-%dT%H:%M:%SZ > ~/.claude/dream-last-run
echo "Dream complete. Next run in ~24h."
```

---

## Tips for signal quality

**High-value friction signals:**
- "From now on..." / "Always..." / "Never..." — user explicitly encoding a rule
- Same mistake appearing across multiple sessions (different session IDs, same pattern)
- User had to re-explain something already stated in a prior session
- Explicit frustration ("you keep doing this", "again")

**Low-value noise — discard:**
- "No wait, I meant..." — user correcting their own prompt
- Technical "no" (e.g., "No need to create a test file")
- "Hmm" with no follow-up correction

**When multiple signals cluster into one theme:** write one feedback file covering the theme, not one per signal.

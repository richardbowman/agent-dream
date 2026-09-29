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

Run this Node/TypeScript script to extract user messages that signal frustration, corrections, or stated preferences. This is the core of what makes this skill different from standard memory consolidation. It needs Node 22.18+ (runs `.ts` natively, no compile step) and no packages.

Write it to a temp file, run it, and delete it. Do not leave the script behind.

```bash
SCAN_DIR=$(mktemp -d)
cat > "$SCAN_DIR/dream-scan.ts" << 'TSEOF'
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const LOGS_DIR = path.join(os.homedir(), ".claude/projects");
const LAST_RUN_FILE = path.join(os.homedir(), ".claude/dream-last-run");

let lastRun = Date.now() - 30 * 24 * 3600 * 1000;
try {
  const t = Date.parse(fs.readFileSync(LAST_RUN_FILE, "utf8").trim());
  if (!Number.isNaN(t)) lastRun = t;
} catch {}
console.log(`Scanning logs since: ${new Date(lastRun).toISOString()}\n`);

const FRICTION = [
  // Direct corrections
  /\bno[,.!]\s/i, /\bnope\b/i, /\bwrong\b/i, /\bincorrect\b/i, /\bactually[,.]/i,
  /\bwait[,.]/i, /\bhold on\b/i, /that'?s not/i, /not what i/i, /didn'?t want/i,
  /don'?t want/i, /why did you/i, /why are you/i,
  // Frustration
  /\bugh\b/i, /\bargh\b/i, /\bffs\b/i, /you keep/i, /again you/i,
  /still (doing|not|wrong)/i, /i (told|said|asked) you/i,
  // Redirects
  /\bstop (doing|that|this)\b/i, /never ?mind/i, /forget (it|that|this)/i,
  /revert (that|this|it)/i, /please don'?t/i, /don'?t do that/i,
  // Explicit rule declarations (high-value)
  /from now on/i, /always\b.{0,30}(do|use|run|check|make)/i,
  /\bnever\b.{0,30}(do|use|run|add|create)/i, /remember (to|that)\b/i,
  /don'?t forget/i, /i (prefer|want|need|like) you to/i, /going forward/i, /in the future/i,
];
const PRAISE = [
  /\bperfect\b/i, /\bexactly\b/i, /love (it|this|that)/i,
  /that'?s (exactly|what i wanted|right|it|perfect)/i,
  /(nice|great|good) (job|work|call|catch|one)/i, /that (works|worked|did it)/i,
  /\byes!?\b.{0,20}(that|this|perfect|exactly)/i,
];

// Not the user's own words: system wrappers, subagent briefs, coordinator
// messages, summarizer prompts, and this skill's own invocation.
const NOISE_PREFIXES = [
  "<system-reminder>", "<command-", "Caveat:", "Base directory for this skill",
  "Run the dream skill", "The coordinator sent a message", "You are updating an existing",
  "Below is a conversation transcript", "This session is being continued",
  "Summarize this conversation", "Summary:\n", "The conversation above",
  "You are ", "I need you to", "Repo:", "Working directory:", "[SYSTEM NOTIFICATION",
];
const isNoise = (t: string) => /^[[{]/.test(t) || NOISE_PREFIXES.some((p) => t.startsWith(p));

// Content is a string OR an array of blocks; join the text blocks.
function textOf(msg: any): string {
  const c = msg?.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.filter((b) => b?.type === "text").map((b) => b.text).join("\n");
  return "";
}

function walk(dir: string, out: string[]) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith(".jsonl") && fs.statSync(p).mtimeMs >= lastRun) out.push(p);
  }
}
const files: string[] = [];
walk(LOGS_DIR, files);

type Hit = { ts: string; project: string; session: string; text: string; prior: string; pat: string };
const friction: Hit[] = [];
const praise: Hit[] = [];
const seen = new Set<string>();

for (const file of files) {
  const project = path.relative(LOGS_DIR, file).split(path.sep)[0];
  // Summarizer/scratch sessions live under the OS temp dir; skip them.
  if (project.startsWith("-private-var-folders")) continue;
  const lines = fs.readFileSync(file, "utf8").split("\n");
  lines.forEach((line, i) => {
    if (!line.startsWith("{")) return;
    let o: any;
    try { o = JSON.parse(line); } catch { return; }
    if (o.type !== "user") return;
    if (o.timestamp && Date.parse(o.timestamp) < lastRun) return;
    const text = textOf(o.message).trim();
    if (text.length < 8 || isNoise(text)) return;
    const key = text.slice(0, 200);
    if (seen.has(key)) return;
    seen.add(key);

    // What did Claude say just before? (look back up to 8 lines)
    let prior = "";
    for (let j = i - 1; j >= Math.max(0, i - 8) && !prior; j--) {
      try {
        const p = JSON.parse(lines[j]);
        if (p.message?.role === "assistant") prior = textOf(p.message).slice(0, 200);
      } catch {}
    }
    const base = { ts: (o.timestamp || "").slice(0, 10), project, session: (o.sessionId || "").slice(0, 8), text: text.slice(0, 400), prior };
    const f = FRICTION.find((r) => r.test(text));
    if (f) friction.push({ ...base, pat: f.source });
    const p = PRAISE.find((r) => r.test(text));
    if (p) praise.push({ ...base, pat: p.source });
  });
}

console.log(`Files scanned: ${files.length}`);
console.log(`Friction signals: ${friction.length}`);
console.log(`Praise signals:   ${praise.length}\n`);
console.log("=".repeat(60) + "\nFRICTION SIGNALS\n" + "=".repeat(60));
for (const h of friction) {
  console.log(`\n[${h.ts}] project=${h.project.slice(0, 40)} session=${h.session}`);
  if (h.prior) console.log(`  Claude said: ${h.prior.slice(0, 120).replace(/\n+/g, " ")}...`);
  console.log(`  User said:   ${h.text.slice(0, 300).replace(/\n+/g, " ")}`);
  console.log(`  Pattern:     ${h.pat}`);
}
console.log("\n" + "=".repeat(60) + "\nPRAISE SIGNALS\n" + "=".repeat(60));
for (const h of praise.slice(0, 15)) {
  console.log(`\n[${h.ts}] project=${h.project.slice(0, 40)}`);
  console.log(`  User said:   ${h.text.slice(0, 200).replace(/\n+/g, " ")}`);
}
TSEOF
node "$SCAN_DIR/dream-scan.ts"; rm -rf "$SCAN_DIR"
```

Even after filtering, expect some noise (subagent briefs and coordinator messages that slip past the prefix list). Judge each hit by whether it reads like the user's own words before treating it as a signal.

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
ENCODED="Claude%2Fdream-${DATE}"
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

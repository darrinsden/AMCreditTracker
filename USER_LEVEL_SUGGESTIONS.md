# Suggested user-level Claude Code config (~/.claude/)

These files live in your home directory, not in this project. They apply across **every** project you open with Claude Code on this machine.

**DO NOT commit these to any repo.** They're personal.

---

## ~/.claude/CLAUDE.md

Personal preferences that apply across all projects. Based on the working style observed during this build, here's a starting point:

```markdown
# Darrin's Claude Code Preferences

## Communication style
- I prefer short, direct prompts. Short single-word confirmations from me ("yes", "do it", "continue") mean execute fully — don't re-ask for permission.
- When you propose a multi-step plan, list the steps clearly, then start executing without waiting for me to say "okay" again.
- Push back when I'm wrong. I'd rather hear "that's the wrong approach because X" than have you implement something I'll have to undo.
- When something has multiple reasonable approaches, list 2-3 with one-line tradeoffs, then make a recommendation. Don't just dump options without an opinion.

## Coding style
- I'm a senior front-end developer (20+ years, currently Angular + AG Grid at NContracts). Treat me as such — don't over-explain syntax or basic patterns.
- I prefer surgical edits over rewrites. Use the str_replace tool, not full-file rewrites, unless the change is genuinely large.
- Comment explanatory non-obvious decisions. Don't comment what the code does, comment why.
- Verify your work before declaring done — run linters, balance checkers, tests if they exist.

## Workflow
- I use Bear Notes extensively (via MCP) for personal notes and project documentation.
- I use a custom CLI workflow called NDLC that integrates Claude into my dev lifecycle.
- I use Apple ecosystem (macOS, iPhone) and a paid Apple Developer account.
- I'm based in the Seattle area but originally from Boston.

## What I don't want
- Don't apologize repeatedly. Acknowledge a mistake once, then fix it.
- Don't pad responses with restating my question or summarizing my context back to me.
- Don't add emoji unless I use them first.
- Don't suggest installing tools or libraries without checking if I asked for that.
```

Drop that into `~/.claude/CLAUDE.md` and edit to match. Anything specific to one project goes in that project's `CLAUDE.md` instead.

---

## ~/.claude/settings.json

Global preferences. Minimal starting point:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "model": "claude-opus-4-7",
  "spinnerTipsEnabled": false,
  "permissions": {
    "allow": [
      "Bash(git status)",
      "Bash(git diff:*)",
      "Bash(git log:*)",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(grep:*)",
      "Bash(rg:*)",
      "Bash(find:*)"
    ],
    "deny": [
      "Bash(rm -rf /)",
      "Bash(sudo:*)"
    ]
  }
}
```

Notes:
- `model` — set this once and Claude Code will always use it (override per-project if needed).
- `spinnerTipsEnabled: false` — hides those loading-screen tips, cleaner UI.
- `permissions.allow` — pre-approves harmless commands so Claude doesn't pause to ask. Add commands you find yourself approving over and over.
- `permissions.deny` — hard blocks. `sudo` and root-level `rm -rf` are obvious; add more as you discover what you never want auto-allowed.

---

## ~/.claude/commands/

User-level slash commands available in every project. A few I'd suggest:

### `~/.claude/commands/explain.md`
```markdown
---
description: Explain selected code or a file at a senior-engineer level
---

Explain $ARGUMENTS at a senior engineer level. Skip syntax basics. Focus on:
- The non-obvious design decisions
- Why this approach over alternatives
- Hidden gotchas or edge cases
- How it fits into the broader system

If the code does something unusual or clever, say so. If it does something boring and standard, say that too — don't manufacture insight where there isn't any.
```

### `~/.claude/commands/code-review.md`
```markdown
---
description: Code review of recent changes or a specific file
---

Review $ARGUMENTS as a senior engineer would, in this priority order:

1. **Correctness** — bugs, edge cases, off-by-ones, null handling
2. **Security** — injection, leaked secrets, auth bypasses
3. **Maintainability** — naming, structure, comments where they matter
4. **Performance** — only flag if it's likely to actually matter at scale

Be direct. If something is fine, say "no issues here" rather than inventing concerns.
Use the format:
- **What's good:** (max 3 things)
- **What needs fixing:** (with line numbers)
- **What's debatable:** (style/preference, not bugs)
```

### `~/.claude/commands/commit.md`
```markdown
---
description: Stage changes and write a clean commit message
---

1. Run `git status` and `git diff --stat` to see what changed.
2. Group changes logically — if there are multiple unrelated changes, ask whether to split into multiple commits.
3. Stage with `git add` (never use `git add .` unless I confirm).
4. Write a commit message in this format:
   - First line: 50 chars max, imperative mood ("Add X" not "Added X")
   - Blank line
   - Body (only if needed): wrap at 72 chars, explain why not what

Don't include `Co-Authored-By: Claude` or AI tool footers. The user has those disabled in attribution settings.
```

Drop them into `~/.claude/commands/` and they're available as `/explain`, `/code-review`, `/commit` in every project.

---

## Setup steps

```bash
# Create the user-level dir if it doesn't exist
mkdir -p ~/.claude/commands

# Drop the files in
# (manually paste from above, or use your editor of choice)
nvim ~/.claude/CLAUDE.md
nvim ~/.claude/settings.json
nvim ~/.claude/commands/explain.md
nvim ~/.claude/commands/code-review.md
nvim ~/.claude/commands/commit.md
```

Verify with: `claude /config` from any project directory — opens a UI showing what's loaded from each scope.

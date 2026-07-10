---
description: Offload a self-contained subtask to a local OpenRouter model via opencode instead of Claude tokens
argument-hint: [-m provider/model] [-f file] <task description>
---

Run the following task through the opencode-offload skill instead of doing it
yourself with Claude tokens:

$ARGUMENTS

Steps:
1. If you haven't already, skim `~/.claude/skills/opencode-offload/SKILL.md` for the full flag set (model fallback lists, session continuity, timeout, JSON output, dry-run, file-editing agent mode).
2. Call `~/.claude/skills/opencode-offload/scripts/offload.sh` via Bash with the task above as the prompt, passing through any flags present in the arguments; otherwise use the script's default free model with no extra flags.
3. Report the model's answer (stdout) and the diagnostic line (stderr: model/tokens/cost/session) back to the user.

If the task genuinely needs multi-turn tool use, this session's context, or your own judgment, say so instead of forcing it through opencode.

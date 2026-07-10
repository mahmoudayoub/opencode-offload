---
name: opencode-offload
description: Offload a self-contained subtask (summarization, boilerplate generation, log triage, batch classification, draft text) to a local OpenRouter model via the `opencode` CLI instead of spending Claude tokens on it. Use when a task doesn't need this session's accumulated context or tool-use loop — just a prompt in, text out. Trigger on "offload this", "use opencode for this", "run this on openrouter/a cheaper model", or when doing large-volume mechanical work (e.g. summarizing many files, generating fixtures) where a free/cheap model is good enough.
---

# opencode Offload

Runs a prompt through the local `opencode` CLI (configured with OpenRouter) and
returns just the model's text reply. This is a way to spend OpenRouter tokens
instead of Claude tokens for well-scoped, self-contained subtasks.

There is no native Claude Code integration with opencode — this works by
shelling out to the `opencode` CLI's headless mode (`opencode run ... --format
json`) and parsing the JSON event stream. It is a subprocess call, not a
subagent: opencode has no visibility into this conversation, your prior tool
calls, or repo context unless you put it in the prompt or attach it as a file.

## When to use this

Good fits — the task is fully specified by a prompt (plus maybe a file) and
doesn't need iterative tool use:
- Summarizing a log file, error dump, or long document
- Drafting boilerplate text, fixtures, or repetitive mechanical content
- Batch classification/labeling of many independent items
- First-pass triage before you decide what deserves real attention

Poor fits — keep these in the main conversation instead:
- Anything requiring Read/Edit/Bash across multiple turns
- Anything that needs this session's accumulated context to get right
- Decisions the user is relying on your (Claude's) judgment for

## Usage

Call the helper script via Bash:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh "<prompt>"
```

It prints the model's final text to **stdout** and a one-line diagnostic
(`model=... tokens=... cost=...`) to **stderr** — capture stdout only if you
just want the answer.

**Cost guard, on by default**: only known free models ($0 input/output, per
`opencode models --verbose`) are ever actually called. Any paid model named
in `-m` gets skipped with a message instead of silently billing — pass `-P`
to lift the guard and allow paid models.

Options:

```
Cost guard:
  -P                      allow paid models (disables the free-only guard)

Model selection:
  -m model[,model2,...]  provider/model, comma-separated fallbacks tried in order
                          (default: opencode/deepseek-v4-flash-free, a free model)
  -e variant              reasoning effort/variant, e.g. high, max, minimal

Input:
  -f file                 attach a file (repeatable); prompt may also be piped via stdin

Session continuity (passthrough to opencode):
  -c                      continue the most recent opencode session
  -s session_id           continue a specific session id (get it from -j output)

Reliability:
  -t seconds              kill the opencode call if it runs longer than this

Output:
  -j                      emit one JSON object {text,model,tokens,cost,sessionID}
                          to stdout instead of text+stderr-diagnostics
  -n                      dry run: print what would be run and exit, no call made

File-editing agent mode (opencode's own agent gets real read/write tool access
in the given directory — higher blast radius, off unless you set -d):
  -d dir                  directory opencode's agent may read/write in
  -A agent                opencode agent preset to use (e.g. build, plan, explore)
  -U                      auto-approve opencode's own permission prompts (dangerous;
                          only meaningful together with -d/-A)

  -l                      list models (free-only unless -P), then exit
```

Examples:

```bash
# Default free model — good for bulk/cheap work
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh "Summarize the errors in this log" -f /tmp/app.log

# Naming a paid model WITHOUT -P: it gets skipped, guard error since nothing free is left
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -m openrouter/anthropic/claude-haiku-4.5 "..."
# -> [offload] skipping 'openrouter/anthropic/claude-haiku-4.5' -- known paid model (pass -P to allow paid models)
# -> Error: no free models left in '...' after the free-only guard. Pass -P to allow paid models.

# Explicitly opt into a paid model when quality matters more than cost
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -P -m openrouter/anthropic/claude-haiku-4.5 \
  "Classify each line as ERROR/WARN/INFO: $(cat lines.txt)"

# Mixed fallback list without -P: the paid entry is silently skipped, the free one is used
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh \
  -m openrouter/anthropic/claude-haiku-4.5,opencode/deepseek-v4-flash-free -t 30 "..."

# Structured output for scripts/Workflows
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -j "Summarize this" | jq -r .text

# Multi-turn: capture the session id, then continue it
SID=$(${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -j "Remember X=42" | jq -r .sessionID)
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -s "$SID" "What is X?"

# Preview a paid-model call (needs -P, else the guard filters it before the dry-run even runs)
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -n -P -m openrouter/anthropic/claude-opus-4.8 "big task"

# Let opencode's own agent actually edit files in a scratch directory, unattended
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -d /tmp/scratch -A build -U \
  "Generate 10 sample JSON fixtures matching schema.json in this directory"

# See what's free right now
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -l

# See everything, including paid models
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -l -P
```

## Notes

- Requires the `opencode` and `jq` CLIs on PATH (both already installed for
  this user). If either is missing the script exits with a clear error.
- **Free-only by default.** Unless `-P` is passed, every candidate model is
  checked against `opencode models --verbose` cost metadata (`$0` input/output
  = free); paid or unrecognized models are dropped from the list with a
  reason on stderr, and the script errors out if that leaves nothing to try.
  The unmodified default model skips this check entirely (already known
  free, zero extra latency). Naming a custom model always re-checks it, even
  if it happens to be free — there's no way to accidentally spend money
  without passing `-P`.
- `-m` accepts a comma-separated list; the script tries each in order and
  uses the first one that succeeds, printing `model '<x>' failed, trying
  next...` to stderr for each runtime miss (separate from the free-only
  guard's own skip messages, which happen before any model is called).
- Without `-c`/`-s`, each call is a fresh, stateless opencode session. Use
  `-j` to get the `sessionID` back and `-s` to continue it in a later call.
- `-U` (auto-approve) is opt-in and always prints a warning banner to stderr
  before running. It only does anything meaningful alongside `-d` (and
  usually `-A build`, since `plan`/`explore` deny or restrict edits). Prefer
  running it against a scratch/throwaway directory first, same as any
  unattended agent.
- This is a filesystem-level convention (a script under this skill's
  `scripts/` directory), not a Claude Code API — it works from the main
  conversation or from any subagent that has Bash access.

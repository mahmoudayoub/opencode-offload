---
name: opencode-offload
description: Offload a self-contained subtask (summarization, log triage, batch classification, draft generation) to a local opencode CLI (OpenRouter and other providers) instead of spending Claude tokens on it — also use whenever the user wants to save or reduce Claude token usage on a subtask. Use when a task doesn't need this session's accumulated context or tool-use loop — just a prompt in, text out. Trigger on "offload this", "use opencode for this", "run this on openrouter/a cheaper model", "save tokens on this", or when doing large-volume mechanical work (e.g. summarizing many files, generating fixtures) where a free/cheap model is good enough — including batch runs over hundreds of items with validated JSON output.
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
(`model=... tokens=... cost=... attempts=...`) to **stderr** — capture stdout
only if you just want the answer.

**Cost guard, on by default**: only known free models ($0 input/output, per
`opencode models --verbose`) are ever actually called. Any paid model named
in `-m` gets skipped with a message instead of silently billing — pass `-P`
to lift the guard and allow paid models.

**Reliable by default**: errors, empty replies and timeouts all count as
failures — transient ones (rate limits, overload, timeouts) are retried with
backoff, anything else moves on to the next model in the list. Every call has
a timeout (default 600s), so a call can never hang forever.

Options:

```
Cost guard:
  -P                      allow paid models (disables the free-only guard)

Model selection:
  -m model[,model2,...]  provider/model, comma-separated fallbacks tried in order
                          (default: preferred free models, auto-pruned to what opencode
                          currently offers; override with $OFFLOAD_MODELS)
  -e variant              reasoning effort/variant, e.g. high, max, minimal
  -R                      refresh the cached model list (cached 6h)

Input:
  -f file                 attach a file (repeatable); prompt may also be piped via stdin

Session continuity (passthrough to opencode):
  -c                      continue the most recent opencode session
  -s session_id           continue a specific session id (get it from -j output)

Reliability:
  -t seconds              per-call timeout (default 600, 0 disables)
  -r n                    retries per model for transient failures (default 1)

Output:
  -j                      emit one JSON object {text,model,tokens,cost,sessionID,attempts}
                          to stdout instead of text+stderr-diagnostics
  -J                      the reply must be JSON: it is extracted (code fences / prose
                          stripped), validated and printed compactly; invalid = failure
  -n                      dry run: print what would be run and exit, no call made

Batch:
  -b file                 one prompt per line, or JSONL {"id": ..., "prompt": ...};
                          one JSON result per input line on stdout, in input order
  -k n                    parallel calls in batch mode (default 4)

File-editing agent mode (opencode's own agent gets real read/write tool access
in the given directory — higher blast radius, off unless you set -d):
  -d dir                  directory opencode's agent may read/write in
  -A agent                opencode agent preset to use (e.g. build, plan, explore)
  -U                      auto-approve opencode's own permission prompts (dangerous;
                          only meaningful together with -d/-A)

  -l                      list free models (all with -P), then exit
  -V                      print version
```

Examples:

```bash
# Default free models — good for bulk/cheap work
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh "Summarize the errors in this log" -f /tmp/app.log

# Long prompts: pipe them in (very long ones are sent as an attached file automatically)
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh < prompt.md

# Structured output you can trust: -J guarantees stdout is valid, compact JSON
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -J 'Return {"sentiment": "pos|neg", "score": 0-1} for: "great product"'

# Batch: 200 independent classifications, 4 at a time, results as JSONL in input order
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -b items.jsonl -k 4 -J > results.jsonl
#   items.jsonl lines: {"id": "a1", "prompt": "Classify ..."}   (or just one plain prompt per line)
#   result lines:      {"id": "a1", "ok": true, "json": {...}, "model": "...", "tokens": ..., ...}
#                      {"id": "a2", "ok": false, "error": "..."}   (exit status 1 if any failed)

# Naming a paid model WITHOUT -P: it gets skipped, guard error since nothing free is left
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -m openrouter/anthropic/claude-haiku-4.5 "..."
# -> [offload] skipping 'openrouter/anthropic/claude-haiku-4.5' -- known paid model (pass -P to allow paid models)
# -> Error: no free models left in '...' after the free-only guard. Pass -P to allow paid models.

# Explicitly opt into a paid model when quality matters more than cost
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -P -m openrouter/anthropic/claude-haiku-4.5 \
  "Classify each line as ERROR/WARN/INFO: $(cat lines.txt)"

# Script-friendly output
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -j "Summarize this" | jq -r .text

# Multi-turn: capture the session id, then continue it
SID=$(${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -j "Remember X=42" | jq -r .sessionID)
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -s "$SID" "What is X?"

# Let opencode's own agent actually edit files in a scratch directory, unattended
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -d /tmp/scratch -A build -U \
  "Generate 10 sample JSON fixtures matching schema.json in this directory"

# See what's free right now (-R to refresh the 6h cache)
${CLAUDE_PLUGIN_ROOT}/scripts/offload.sh -l
```

## Notes

- Requires the `opencode` and `jq` CLIs on PATH. Works with the stock macOS
  bash 3.2; if `timeout(1)` isn't installed, a perl fallback enforces `-t`.
- **Free-only by default.** Unless `-P` is passed, every candidate model is
  checked against `opencode models --verbose` cost metadata (`$0` input/output
  = free); paid or unrecognized models are dropped with a reason on stderr,
  and the script errors out if that leaves nothing to try. The model list is
  cached for 6 hours (`-R` refreshes it), so the check costs nothing per call.
- **Defaults never go stale.** When `-m` isn't given, the preferred free
  models are pruned to the ones opencode still offers; if none are left, the
  first free models opencode currently lists are used (with a note on stderr).
- **Failures are detected, not guessed.** opencode exits 0 even when the
  provider returns an error, so the script reads the event stream: an `error`
  event, an empty reply, a timeout, or (with `-J`) an unparseable reply is a
  failure. Transient ones are retried (`-r`, exponential backoff); others go
  straight to the next model.
- **Isolated by default.** Without `-d`, calls run in an empty directory of
  their own (`~/.cache/opencode-offload/workdir`, persistent so `-s`/`-c` can
  resume sessions): opencode's agent can't read or modify the current
  project, and startup is faster. Attached files (`-f`) keep working from any
  path (they're resolved to absolute paths first).
- **Never hangs on stdin.** `opencode run` reads stdin as extra prompt text
  whenever it isn't a terminal and waits for EOF — under an agent harness or a
  background shell that's forever. The script always runs opencode with stdin
  closed (pipe your prompt into the *script*, not opencode), and every call
  also has a timeout as a safety net.
- **Token overhead.** opencode sends its agent system prompt and tool
  definitions with every call (~12k input tokens even for "say OK"). It's free
  on free models, and opencode's free tier rejects calls without them, so it
  can't be stripped — just batch work into fewer, larger prompts where sensible.
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
- Tests: `bash tests/run.sh` (offline, no model calls).

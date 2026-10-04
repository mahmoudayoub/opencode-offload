# opencode-offload

A Claude Code skill (plus an optional `/offload` slash command) that offloads
self-contained subtasks — summarization, log triage, batch classification,
draft generation — to a local [opencode](https://opencode.ai) CLI installation
instead of spending Claude tokens on them.

It works by shelling out to `opencode run ... --format json` and parsing the
JSON event stream. This is a subprocess call, not a real subagent: opencode
has no visibility into your conversation or repo context unless you hand it
a prompt, a file (`-f`), or a directory to work in (`-d`).

## Why

If you have `opencode` configured with OpenRouter (or any other provider),
you effectively have a second, independent pool of LLM tokens sitting next to
your Claude Code session. Tasks that are fully specified by a prompt — no
multi-turn tool use, no need for the assistant's accumulated context — don't
need to burn Claude tokens at all. This script is the plumbing that lets an
agent (Claude Code's main loop or any subagent with Bash access) reach for
that second pool deliberately, instead of defaulting to its own.

**Free by default.** Every model is checked against `opencode models
--verbose`'s real cost metadata before it's ever called. Paid models are
skipped with a clear reason unless you explicitly pass `-P`. You cannot
accidentally spend money with this script.

## Requirements

- [opencode](https://opencode.ai) installed and configured with at least one
  provider (`opencode providers login`)
- `jq`

## Install

This repo ships a `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`,
so it installs as a proper Claude Code plugin — the `opencode-offload` skill and
the `/opencode-offload:offload` slash command are both auto-discovered together,
no manual file copying needed.

**Option A — as a plugin marketplace (recommended):**

```
/plugin marketplace add mahmoudayoub/opencode-offload
/plugin install opencode-offload@opencode-offload
```

Updates: `/plugin marketplace update` then `/plugin update opencode-offload`.

**Option B — clone directly into your skills directory:**

```bash
git clone https://github.com/mahmoudayoub/opencode-offload.git ~/.claude/skills/opencode-offload
```

Because the repo includes `.claude-plugin/plugin.json`, Claude Code
auto-loads it in place as `opencode-offload@skills-dir` on the next session —
same skill and command, no marketplace registration, but you manage updates
yourself (`git pull`).

Either way, invoke the slash command as `/opencode-offload:offload` (plugin
components are namespaced by plugin name).

**Standalone, no Claude Code at all:** `scripts/offload.sh` is a plain,
dependency-free bash script — call it directly from any shell or agent with
Bash access. It doesn't reference `${CLAUDE_PLUGIN_ROOT}` itself (only
`SKILL.md`/`commands/offload.md` do, for locating it), so just invoke it by
whatever path you cloned the repo to.

## Usage

```
opencode-offload 1.1.0

Usage: offload.sh [options] "<prompt>"       (prompt may also be piped via stdin)
       offload.sh -b prompts.txt [options]    batch: one prompt per line -> JSONL results
       offload.sh -l                          list free models

Cost guard (on by default):
  Only known free models ($0 input/output cost, per 'opencode models --verbose')
  are ever used unless you pass -P. Any paid model in -m is skipped with a
  message, not silently billed.
  -P                      allow paid models (disables the free-only guard)

Model selection:
  -m model[,model2,...]  provider/model, comma-separated fallbacks tried in order
                          (default: preferred free models, auto-pruned to what
                          opencode currently offers; override with $OFFLOAD_MODELS)
  -e variant              reasoning effort/variant, e.g. high, max, minimal
  -R                      refresh the cached model list (cached 6h)

Input:
  -f file                 attach a file (repeatable)

Session continuity (passthrough to opencode):
  -c                      continue the most recent opencode session
  -s session_id           continue a specific session id

Reliability:
  -t seconds              kill a call that runs longer than this (default 600;
                          0 disables; headless opencode can otherwise wait forever
                          on a permission prompt)
  -r n                    retries per model for transient failures
                          (timeouts, rate limits, overload; default 1)

Output:
  -j                      emit one JSON object {text,model,tokens,cost,sessionID,attempts}
                          to stdout instead of text+stderr-diagnostics
  -J                      the reply must be JSON: extract it (code fences and
                          surrounding prose are stripped), validate it, and print it
                          compactly; an invalid reply counts as a failure (retry/next model)
  -n                      dry run: print what would be run and exit, no call made

Batch:
  -b file                 one prompt per line, or JSONL lines {"id": ..., "prompt": ...};
                          prints one JSON result per input line, in input order
  -k n                    parallel calls in batch mode (default 4)

File-editing agent mode (opencode's own agent gets real read/write tool access
in the given directory -- higher blast radius, off unless you set -d):
  -d dir                  directory opencode's agent may read/write in
  -A agent                opencode agent preset to use (e.g. build, plan, explore)
  -U                      auto-approve opencode's own permission prompts (dangerous;
                          only meaningful together with -d/-A)

Without -d, every call runs in a fresh empty temporary directory, so opencode's
agent cannot see or touch the current project (and starts faster).

  -l                      list free models (all models with -P), then exit
  -V                      print version
  -h                      this help
```

### Examples

```bash
# Default free models — good for bulk/cheap work. Attach files by path;
# opencode reads them itself, so the content never has to pass through
# the calling agent's own context.
./scripts/offload.sh "Summarize the errors in this log" -f /tmp/app.log

# JSON you can pipe straight into jq: fences/prose are stripped and the
# reply is validated (an invalid reply is retried / falls through to the next model)
./scripts/offload.sh -J 'Return {"sentiment": "pos|neg"} for: "great product"' | jq -r .sentiment

# Batch: one prompt per line (or JSONL {"id","prompt"}), 4 in parallel,
# one JSON result per input line, in order
./scripts/offload.sh -b items.jsonl -k 4 -J > results.jsonl

# Explicitly opt into a paid model when quality matters more than cost
./scripts/offload.sh -P -m openrouter/anthropic/claude-haiku-4.5 \
  "Classify each line as ERROR/WARN/INFO: $(cat lines.txt)"

# Multi-turn: capture the session id, then continue it
SID=$(./scripts/offload.sh -j "Remember X=42" | jq -r .sessionID)
./scripts/offload.sh -s "$SID" "What is X?"

# Let opencode's own agent actually edit files in a scratch directory, unattended
./scripts/offload.sh -d /tmp/scratch -A build -U \
  "Generate 10 sample JSON fixtures matching schema.json in this directory"

# See what's free right now
./scripts/offload.sh -l
```

See [`SKILL.md`](SKILL.md) for the full write-up (when to use this vs. not,
notes on each flag) as consumed by Claude Code's skill system, and
[`commands/offload.md`](commands/offload.md) for the slash-command wrapper.

## Design notes

- **Pass paths, not content.** The whole point is that the calling agent
  never has to read a file itself and re-type its contents into a prompt —
  it only needs to know a path (`-f`), pipe bytes through the shell, or point
  opencode's own agent at a directory (`-d`). All three keep large content
  out of the calling agent's token budget entirely.
- **opencode exits 0 on provider errors.** A dead model or a rate limit shows
  up only as an `error` event in the JSON stream, so success is decided from
  the stream (text present, no error event), not the exit code. That is what
  makes `-m a,b,c` fallbacks and `-r` retries actually trigger.
- **`opencode run` blocks on an open stdin.** When stdin isn't a terminal it is
  read as extra prompt text until EOF — so under an agent harness or a
  background shell (stdin open, never closed) the call hangs forever. opencode
  is always started with stdin closed, and every call has a timeout (600s
  default) as a safety net.
- **Plain calls run in an empty directory of their own** (persistent, so sessions stay resumable), so opencode's agent can't
  wander into (or modify) the caller's repo, and it starts ~30% faster than
  inside a project.
- **`opencode models --verbose` truncates when piped directly** into another
  process (it appears to exit before its stdout pipe fully drains) — the
  model lookup writes it to a temp file first, then caches the parsed list
  for 6 hours under `~/.cache/opencode-offload/`.
- **Default models self-heal.** Free models come and go; the preferred list is
  pruned against opencode's live free list, falling back to whatever is free
  now, so the default never points at a model that no longer exists.
- **~12k tokens of overhead per call** (opencode's agent prompt + tool
  definitions) can't be removed: opencode's free tier rejects requests without
  them. Prefer fewer, larger prompts when that fits the task.

## Tests

```bash
bash tests/run.sh        # offline: JSON extraction, event parsing, retry rules, model selection
/bin/bash tests/run.sh   # same, on the stock macOS bash 3.2
```

## License

MIT — see [LICENSE](LICENSE).

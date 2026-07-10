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
Usage: offload.sh [options] "<prompt>"       (prompt may also be piped via stdin)
       offload.sh -l                          # list available models

Cost guard (on by default):
  Only known free models ($0 input/output cost, per 'opencode models --verbose')
  are ever used unless you pass -P. Any paid model in -m is skipped with a
  message, not silently billed.
  -P                      allow paid models (disables the free-only guard)

Model selection:
  -m model[,model2,...]  provider/model, comma-separated fallbacks tried in order
                          (default: opencode/deepseek-v4-flash-free)
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
in the given directory -- higher blast radius, off unless you set -d):
  -d dir                  directory opencode's agent may read/write in
  -A agent                opencode agent preset to use (e.g. build, plan, explore)
  -U                      auto-approve opencode's own permission prompts (dangerous;
                          only meaningful together with -d/-A)

  -l                      list models (free-only unless -P), then exit
  -h                      this help
```

### Examples

```bash
# Default free model — good for bulk/cheap work. Attach files by path;
# opencode reads them itself, so the content never has to pass through
# the calling agent's own context.
./scripts/offload.sh "Summarize the errors in this log" -f /tmp/app.log

# Explicitly opt into a paid model when quality matters more than cost
./scripts/offload.sh -P -m openrouter/anthropic/claude-haiku-4.5 \
  "Classify each line as ERROR/WARN/INFO: $(cat lines.txt)"

# Structured output for scripts/pipelines
./scripts/offload.sh -j "Summarize this" | jq -r .text

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
- **`opencode models --verbose` truncates when piped directly** into another
  process (it appears to exit before its stdout pipe fully drains) — the
  cost-lookup helper writes it to a temp file first instead, which is
  reliable.
- The free-model check is skipped entirely when the model is left at its
  default (zero extra latency for the common case); naming any model via
  `-m` re-triggers the check, even if that model happens to be free.

## License

MIT — see [LICENSE](LICENSE).

# agent-pair

A skill that lets Claude Code and OpenAI Codex CLI review each other's code. It works from either side.

The agent you are using is the **host**; the other one is the **peer**, called in the background through its CLI. There are two ways to split the work:

| Mode | Writes code | Reviews |
|---|---|---|
| A: I write, peer reviews | host | peer (read-only) |
| B: peer writes, I review | peer | host (does not change code) |

A reviewer who is not the author is far more likely to spot what the author cannot see. That is why the roles are kept strictly apart and the reviewer never fixes code on the side.

## Features

- **One session across rounds**: continued via `codex exec resume` / `claude -p --resume`, so the peer remembers earlier feedback and each round only needs the delta.
- **Resumable and clearable sessions**: every run reports the peer session id, which you can continue later with `--resume`; `--clear` deletes every peer session the current session created in one go.
- **Tight permissions**: the reviewer is read-only; the writer can only edit workspace files and cannot commit.
- **Recursion guard**: the peer runs with `AGENT_PAIR_PEER` set, so it never calls back into the host.
- **Replies in your language**: the skill is written in English, but the host always talks to you in the language you use.

## Requirements

- `git`, `bash`
- The peer's CLI, logged in:
  - from Claude Code: `codex` with `codex exec resume` support; `--clear` also needs `codex delete`
  - from Codex: `claude`
- `jq` is recommended; `python3` is used to parse JSON when it is missing

## Installation

Claude Code:

```bash
git clone https://github.com/natsu1211/agent-pair.git ~/.claude/skills/agent-pair
```

Codex: put it in Codex's user-level skill directory. If you use both, clone once and symlink:

```bash
mkdir -p ~/.agents/skills
ln -s ~/.claude/skills/agent-pair ~/.agents/skills/agent-pair
```

Update: `git -C ~/.claude/skills/agent-pair pull`

## Usage

Just ask in natural language; the skill infers the mode from what you say:

- "Implement this and have Codex review it" → mode A
- "Let Codex write it and you review" → mode B
- In Codex: "Have Claude review this change"

Or invoke it explicitly with arguments:

| Invocation | Behavior |
|---|---|
| `/agent-pair` | Continue the peer session bound to the current session, or start a new one |
| `/agent-pair --new` | Start a fresh peer session |
| `/agent-pair --resume <id>` | Continue the given peer session |
| `/agent-pair --clear` | Permanently delete every peer session the current session created |

In Codex, use `$agent-pair` instead of `/agent-pair`.

`--clear` only deletes peer sessions **created by** the current host session. Peer sessions picked up with `--resume` that another session created are only unbound, never deleted.

## Configuration

Copy the example config and edit it:

```bash
cp ~/.claude/skills/agent-pair/config.env.example ~/.claude/skills/agent-pair/config.env
```

Model and effort can be set per peer × role, for example:

```
PAIR_CODEX_REVIEWER_MODEL=gpt-5
PAIR_CODEX_REVIEWER_EFFORT=high
PAIR_CLAUDE_WRITER_MODEL=opus
```

Highest priority first:

1. Named in the conversation (the skill turns it into `--model` / `--effort` on `send`)
2. Environment variables with the same names
3. Project config `<repo root>/.agent-pair/config.env`
4. Global config `<skill dir>/config.env`
5. The peer CLI's own defaults

Config files are plain `KEY=value` text, read as data and never executed. A project config may come from someone else's repository, so it may only set models and efforts. The permission-related `PAIR_CODEX_EXTRA`, `PAIR_CLAUDE_REVIEWER_TOOLS` and `PAIR_CLAUDE_WRITER_TOOLS` are only honored from environment variables or the global config.

## Permissions and sandbox

The peer needs network access to its own model API and must write to its own session directory (`~/.codex` or `~/.claude`). So if the host runs with a sandbox, `scripts/pair.sh` has to run outside it, and you will get an approval prompt.

Permissions the script gives the peer:

| | Codex | Claude Code |
|---|---|---|
| reviewer | `read-only` sandbox | edit tools disabled, Bash limited to `git diff/log/show/status` |
| writer | `workspace-write` sandbox | edits auto-accepted, Bash limited to `git diff/status` |

So the peer usually cannot run tests; the host runs them. If needed, allow specific commands through `PAIR_CLAUDE_*_TOOLS` in the global config, e.g. `Bash(npm test:*)`.

## Files and state

| Location | Contents |
|---|---|
| `<repo root>/.agent-pair/` | Session bindings and full per-round logs (`<peer>-<role>.log`); ships its own `.gitignore` |
| `~/.agent-pair/ledger.tsv` | Which host session created each peer session, used by `--clear`; relocatable with `AGENT_PAIR_HOME` |

The script detects the host session id itself: `CLAUDE_CODE_SESSION_ID` in Claude Code, `CODEX_THREAD_ID` in Codex. If detection fails, set `PAIR_HOST_SESSION` manually.

## Layout

```
SKILL.md               the skill itself: the workflow the agent follows
references/prompts.md  prompt templates sent to the peer
scripts/pair.sh        talks to the peer and manages sessions
config.env.example     example config
```

## License

MIT

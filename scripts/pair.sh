#!/usr/bin/env bash
# agent-pair helper: lets the host (Claude Code or Codex) hold a multi-round conversation with one peer session.
#
# Usage:
#   pair.sh <codex|claude> send <reviewer|writer> [--new | --resume ID] [--model M] [--effort E] "prompt"
#                                                           # reads the prompt from stdin when omitted
#   pair.sh status                                          # bindings of the current host session and the peer sessions it created
#   pair.sh lookup <ID>                                     # which peer/role a peer session id belongs to
#   pair.sh reset [all|codex|claude|codex-reviewer|...]     # unbind for the current host session (default all); sessions are kept
#   pair.sh clear [--dry-run]                               # permanently delete every peer session the current host session created
#
# Review range helpers (each prints one git object id to diff from or to):
#   pair.sh snapshot                                        # the current working tree as a tree id (incl. untracked files)
#   pair.sh <codex|claude> last-reviewed <reviewer|writer> [--new | --resume ID]
#                                                           # the working tree as it was after that peer session's last
#                                                           # round; prints nothing if there is no record for this repo
#   pair.sh branch-base [BRANCH]                            # merge-base of HEAD with BRANCH (default: origin/HEAD, main, master)
#
# The first argument is the peer, i.e. the other agent:
#   from Claude Code -> codex  (codex exec / codex exec resume)
#   from Codex       -> claude (claude -p / claude -p --resume)
#
# Roles and permissions:
#   reviewer  read-only. codex: sandbox_mode=read-only; claude: no edit tools, Bash limited to read-only git commands
#   writer    may edit workspace files. codex: sandbox_mode=workspace-write; claude: acceptEdits
#   The claude peer ignores project/local settings and MCP servers, so the repository under review cannot widen
#   its permissions, and git's write-capable --output option is denied
#
# Session selection (send):
#   default    continue the peer session bound to the current host session; start a new one if none is bound
#   --new      ignore the existing binding and start a new session
#   --resume   continue the peer session with the given id and bind it to the current host session
#   Every round prints "agent-pair: SESSION <peer>-<role> <id>" to stderr
#
# Host session: CLAUDE_CODE_SESSION_ID for Claude Code, CODEX_THREAD_ID for Codex.
#   The host is identified by walking up the parent processes; PAIR_HOST_SESSION overrides it.
#
# State, all under ${AGENT_PAIR_HOME:-~/.agent-pair} so nothing is ever written into the repository:
#   sessions/<host session>/<repo key>/<peer>-<role>.id  currently bound peer session id
#   logs/<repo key>/<peer>-<role>.log                    full output of every round; look here on errors
#   ledger.tsv                                           which host session created each peer session; clear uses it
#   reviewed/<peer session>                              "<repo root>\t<tree id>" after that session's last round
#   (<repo key> is the repo directory name plus a hash of its full path)
#
# Model and effort, highest priority first:
#   1. --model / --effort on send (this round only)
#   2. environment variables PAIR_<PEER>_<ROLE>_MODEL / PAIR_<PEER>_<ROLE>_EFFORT
#      e.g. PAIR_CODEX_REVIEWER_MODEL, PAIR_CLAUDE_WRITER_EFFORT
#   3. config files (KEY=value, same names): <repo root>/.agent-pair/config.env over <skill dir>/config.env
#   4. otherwise the peer CLI's own defaults
#   effort values: codex minimal|low|medium|high|xhigh; claude low|medium|high|xhigh|max
#   (codex gets it via -c model_reasoning_effort; claude via --effort and CLAUDE_CODE_EFFORT_LEVEL)
#
# Permission-related settings, only honored from the environment or <skill dir>/config.env (ignored in repo config):
#   PAIR_CODEX_EXTRA                       extra arguments for codex exec (split on spaces)
#   PAIR_CLAUDE_REVIEWER_TOOLS             overrides --allowedTools for the claude reviewer (comma separated)
#   PAIR_CLAUDE_WRITER_TOOLS               overrides --allowedTools for the claude writer (comma separated)

set -euo pipefail

die() { echo "agent-pair: $*" >&2; exit 1; }

# Recursion guard: the peer process carries this variable and must not call another agent
if [[ -n "${AGENT_PAIR_PEER:-}" ]]; then
  die "this process is itself a peer called by agent-pair and may not call another agent (prevents mutual recursion)"
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Only read from inside the repository. Mutable state lives in GLOBAL_DIR, because a malicious repository could
# commit symlinks under .agent-pair/ and make the (unsandboxed) script write to arbitrary files
REPO_CONF_DIR="$ROOT/.agent-pair"

GLOBAL_DIR="${AGENT_PAIR_HOME:-$HOME/.agent-pair}"
LEDGER="$GLOBAL_DIR/ledger.tsv"
LEDGER_LOCK="$GLOBAL_DIR/ledger.lock"
path_hash() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-16
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-16
  else cksum | cut -d' ' -f1
  fi
}
REPO_KEY="$(basename "$ROOT" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)-$(printf '%s' "$ROOT" | path_hash)"
LOG_DIR="$GLOBAL_DIR/logs/$REPO_KEY"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

MODEL_KEYS=""
for _p in CODEX CLAUDE; do for _r in REVIEWER WRITER; do MODEL_KEYS+=" PAIR_${_p}_${_r}_MODEL PAIR_${_p}_${_r}_EFFORT"; done; done
PERMISSION_KEYS="PAIR_CODEX_EXTRA PAIR_CLAUDE_REVIEWER_TOOLS PAIR_CLAUDE_WRITER_TOOLS"
unset _p _r

# Config files are plain KEY=value text, read as data and never executed. Variables that are already set are kept,
# so the environment always wins, and the repo config is loaded first so it beats the global one. A repo config may
# come from an untrusted repository, so it may only set models and efforts; otherwise it could loosen the peer's
# sandbox and permissions through PAIR_CODEX_EXTRA or *_TOOLS
load_config() {
  local file="$1" allowed="$2" line key val n=0
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      echo "agent-pair: warning: cannot parse $file line $n, ignored" >&2; continue
    fi
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    if [[ " $allowed " != *" $key "* ]]; then
      echo "agent-pair: warning: $key ($file line $n) is not allowed here, ignored" >&2; continue
    fi
    [[ -n "${!key+x}" ]] || printf -v "$key" '%s' "$val"
  done <"$file"
}

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for _old in "$REPO_CONF_DIR/config.sh" "$SKILL_DIR/config.sh"; do
  [[ -f "$_old" ]] && echo "agent-pair: warning: $_old is no longer read; rewrite it as config.env (KEY=value) in the same directory" >&2
done
unset _old
load_config "$REPO_CONF_DIR/config.env" "$MODEL_KEYS"
load_config "$SKILL_DIR/config.env" "$MODEL_KEYS $PERMISSION_KEYS"

TMP_FILES=()
cleanup() { [[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}"; return 0; }
trap cleanup EXIT
# Assigns to the variable named $1 instead of printing: $(mktmp) would run in a subshell and the
# file would never reach TMP_FILES, so it would not be cleaned up
mktmp() { local f; f=$(mktemp); TMP_FILES+=("$f"); printf -v "$1" '%s' "$f"; }

# Read a top-level field from a file holding a single JSON object
json_get() {
  local file="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // empty | tostring' "$file" 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" <<'PY' 2>/dev/null && return 0
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.find("{")
d = json.loads(text[start:]) if start >= 0 else {}
v = d.get(sys.argv[2])
print("" if v is None else v)
PY
  fi
  return 1
}

# Session ids end up in file paths and deletions, so only letters, digits, - and _ are accepted
valid_id() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

# ---------- host session ----------
# The environment variables may be inherited from an outer agent (e.g. Codex started inside Claude Code),
# so find the nearest claude/codex ancestor process first and then read the matching variable
detect_host_kind() {
  local pid=$PPID comm
  while [[ -n "$pid" && "$pid" -gt 1 ]]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
    case "${comm##*/}" in
      claude) echo claude; return 0 ;;
      codex|codex-*) echo codex; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
}

# $1: host kind to assume when detection fails (send derives it from the peer)
resolve_host() {
  HOST_SID="${PAIR_HOST_SESSION:-}"
  if [[ -n "$HOST_SID" ]]; then
    valid_id "$HOST_SID" || die "PAIR_HOST_SESSION may only contain letters, digits, - and _"
    return 0
  fi
  local kind; kind=$(detect_host_kind)
  [[ -n "$kind" ]] || kind="${1:-}"
  case "$kind" in
    claude) HOST_SID="${CLAUDE_CODE_SESSION_ID:-}" ;;
    codex)  HOST_SID="${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}" ;;
  esac
  if [[ -n "$HOST_SID" ]] && ! valid_id "$HOST_SID"; then HOST_SID=""; fi
  return 0
}

host_sessions_dir() { printf '%s/sessions/%s' "$GLOBAL_DIR" "${HOST_SID:-unknown-host}"; }
host_dir() { printf '%s/%s' "$(host_sessions_dir)" "$REPO_KEY"; }

# ---------- ledger: peer session <- host session that created it ----------
# Each line: time \t host session \t peer \t role \t peer session \t repo root
ledger_has() { [[ -f "$LEDGER" ]] && awk -F'\t' -v id="$1" '$5==id {f=1} END {exit !f}' "$LEDGER"; }

# Several host sessions may share the ledger, so every read-modify-write runs under a mkdir lock whose owner file
# holds "<pid>:<random token>", and only the holder of the matching token releases it. Stale locks are never removed
# automatically: two waiters could both judge the same lock stale and one would delete the other's fresh lock.
# The lock is held for milliseconds, so a stale one only appears if a process is killed mid-write
lock_owner() { cat "$LEDGER_LOCK/owner" 2>/dev/null || true; }

with_ledger_lock() {
  local waited=0 rc=0 owner token
  token="$$:$(mktemp -u XXXXXXXXXX)"
  mkdir -p "$GLOBAL_DIR"
  until mkdir "$LEDGER_LOCK" 2>/dev/null; do
    owner=$(lock_owner)
    if [[ -n "$owner" ]] && ! kill -0 "${owner%%:*}" 2>/dev/null; then
      echo "agent-pair: the ledger lock was left behind by process ${owner%%:*}, which no longer exists; remove $LEDGER_LOCK and retry" >&2
      return 1
    fi
    waited=$((waited + 1))
    if [[ $waited -ge 300 ]]; then
      echo "agent-pair: the ledger is locked by another process; if no agent-pair is running, remove $LEDGER_LOCK" >&2
      return 1
    fi
    sleep 0.1
  done
  printf '%s' "$token" >"$LEDGER_LOCK/owner"
  "$@" || rc=$?
  [[ "$(lock_owner)" == "$token" ]] && rm -rf -- "$LEDGER_LOCK"
  return $rc
}

_ledger_add() {
  local peer="$1" role="$2" id="$3"
  ledger_has "$id" && return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$HOST_SID" "$peer" "$role" "$id" "$ROOT" >>"$LEDGER"
}

ledger_add() {
  [[ -n "$HOST_SID" ]] || return 0
  with_ledger_lock _ledger_add "$@"
}

_ledger_remove() {
  local id="$1" tmp
  [[ -f "$LEDGER" ]] || return 0
  tmp="$LEDGER.tmp.$$"
  awk -F'\t' -v id="$id" '$5!=id' "$LEDGER" >"$tmp" && mv -f "$tmp" "$LEDGER"
}

ledger_remove() { with_ledger_lock _ledger_remove "$@"; }

# Output: peer role host-session repo-root
ledger_lookup() {
  [[ -f "$LEDGER" ]] || return 0
  awk -F'\t' -v id="$1" '$5==id {print $3, $4, $2, $6; exit}' "$LEDGER"
}

# ---------- peer session files ----------
peer_session_exists() {
  local peer="$1" id="$2" d
  case "$peer" in
    codex)
      # Check each existing directory separately: with pipefail, find failing on a missing directory
      # would otherwise hide a match found in the other one
      for d in "$CODEX_DIR/sessions" "$CODEX_DIR/archived_sessions"; do
        [[ -d "$d" ]] || continue
        [[ -n "$(find "$d" -name "*$id.jsonl" -print 2>/dev/null | head -n1)" ]] && return 0
      done
      return 1
      ;;
    claude)
      compgen -G "$CLAUDE_DIR/projects/*/$id.jsonl" >/dev/null ;;
  esac
}

# Returns 0: deleted; 2: did not exist; anything else: deletion failed
delete_peer_session() {
  local peer="$1" id="$2"
  valid_id "$id" || return 1
  case "$peer" in
    codex)
      command -v codex >/dev/null 2>&1 || return 1
      if (cd "$ROOT" && AGENT_PAIR_PEER=1 codex delete --force "$id") </dev/null >/dev/null 2>&1; then return 0; fi
      peer_session_exists codex "$id" && return 1
      return 2
      ;;
    claude)
      local f found=0
      # The directory named after the session holds subagent transcripts and large tool outputs
      # errexit is off here (callers use ||), so every removal is checked explicitly
      for f in "$CLAUDE_DIR"/projects/*/"$id".jsonl "$CLAUDE_DIR"/projects/*/"$id"; do
        [[ -e "$f" ]] || continue
        rm -rf -- "$f" || return 1
        found=1
      done
      [[ $found -eq 1 ]] && return 0
      return 2
      ;;
  esac
}

# ---------- peer: Codex ----------
run_codex() {
  local role="$1" prompt="$2" sid="$3" events="$4" reply="$5"
  command -v codex >/dev/null 2>&1 || die "codex command not found"
  local sandbox
  case "$role" in reviewer) sandbox="read-only" ;; writer) sandbox="workspace-write" ;; esac

  local out; mktmp out
  local -a opts=(-C "$ROOT" -c "sandbox_mode=\"$sandbox\"" --skip-git-repo-check --json --output-last-message "$out")
  [[ -n "$MODEL" ]] && opts+=(--model "$MODEL")
  [[ -n "$EFFORT" ]] && opts+=(-c "model_reasoning_effort=\"$EFFORT\"")
  # shellcheck disable=SC2206
  [[ -n "${PAIR_CODEX_EXTRA:-}" ]] && opts+=($PAIR_CODEX_EXTRA)
  [[ "$prompt" == -* ]] && prompt=" $prompt"

  # codex exec appends piped stdin to the prompt and waits for EOF, which never comes if the host's stdin is an open pipe
  local rc=0
  if [[ -n "$sid" ]]; then
    AGENT_PAIR_PEER=1 codex exec "${opts[@]}" resume "$sid" "$prompt" </dev/null >"$events" 2>&1 || rc=$?
  else
    AGENT_PAIR_PEER=1 codex exec "${opts[@]}" "$prompt" </dev/null >"$events" 2>&1 || rc=$?
  fi
  [[ $rc -eq 0 ]] || return $rc

  cp "$out" "$reply"
  NEW_ID="$sid"
  if [[ -z "$NEW_ID" ]]; then
    if command -v jq >/dev/null 2>&1; then
      NEW_ID=$(jq -rR 'fromjson? | select(.type=="thread.started") | .thread_id // empty' "$events" 2>/dev/null | head -n1 || true)
    fi
    [[ -n "$NEW_ID" ]] || NEW_ID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$events" | head -n1 || true)
  fi
}

# ---------- peer: Claude Code ----------
run_claude() {
  local role="$1" prompt="$2" sid="$3" events="$4" reply="$5"
  command -v claude >/dev/null 2>&1 || die "claude command not found"

  local sys_prompt
  local -a opts=(-p --output-format json)
  [[ -n "$sid" ]] && opts+=(--resume "$sid")
  [[ -n "$MODEL" ]] && opts+=(--model "$MODEL")
  # CLAUDE_CODE_EFFORT_LEVEL takes precedence over --effort, so both get the same value; without an effort,
  # drop the inherited variable so the host's own setting does not leak into the peer
  local -a effort_env=(env -u CLAUDE_CODE_EFFORT_LEVEL)
  if [[ -n "$EFFORT" ]]; then
    opts+=(--effort "$EFFORT")
    effort_env=(env "CLAUDE_CODE_EFFORT_LEVEL=$EFFORT")
  fi
  # --allowedTools only pre-approves; it does not limit what is available. So: --tools limits the built-in tools,
  # --setting-sources user drops the reviewed repository's project/local settings (permission rules, hooks),
  # --strict-mcp-config drops MCP servers, and an explicit --permission-mode overrides any defaultMode.
  # User settings are kept on purpose: they may carry auth/provider config, and they are the user's own trust decision.
  # Read-only git commands can still write files through --output or run a configured diff tool through --ext-diff
  opts+=(--setting-sources user --strict-mcp-config --disallowedTools "Bash(git *--output*),Bash(git *--ext-diff*)")
  case "$role" in
    reviewer)
      opts+=(--tools "Read,Grep,Glob,Bash" --permission-mode dontAsk
             --allowedTools "${PAIR_CLAUDE_REVIEWER_TOOLS:-Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*)}")
      sys_prompt="You are the REVIEWER peer in an agent-pair cross-review, called by another AI coding agent. Do not modify any files. Do not delegate to other agents or use the agent-pair skill. Reply only with your review in the requested format."
      ;;
    writer)
      opts+=(--tools "Read,Grep,Glob,Edit,Write,Bash" --permission-mode acceptEdits
             --allowedTools "${PAIR_CLAUDE_WRITER_TOOLS:-Read,Grep,Glob,Edit,Write,Bash(git diff:*),Bash(git status:*)}")
      sys_prompt="You are the WRITER peer in an agent-pair cross-review, called by another AI coding agent who will review your changes. Implement what is asked within the stated scope, do not commit, do not delegate to other agents or use the agent-pair skill. Reply in the requested format."
      ;;
  esac
  opts+=(--append-system-prompt "$sys_prompt")

  # Parse stdout on its own: any stderr warning appended to it would break the JSON
  local out err; mktmp out; mktmp err
  local rc=0
  (cd "$ROOT" && printf '%s' "$prompt" | AGENT_PAIR_PEER=1 "${effort_env[@]}" claude "${opts[@]}") >"$out" 2>"$err" || rc=$?
  cat "$out" "$err" >"$events"
  [[ $rc -eq 0 ]] || return $rc

  local is_error; is_error=$(json_get "$out" is_error || true)
  [[ "$is_error" == "true" || "$is_error" == "True" ]] && return 3
  json_get "$out" result >"$reply" || return 4
  # claude may return a new session_id after resuming, so always trust the returned value
  NEW_ID=$(json_get "$out" session_id || true)
  [[ -n "$NEW_ID" ]] || NEW_ID="$sid"
}

# Which peer session a send would use: the --resume id, nothing for --new, otherwise the current binding
pick_session() {
  local id_file="$1" force_new="$2" resume_id="$3"
  if [[ -n "$resume_id" ]]; then
    printf '%s' "$resume_id"
  elif [[ $force_new -eq 0 && -s "$id_file" ]]; then
    cat "$id_file"
  fi
}

host_hint_for() { case "$1" in codex) echo claude ;; claude) echo codex ;; esac; }

# ---------- review range ----------
reviewed_file() { printf '%s/reviewed/%s' "$GLOBAL_DIR" "$1"; }

# The working tree, tracked and untracked files alike (honoring .gitignore), written as a tree object. A copy of the
# real index keeps git's stat cache, so only changed files are rehashed, and the user's index stays untouched
snapshot_tree() {
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local idx; mktmp idx
  rm -f "$idx"
  (
    cd "$ROOT" || exit 1
    real=$(git rev-parse --git-path index) || exit 1
    if [[ -f "$real" ]]; then cp "$real" "$idx" || exit 1; fi
    GIT_INDEX_FILE="$idx" git add -A . >/dev/null 2>&1 || exit 1
    GIT_INDEX_FILE="$idx" git write-tree
  )
}

record_reviewed() {
  local tree
  tree=$(snapshot_tree 2>/dev/null) && [[ -n "$tree" ]] || return 0
  mkdir -p "$GLOBAL_DIR/reviewed"
  printf '%s\t%s\n' "$ROOT" "$tree" >"$(reviewed_file "$1")"
}

cmd_snapshot() {
  snapshot_tree || die "cannot snapshot the working tree: not inside a git work tree"
}

cmd_last_reviewed() {
  local peer="$1" role="${2:-}" force_new=0 resume_id=""
  case "$role" in reviewer|writer) ;; *) die "role must be reviewer or writer" ;; esac
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --new) force_new=1; shift ;;
      --resume) [[ $# -ge 2 ]] || die "--resume needs a session id"; resume_id="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -z "$resume_id" ]] || valid_id "$resume_id" || die "malformed session id: $resume_id"
  resolve_host "$(host_hint_for "$peer")"

  local sid; sid=$(pick_session "$(host_dir)/$peer-$role.id" "$force_new" "$resume_id")
  [[ -n "$sid" ]] || return 0
  local f root tree; f=$(reviewed_file "$sid")
  [[ -f "$f" ]] || return 0
  IFS=$'\t' read -r root tree <"$f"
  [[ "$root" == "$ROOT" ]] || return 0
  git -C "$ROOT" cat-file -e "$tree^{tree}" 2>/dev/null || return 0
  echo "$tree"
}

cmd_branch_base() {
  local base="${1:-}" b mb
  [[ "$base" != -* ]] || die "usage: pair.sh branch-base [BRANCH]"
  git -C "$ROOT" rev-parse -q --verify HEAD >/dev/null || die "HEAD has no commits yet"
  if [[ -z "$base" ]]; then
    base=$(git -C "$ROOT" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -z "$base" ]]; then
      for b in main master; do
        if git -C "$ROOT" rev-parse -q --verify "refs/heads/$b" >/dev/null; then base="$b"; break; fi
      done
    fi
    [[ -n "$base" ]] || die "cannot tell the default branch (no origin/HEAD, main or master); pass it explicitly"
  fi
  git -C "$ROOT" rev-parse -q --verify "$base^{commit}" >/dev/null || die "unknown branch or commit: $base"
  mb=$(git -C "$ROOT" merge-base "$base" HEAD) || die "$base and HEAD have no common ancestor"
  echo "agent-pair: comparing against $base" >&2
  echo "$mb"
}

cmd_send() {
  local peer="$1" role="${2:-}"
  case "$role" in reviewer|writer) ;; *) die "role must be reviewer or writer" ;; esac
  shift 2

  local cli_model="" cli_effort="" force_new=0 resume_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model)  [[ $# -ge 2 ]] || die "--model needs a value"; cli_model="$2"; shift 2 ;;
      --effort) [[ $# -ge 2 ]] || die "--effort needs a value"; cli_effort="$2"; shift 2 ;;
      --new)    force_new=1; shift ;;
      --resume) [[ $# -ge 2 ]] || die "--resume needs a session id"; resume_id="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [[ $force_new -eq 1 && -n "$resume_id" ]] && die "--new and --resume cannot be used together"
  if [[ -n "$resume_id" ]]; then
    valid_id "$resume_id" || die "malformed session id: $resume_id"
    local owner o_peer o_role; owner=$(ledger_lookup "$resume_id")
    if [[ -n "$owner" ]]; then
      read -r o_peer o_role _ <<<"$owner"
      [[ "$o_peer" == "$peer" ]] || die "session $resume_id belongs to $o_peer and cannot be resumed by $peer"
      [[ "$o_role" == "$role" ]] || echo "agent-pair: note: session $resume_id was used as $o_role before, now as $role" >&2
    elif ! peer_session_exists "$peer" "$resume_id"; then
      echo "agent-pair: warning: no local record file for $peer session $resume_id, trying to resume anyway" >&2
    fi
  fi

  local up_peer up_role; up_peer=$(tr '[:lower:]' '[:upper:]' <<<"$peer"); up_role=$(tr '[:lower:]' '[:upper:]' <<<"$role")
  local model_var="PAIR_${up_peer}_${up_role}_MODEL" effort_var="PAIR_${up_peer}_${up_role}_EFFORT"
  MODEL="${cli_model:-${!model_var:-}}"
  EFFORT="${cli_effort:-${!effort_var:-}}"
  if [[ -n "$EFFORT" ]]; then
    local allowed
    case "$peer" in codex) allowed="minimal low medium high xhigh" ;; claude) allowed="low medium high xhigh max" ;; esac
    [[ " $allowed " == *" $EFFORT "* ]] || echo "agent-pair: warning: $peer effort is usually one of {$allowed}, got '$EFFORT'; passing it through anyway" >&2
  fi
  echo "agent-pair: $peer/$role this round model=${MODEL:-default} effort=${EFFORT:-default}" >&2

  local prompt
  if [[ $# -gt 0 ]]; then prompt="$*"; else prompt=$(cat); fi
  [[ -n "${prompt//[[:space:]]/}" ]] || die "prompt is empty"

  # A codex peer means a claude host, and vice versa
  resolve_host "$(host_hint_for "$peer")"
  [[ -n "$HOST_SID" ]] || echo "agent-pair: warning: cannot detect the host session id; bindings will be shared with other hosts and clear is unavailable" >&2

  local key="$peer-$role"
  local hdir; hdir=$(host_dir)
  local id_file="$hdir/$key.id" log="$LOG_DIR/$key.log"
  local sid; sid=$(pick_session "$id_file" "$force_new" "$resume_id")
  local events reply; mktmp events; mktmp reply

  NEW_ID=""
  local rc=0
  "run_$peer" "$role" "$prompt" "$sid" "$events" "$reply" || rc=$?

  mkdir -p "$LOG_DIR"
  { echo "===== $(date '+%F %T') peer=$peer role=$role model=${MODEL:-default} effort=${EFFORT:-default} host=${HOST_SID:-unknown} session=${sid:-new} rc=$rc ====="; cat "$events"; echo; } >>"$log"
  [[ $rc -eq 0 ]] || die "$peer call failed (rc=$rc), full output in $log"

  if [[ -n "$NEW_ID" ]] && valid_id "$NEW_ID"; then
    mkdir -p "$hdir"
    printf '%s' "$NEW_ID" >"$id_file"
    [[ "$NEW_ID" != "$sid" ]] && ledger_add "$peer" "$role" "$NEW_ID"
    record_reviewed "$NEW_ID"
    echo "agent-pair: SESSION $key $NEW_ID" >&2
  else
    rm -f "$id_file"
    echo "agent-pair: warning: could not get the session id; the next round will start a new session, check $log" >&2
  fi

  [[ -s "$reply" ]] || die "$peer returned no final reply, full output in $log"
  cat "$reply"
  [[ "$(tail -c1 "$reply")" == "" ]] || echo
}

cmd_lookup() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: pair.sh lookup <session id>"
  local info peer role host root; info=$(ledger_lookup "$id")
  if [[ -n "$info" ]]; then
    read -r peer role host root <<<"$info"
    echo "peer=$peer role=$role host=$host root=$root"
  else
    local p
    for p in codex claude; do
      if peer_session_exists "$p" "$id"; then echo "peer=$p role=unknown (not created by agent-pair, or missing from the ledger)"; return 0; fi
    done
    die "session $id not found"
  fi
}

cmd_status() {
  resolve_host ""
  echo "Host session: ${HOST_SID:-(not detected)}"
  echo "Bindings ($ROOT):"
  local found=0 f hdir; hdir=$(host_dir)
  for f in "$hdir"/*.id; do
    [[ -e "$f" ]] || continue
    found=1
    echo "  $(basename "$f" .id): $(cat "$f")"
  done
  [[ $found -eq 1 ]] || echo "  (none)"
  echo "Peer sessions created by this host session:"
  if [[ -n "$HOST_SID" && -f "$LEDGER" ]] && awk -F'\t' -v h="$HOST_SID" '$2==h {f=1} END {exit !f}' "$LEDGER"; then
    awk -F'\t' -v h="$HOST_SID" '$2==h {printf "  %s-%s: %s  (%s, %s)\n", $3, $4, $5, $1, $6}' "$LEDGER"
  else
    echo "  (none)"
  fi
  echo "Logs: $LOG_DIR"
}

cmd_reset() {
  local which="${1:-all}"
  resolve_host ""
  local hdir; hdir=$(host_dir)
  if [[ "$which" == "all" ]]; then
    rm -f "$hdir"/*.id
  elif [[ "$which" =~ ^(codex|claude)(-(reviewer|writer))?$ ]]; then
    rm -f "$hdir/$which".id "$hdir/$which"-*.id
  else
    die "reset takes all, codex, claude, or <peer>-<role> (e.g. codex-reviewer)"
  fi
  echo "agent-pair: unbound $which (the sessions themselves are kept and can be continued with --resume)"
}

cmd_clear() {
  local dry=0
  [[ "${1:-}" == "--dry-run" ]] && dry=1
  resolve_host ""
  [[ -n "$HOST_SID" ]] || die "cannot detect the host session id, so cannot tell which sessions belong to it. Set PAIR_HOST_SESSION and retry"

  local -a rows=()
  if [[ -f "$LEDGER" ]]; then
    while IFS= read -r line; do rows+=("$line"); done < <(awk -F'\t' -v h="$HOST_SID" '$2==h' "$LEDGER")
  fi

  local line ts host peer role id root rc deleted=0 failed=0
  for line in ${rows[@]+"${rows[@]}"}; do
    IFS=$'\t' read -r ts host peer role id root <<<"$line"
    if [[ $dry -eq 1 ]]; then
      echo "would delete $peer-$role $id ($ts, $root)"
      continue
    fi
    rc=0; delete_peer_session "$peer" "$id" || rc=$?
    case $rc in
      0) echo "deleted $peer-$role $id"; ledger_remove "$id"; rm -f "$(reviewed_file "$id")"; deleted=$((deleted + 1)) ;;
      2) echo "already gone $peer-$role $id"; ledger_remove "$id"; rm -f "$(reviewed_file "$id")" ;;
      *) echo "failed to delete $peer-$role $id (kept in the ledger, retry later)"; failed=$((failed + 1)) ;;
    esac
  done
  [[ ${#rows[@]} -gt 0 ]] || echo "this host session has not created any peer sessions"
  [[ $dry -eq 1 ]] && return 0

  # Unbind everything in every repository, including sessions picked up with --resume that this host did not
  # create (those are not deleted)
  rm -rf -- "$(host_sessions_dir)"
  echo "agent-pair: clear done, $deleted deleted, $failed failed, all bindings of this host session removed"
  [[ $failed -eq 0 ]]
}

first="${1:-}"; shift || true
case "$first" in
  codex|claude)
    sub="${1:-}"; shift || true
    case "$sub" in
      send) cmd_send "$first" "$@" ;;
      last-reviewed) cmd_last_reviewed "$first" "$@" ;;
      *) die "usage: pair.sh $first <send|last-reviewed> <reviewer|writer> ..." ;;
    esac
    ;;
  status) cmd_status ;;
  lookup) cmd_lookup "$@" ;;
  reset)  cmd_reset "$@" ;;
  clear)  cmd_clear "$@" ;;
  snapshot) cmd_snapshot ;;
  branch-base) cmd_branch_base "$@" ;;
  *) awk 'NR > 1 && /^#/ {print; next} NR > 1 {exit}' "$0"; exit 1 ;;
esac

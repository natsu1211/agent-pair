#!/usr/bin/env bash
# agent-pair 辅助脚本：主控方（Claude Code 或 Codex）通过它与协作方的同一个会话多轮对话。
#
# 用法:
#   pair.sh <codex|claude> send <reviewer|writer> [--new | --resume ID] [--model M] [--effort E] "prompt"
#                                                           # prompt 省略时从 stdin 读取
#   pair.sh status                                          # 查看当前主控方会话绑定和创建的协作方会话
#   pair.sh lookup <ID>                                     # 查询某个协作方会话 id 属于哪个 peer/role
#   pair.sh reset [all|codex|claude|codex-reviewer|...]     # 解除当前主控方会话的绑定（默认 all），不删除会话
#   pair.sh clear [--dry-run]                               # 永久删除当前主控方会话创建的全部协作方会话
#
# 第一个参数是"协作方"，也就是对方：
#   在 Claude Code 里用 -> codex（底层是 codex exec / codex exec resume）
#   在 Codex 里用       -> claude（底层是 claude -p / claude -p --resume）
#
# 角色与权限：
#   reviewer  只读。codex: sandbox_mode=read-only；claude: 禁用编辑工具，Bash 只放行 git 只读命令
#   writer    可改工作区文件。codex: sandbox_mode=workspace-write；claude: acceptEdits
#
# 会话选择（send）：
#   默认       接上当前主控方会话已绑定的协作方会话；没有绑定时新建
#   --new      忽略已有绑定，新建会话
#   --resume   接上指定 id 的协作方会话，并把它绑定到当前主控方会话
#   每轮结束都会在 stderr 打印 "agent-pair: SESSION <peer>-<role> <id>"
#
# 主控方会话：Claude Code 取 CLAUDE_CODE_SESSION_ID，Codex 取 CODEX_THREAD_ID，
#   通过向上查找父进程判断主控方是哪一个；可用 PAIR_HOST_SESSION 强制指定。
#
# 状态：
#   <仓库根>/.agent-pair/（自带 .gitignore）
#     sessions/<主控方会话>/<peer>-<role>.id  当前绑定的协作方会话 id
#     <peer>-<role>.log                       每轮完整输出，出错时看这里
#   ${AGENT_PAIR_HOME:-~/.agent-pair}/ledger.tsv
#     记录每个协作方会话由哪个主控方会话创建，clear 据此删除
#
# 模型与 effort，优先级从高到低：
#   1. send 的 --model / --effort 参数（只影响这一轮）
#   2. 环境变量 PAIR_<PEER>_<ROLE>_MODEL / PAIR_<PEER>_<ROLE>_EFFORT
#      例如 PAIR_CODEX_REVIEWER_MODEL、PAIR_CLAUDE_WRITER_EFFORT
#   3. 配置文件（KEY=value 格式，同样的变量名）：<仓库根>/.agent-pair/config.env 优先于 <skill目录>/config.env
#   4. 都没设置时，用对方 CLI 自己的默认值
#   effort 取值：codex 为 minimal|low|medium|high|xhigh；claude 为 low|medium|high|xhigh|max
#   （codex 通过 -c model_reasoning_effort 传入；claude 通过 --effort 和 CLAUDE_CODE_EFFORT_LEVEL 传入）
#
# 涉及权限的设置，只能通过环境变量或 <skill目录>/config.env 设置，仓库级配置里写了会被忽略：
#   PAIR_CODEX_EXTRA                       额外传给 codex exec 的参数（按空格切分）
#   PAIR_CLAUDE_REVIEWER_TOOLS             覆盖 claude 审查者的 --allowedTools（逗号分隔）
#   PAIR_CLAUDE_WRITER_TOOLS               覆盖 claude 编写者的 --allowedTools（逗号分隔）

set -euo pipefail

die() { echo "agent-pair: $*" >&2; exit 1; }

# 防递归：被调用的协作方进程里会带这个变量，它不能再去调用别人
if [[ -n "${AGENT_PAIR_PEER:-}" ]]; then
  die "当前进程本身是被 agent-pair 调用的协作方，不允许再调用其他 agent（防止互相递归调用）"
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$ROOT/.agent-pair"
mkdir -p "$STATE_DIR"
[[ -f "$STATE_DIR/.gitignore" ]] || echo '*' > "$STATE_DIR/.gitignore"

GLOBAL_DIR="${AGENT_PAIR_HOME:-$HOME/.agent-pair}"
LEDGER="$GLOBAL_DIR/ledger.tsv"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

MODEL_KEYS=""
for _p in CODEX CLAUDE; do for _r in REVIEWER WRITER; do MODEL_KEYS+=" PAIR_${_p}_${_r}_MODEL PAIR_${_p}_${_r}_EFFORT"; done; done
PERMISSION_KEYS="PAIR_CODEX_EXTRA PAIR_CLAUDE_REVIEWER_TOOLS PAIR_CLAUDE_WRITER_TOOLS"
unset _p _r

# 配置文件是 KEY=value 纯文本，只当数据读取，不执行。已设置的变量不覆盖，所以环境变量总是优先；
# 仓库级配置先加载，因此它优先于全局配置。仓库级配置可能来自不可信的仓库，只允许设置模型和 effort，
# 否则它能借 PAIR_CODEX_EXTRA 或 *_TOOLS 放宽协作方的沙箱和权限
load_config() {
  local file="$1" allowed="$2" line key val n=0
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      echo "agent-pair: 警告：$file 第 $n 行无法解析，已忽略" >&2; continue
    fi
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    if [[ " $allowed " != *" $key "* ]]; then
      echo "agent-pair: 警告：$file 第 $n 行的 $key 不是这里允许的配置项，已忽略" >&2; continue
    fi
    [[ -n "${!key+x}" ]] || printf -v "$key" '%s' "$val"
  done <"$file"
}

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for _old in "$STATE_DIR/config.sh" "$SKILL_DIR/config.sh"; do
  [[ -f "$_old" ]] && echo "agent-pair: 警告：已不再读取 ${_old}，请改写为同目录下的 config.env（KEY=value 格式）" >&2
done
unset _old
load_config "$STATE_DIR/config.env" "$MODEL_KEYS"
load_config "$SKILL_DIR/config.env" "$MODEL_KEYS $PERMISSION_KEYS"

TMP_FILES=()
cleanup() { [[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}"; return 0; }
trap cleanup EXIT
mktmp() { local f; f=$(mktemp); TMP_FILES+=("$f"); printf '%s' "$f"; }

# 从单个 JSON 对象文件里取顶层字段
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

# 会话 id 会拼进文件路径并用于删除，只接受字母、数字、- 和 _
valid_id() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

# ---------- 主控方会话 ----------
# 环境变量可能从更外层的 agent 继承下来（比如在 Claude Code 里启动的 Codex），
# 所以先沿父进程链找到最近的 claude/codex 进程，再取对应的变量
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

# $1：识别失败时假定的主控方（send 时由协作方推出）
resolve_host() {
  HOST_SID="${PAIR_HOST_SESSION:-}"
  [[ -n "$HOST_SID" ]] && return 0
  local kind; kind=$(detect_host_kind)
  [[ -n "$kind" ]] || kind="${1:-}"
  case "$kind" in
    claude) HOST_SID="${CLAUDE_CODE_SESSION_ID:-}" ;;
    codex)  HOST_SID="${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}" ;;
  esac
  if [[ -n "$HOST_SID" ]] && ! valid_id "$HOST_SID"; then HOST_SID=""; fi
  return 0
}

host_dir() { printf '%s/sessions/%s' "$STATE_DIR" "${HOST_SID:-unknown-host}"; }

# ---------- 账本：协作方会话 <- 创建它的主控方会话 ----------
# 每行：时间 \t 主控方会话 \t peer \t role \t 协作方会话 \t 仓库根
ledger_has() { [[ -f "$LEDGER" ]] && awk -F'\t' -v id="$1" '$5==id {f=1} END {exit !f}' "$LEDGER"; }

ledger_add() {
  local peer="$1" role="$2" id="$3"
  [[ -n "$HOST_SID" ]] || return 0
  ledger_has "$id" && return 0
  mkdir -p "$GLOBAL_DIR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$HOST_SID" "$peer" "$role" "$id" "$ROOT" >>"$LEDGER"
}

ledger_remove() {
  local id="$1" tmp
  [[ -f "$LEDGER" ]] || return 0
  tmp=$(mktmp)
  awk -F'\t' -v id="$id" '$5!=id' "$LEDGER" >"$tmp" && cat "$tmp" >"$LEDGER"
}

# ---------- 协作方会话文件 ----------
peer_session_exists() {
  local peer="$1" id="$2"
  case "$peer" in
    codex)
      find "$CODEX_DIR/sessions" "$CODEX_DIR/archived_sessions" -name "*$id.jsonl" -print 2>/dev/null | grep -q . ;;
    claude)
      compgen -G "$CLAUDE_DIR/projects/*/$id.jsonl" >/dev/null ;;
  esac
}

# 返回 0：已删除；2：本来就不存在；其他：删除失败
delete_peer_session() {
  local peer="$1" id="$2"
  valid_id "$id" || return 1
  case "$peer" in
    codex)
      command -v codex >/dev/null 2>&1 || return 1
      if (cd "$ROOT" && AGENT_PAIR_PEER=1 codex delete --force "$id") >/dev/null 2>&1; then return 0; fi
      peer_session_exists codex "$id" && return 1
      return 2
      ;;
    claude)
      local f found=0
      # 会话目录下的同名子目录存放子 agent 记录和大段工具输出
      for f in "$CLAUDE_DIR"/projects/*/"$id".jsonl "$CLAUDE_DIR"/projects/*/"$id"; do
        [[ -e "$f" ]] || continue
        rm -rf -- "$f"; found=1
      done
      [[ $found -eq 1 ]] && return 0
      return 2
      ;;
  esac
}

# ---------- 协作方：Codex ----------
run_codex() {
  local role="$1" prompt="$2" sid="$3" events="$4" reply="$5"
  command -v codex >/dev/null 2>&1 || die "找不到 codex 命令"
  local sandbox
  case "$role" in reviewer) sandbox="read-only" ;; writer) sandbox="workspace-write" ;; esac

  local out; out=$(mktmp)
  local -a opts=(-C "$ROOT" -c "sandbox_mode=\"$sandbox\"" --skip-git-repo-check --json --output-last-message "$out")
  [[ -n "$MODEL" ]] && opts+=(--model "$MODEL")
  [[ -n "$EFFORT" ]] && opts+=(-c "model_reasoning_effort=\"$EFFORT\"")
  # shellcheck disable=SC2206
  [[ -n "${PAIR_CODEX_EXTRA:-}" ]] && opts+=($PAIR_CODEX_EXTRA)
  [[ "$prompt" == -* ]] && prompt=" $prompt"

  local rc=0
  if [[ -n "$sid" ]]; then
    AGENT_PAIR_PEER=1 codex exec "${opts[@]}" resume "$sid" "$prompt" >"$events" 2>&1 || rc=$?
  else
    AGENT_PAIR_PEER=1 codex exec "${opts[@]}" "$prompt" >"$events" 2>&1 || rc=$?
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

# ---------- 协作方：Claude Code ----------
run_claude() {
  local role="$1" prompt="$2" sid="$3" events="$4" reply="$5"
  command -v claude >/dev/null 2>&1 || die "找不到 claude 命令"

  local sys_prompt
  local -a opts=(-p --output-format json)
  [[ -n "$sid" ]] && opts+=(--resume "$sid")
  [[ -n "$MODEL" ]] && opts+=(--model "$MODEL")
  # CLAUDE_CODE_EFFORT_LEVEL 的优先级高于 --effort，所以两者都设成同一个值；
  # 没指定 effort 时清掉继承来的环境变量，避免主控方自己的设置传给协作方
  local -a effort_env=(env -u CLAUDE_CODE_EFFORT_LEVEL)
  if [[ -n "$EFFORT" ]]; then
    opts+=(--effort "$EFFORT")
    effort_env=(env "CLAUDE_CODE_EFFORT_LEVEL=$EFFORT")
  fi
  case "$role" in
    reviewer)
      opts+=(--disallowedTools "Edit,Write,MultiEdit,NotebookEdit"
             --allowedTools "${PAIR_CLAUDE_REVIEWER_TOOLS:-Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*)}")
      sys_prompt="You are the REVIEWER peer in an agent-pair cross-review, called by another AI coding agent. Do not modify any files. Do not delegate to other agents or use the agent-pair skill. Reply only with your review in the requested format."
      ;;
    writer)
      opts+=(--permission-mode acceptEdits
             --allowedTools "${PAIR_CLAUDE_WRITER_TOOLS:-Read,Grep,Glob,Edit,Write,MultiEdit,Bash(git diff:*),Bash(git status:*)}")
      sys_prompt="You are the WRITER peer in an agent-pair cross-review, called by another AI coding agent who will review your changes. Implement what is asked within the stated scope, do not commit, do not delegate to other agents or use the agent-pair skill. Reply in the requested format."
      ;;
  esac
  opts+=(--append-system-prompt "$sys_prompt")

  local err; err=$(mktmp)
  local rc=0
  (cd "$ROOT" && printf '%s' "$prompt" | AGENT_PAIR_PEER=1 "${effort_env[@]}" claude "${opts[@]}") >"$events" 2>"$err" || rc=$?
  cat "$err" >>"$events"
  [[ $rc -eq 0 ]] || return $rc

  local is_error; is_error=$(json_get "$events" is_error || true)
  [[ "$is_error" == "true" || "$is_error" == "True" ]] && return 3
  json_get "$events" result >"$reply" || return 4
  # claude 恢复会话后可能返回新的 session_id，所以每轮都以返回值为准
  NEW_ID=$(json_get "$events" session_id || true)
  [[ -n "$NEW_ID" ]] || NEW_ID="$sid"
}

cmd_send() {
  local peer="$1" role="${2:-}"
  case "$role" in reviewer|writer) ;; *) die "角色应为 reviewer 或 writer" ;; esac
  shift 2

  local cli_model="" cli_effort="" force_new=0 resume_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model)  [[ $# -ge 2 ]] || die "--model 需要一个值"; cli_model="$2"; shift 2 ;;
      --effort) [[ $# -ge 2 ]] || die "--effort 需要一个值"; cli_effort="$2"; shift 2 ;;
      --new)    force_new=1; shift ;;
      --resume) [[ $# -ge 2 ]] || die "--resume 需要一个会话 id"; resume_id="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [[ $force_new -eq 1 && -n "$resume_id" ]] && die "--new 和 --resume 不能同时使用"
  if [[ -n "$resume_id" ]]; then
    valid_id "$resume_id" || die "会话 id 格式不对：$resume_id"
    local owner o_peer o_role; owner=$(ledger_lookup "$resume_id")
    if [[ -n "$owner" ]]; then
      read -r o_peer o_role _ <<<"$owner"
      [[ "$o_peer" == "$peer" ]] || die "会话 $resume_id 是 $o_peer 的会话，不能交给 $peer 接续"
      [[ "$o_role" == "$role" ]] || echo "agent-pair: 提示：会话 $resume_id 之前用作 ${o_role}，这次用作 $role" >&2
    elif ! peer_session_exists "$peer" "$resume_id"; then
      echo "agent-pair: 警告：本地没找到 $peer 会话 $resume_id 的记录文件，仍会尝试接续" >&2
    fi
  fi

  local up_peer up_role; up_peer=$(tr '[:lower:]' '[:upper:]' <<<"$peer"); up_role=$(tr '[:lower:]' '[:upper:]' <<<"$role")
  local model_var="PAIR_${up_peer}_${up_role}_MODEL" effort_var="PAIR_${up_peer}_${up_role}_EFFORT"
  MODEL="${cli_model:-${!model_var:-}}"
  EFFORT="${cli_effort:-${!effort_var:-}}"
  if [[ -n "$EFFORT" ]]; then
    local allowed
    case "$peer" in codex) allowed="minimal low medium high xhigh" ;; claude) allowed="low medium high xhigh max" ;; esac
    [[ " $allowed " == *" $EFFORT "* ]] || echo "agent-pair: 警告：$peer 的 effort 通常取 {$allowed}，收到的是 '$EFFORT'，仍会照传" >&2
  fi
  echo "agent-pair: $peer/$role 本轮 model=${MODEL:-默认} effort=${EFFORT:-默认}" >&2

  local prompt
  if [[ $# -gt 0 ]]; then prompt="$*"; else prompt=$(cat); fi
  [[ -n "${prompt//[[:space:]]/}" ]] || die "prompt 为空"

  # 协作方是 codex 说明主控方是 claude，反之亦然
  local host_hint; case "$peer" in codex) host_hint=claude ;; claude) host_hint=codex ;; esac
  resolve_host "$host_hint"
  [[ -n "$HOST_SID" ]] || echo "agent-pair: 警告：识别不到主控方会话 id，会话绑定会和其他主控方共用，clear 也无法使用" >&2

  local key="$peer-$role"
  local hdir; hdir=$(host_dir)
  local id_file="$hdir/$key.id" log="$STATE_DIR/$key.log"
  local sid=""
  if [[ -n "$resume_id" ]]; then
    sid="$resume_id"
  elif [[ $force_new -eq 0 && -s "$id_file" ]]; then
    sid=$(cat "$id_file")
  fi
  local events reply; events=$(mktmp); reply=$(mktmp)

  NEW_ID=""
  local rc=0
  "run_$peer" "$role" "$prompt" "$sid" "$events" "$reply" || rc=$?

  { echo "===== $(date '+%F %T') peer=$peer role=$role model=${MODEL:-default} effort=${EFFORT:-default} host=${HOST_SID:-unknown} session=${sid:-new} rc=$rc ====="; cat "$events"; echo; } >>"$log"
  [[ $rc -eq 0 ]] || die "$peer 调用失败（rc=${rc}），完整输出见 $log"

  if [[ -n "$NEW_ID" ]] && valid_id "$NEW_ID"; then
    mkdir -p "$hdir"
    printf '%s' "$NEW_ID" >"$id_file"
    [[ "$NEW_ID" != "$sid" ]] && ledger_add "$peer" "$role" "$NEW_ID"
    echo "agent-pair: SESSION $key $NEW_ID" >&2
  else
    rm -f "$id_file"
    echo "agent-pair: 警告：没能取到会话 id，下一轮会新开会话，请检查 $log" >&2
  fi

  [[ -s "$reply" ]] || die "$peer 没有返回最终回复，完整输出见 $log"
  cat "$reply"
  [[ "$(tail -c1 "$reply")" == "" ]] || echo
}

# 输出：peer role 主控方会话 仓库根
ledger_lookup() {
  [[ -f "$LEDGER" ]] || return 0
  awk -F'\t' -v id="$1" '$5==id {print $3, $4, $2, $6; exit}' "$LEDGER"
}

cmd_lookup() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "用法：pair.sh lookup <会话 id>"
  local info peer role host root; info=$(ledger_lookup "$id")
  if [[ -n "$info" ]]; then
    read -r peer role host root <<<"$info"
    echo "peer=$peer role=$role host=$host root=$root"
  else
    local p
    for p in codex claude; do
      if peer_session_exists "$p" "$id"; then echo "peer=$p role=unknown（不是 agent-pair 创建的，或账本里没有记录）"; return 0; fi
    done
    die "没有找到会话 $id"
  fi
}

cmd_status() {
  resolve_host ""
  echo "主控方会话：${HOST_SID:-（识别不到）}"
  echo "当前绑定（${ROOT}）："
  local found=0 f hdir; hdir=$(host_dir)
  for f in "$hdir"/*.id; do
    [[ -e "$f" ]] || continue
    found=1
    echo "  $(basename "$f" .id): $(cat "$f")"
  done
  [[ $found -eq 1 ]] || echo "  （没有）"
  echo "本主控方会话创建的协作方会话："
  if [[ -n "$HOST_SID" && -f "$LEDGER" ]] && awk -F'\t' -v h="$HOST_SID" '$2==h {f=1} END {exit !f}' "$LEDGER"; then
    awk -F'\t' -v h="$HOST_SID" '$2==h {printf "  %s-%s: %s  (%s, %s)\n", $3, $4, $5, $1, $6}' "$LEDGER"
  else
    echo "  （没有）"
  fi
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
    die "reset 参数应为 all、codex、claude，或 <peer>-<role>（如 codex-reviewer）"
  fi
  echo "agent-pair: 已解除绑定 ${which}（会话本身仍保留，可用 --resume 接续）"
}

cmd_clear() {
  local dry=0
  [[ "${1:-}" == "--dry-run" ]] && dry=1
  resolve_host ""
  [[ -n "$HOST_SID" ]] || die "识别不到主控方会话 id，无法判断哪些会话属于当前会话。可设置 PAIR_HOST_SESSION 后重试"

  local -a rows=()
  if [[ -f "$LEDGER" ]]; then
    while IFS= read -r line; do rows+=("$line"); done < <(awk -F'\t' -v h="$HOST_SID" '$2==h' "$LEDGER")
  fi

  local -a roots=("$ROOT")
  local line ts host peer role id root rc deleted=0 failed=0
  for line in ${rows[@]+"${rows[@]}"}; do
    IFS=$'\t' read -r ts host peer role id root <<<"$line"
    roots+=("$root")
    if [[ $dry -eq 1 ]]; then
      echo "将删除 $peer-$role ${id}（${ts}，${root}）"
      continue
    fi
    rc=0; delete_peer_session "$peer" "$id" || rc=$?
    case $rc in
      0) echo "已删除 $peer-$role $id"; ledger_remove "$id"; deleted=$((deleted + 1)) ;;
      2) echo "已不存在 $peer-$role $id"; ledger_remove "$id" ;;
      *) echo "删除失败 $peer-$role ${id}（保留在账本里，可重试）"; failed=$((failed + 1)) ;;
    esac
  done
  [[ ${#rows[@]} -gt 0 ]] || echo "当前主控方会话没有创建过协作方会话"
  [[ $dry -eq 1 ]] && return 0

  # 解除绑定，包括用 --resume 接上的、不是本会话创建的会话（它们本身不删除）
  local r
  for r in "${roots[@]}"; do
    [[ -d "$r/.agent-pair/sessions/$HOST_SID" ]] && rm -rf -- "$r/.agent-pair/sessions/$HOST_SID"
  done
  echo "agent-pair: clear 完成，删除 $deleted 个，失败 $failed 个，已解除当前主控方会话的全部绑定"
  [[ $failed -eq 0 ]]
}

first="${1:-}"; shift || true
case "$first" in
  codex|claude)
    sub="${1:-}"; shift || true
    [[ "$sub" == "send" ]] || die "用法：pair.sh $first send <reviewer|writer> \"prompt\""
    cmd_send "$first" "$@"
    ;;
  status) cmd_status ;;
  lookup) cmd_lookup "$@" ;;
  reset)  cmd_reset "$@" ;;
  clear)  cmd_clear "$@" ;;
  *) awk 'NR > 1 && /^#/ {print; next} NR > 1 {exit}' "$0"; exit 1 ;;
esac

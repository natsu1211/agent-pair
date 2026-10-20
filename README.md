# agent-pair

让 Claude Code 和 OpenAI Codex CLI 互相审查代码的 skill，两边都能用。

当前正在用的一方是**主控方**，另一方是**协作方**，在后台通过 CLI 调用。有两种分工：

| 模式 | 写代码 | 审查 |
|---|---|---|
| A：我写，对方审 | 主控方 | 协作方（只读） |
| B：对方写，我审 | 协作方 | 主控方（不改代码） |

由不是作者的一方来审查，才容易发现作者自己看不到的问题。所以两边的角色严格分开，审查方不会顺手改代码。

## 特点

- **多轮共用一个会话**：通过 `codex exec resume` / `claude -p --resume` 接续，协作方记得前几轮的意见，每轮只需发增量。
- **会话可接续、可清理**：每次结束都会返回协作方的会话 id，之后可以用 `--resume` 接着聊；`--clear` 一次删除当前会话创建的全部协作方会话。
- **权限收紧**：审查方只读；编写方只能改工作区文件，不能提交。
- **防递归**：被调用的协作方会带上 `AGENT_PAIR_PEER`，它不会再反过来调用对方。

## 依赖

- `git`、`bash`
- 协作方的 CLI，并已登录：
  - 在 Claude Code 里用时需要 `codex`，要支持 `codex exec resume`；`--clear` 还需要 `codex delete`
  - 在 Codex 里用时需要 `claude`
- 推荐安装 `jq`，没有时使用 `python3` 解析 JSON

## 安装

Claude Code：

```bash
git clone https://github.com/natsu1211/agent-pair.git ~/.claude/skills/agent-pair
```

Codex：放进 Codex 的用户级 skill 目录。两边都用的话，建议只 clone 一份，再建软链接：

```bash
mkdir -p ~/.agents/skills
ln -s ~/.claude/skills/agent-pair ~/.agents/skills/agent-pair
```

更新：`git -C ~/.claude/skills/agent-pair pull`

## 用法

直接用自然语言说，skill 会根据说法判断模式：

- "你来实现，让 codex 审一下" → 模式 A
- "让 codex 来写，你来审" → 模式 B
- 在 Codex 里："让 claude 审查这次改动"

也可以显式调用并带参数：

| 调用 | 行为 |
|---|---|
| `/agent-pair` | 接上当前会话已绑定的协作方会话，没有就新建 |
| `/agent-pair --new` | 协作方新开会话 |
| `/agent-pair --resume <id>` | 接上指定的协作方会话 |
| `/agent-pair --clear` | 永久删除当前会话创建过的全部协作方会话 |

在 Codex 里把 `/agent-pair` 换成 `$agent-pair`。

`--clear` 只删除当前主控方会话**创建的**协作方会话。用 `--resume` 接上的、由其他会话创建的协作方会话只解除绑定，不会删除。

## 配置

复制示例配置后修改：

```bash
cp ~/.claude/skills/agent-pair/config.env.example ~/.claude/skills/agent-pair/config.env
```

可以按"协作方 × 角色"分别设置模型和 effort，例如：

```
PAIR_CODEX_REVIEWER_MODEL=gpt-5
PAIR_CODEX_REVIEWER_EFFORT=high
PAIR_CLAUDE_WRITER_MODEL=opus
```

优先级从高到低：

1. 对话中指定（skill 会转成 `send` 的 `--model` / `--effort` 参数）
2. 同名环境变量
3. 项目级配置 `<仓库根>/.agent-pair/config.env`
4. 全局配置 `<skill 目录>/config.env`
5. 协作方 CLI 自己的默认值

配置文件是 `KEY=value` 纯文本，只作为数据读取，不会被执行。项目级配置可能来自别人的仓库，所以只允许设置模型和 effort。涉及权限的 `PAIR_CODEX_EXTRA`、`PAIR_CLAUDE_REVIEWER_TOOLS`、`PAIR_CLAUDE_WRITER_TOOLS` 只能写在环境变量或全局配置里。

## 权限与沙箱

协作方要联网访问自己的模型 API，还要写入自己的会话目录（`~/.codex` 或 `~/.claude`）。所以如果主控方开了沙箱，`scripts/pair.sh` 需要在沙箱外运行，执行时会弹出确认。

脚本给协作方设置的权限：

| | Codex | Claude Code |
|---|---|---|
| reviewer | `read-only` 沙箱 | 禁用编辑工具，Bash 只放行 `git diff/log/show/status` |
| writer | `workspace-write` 沙箱 | 自动接受编辑，Bash 只放行 `git diff/status` |

因此协作方通常跑不了测试，测试由主控方来跑。需要的话，可以在全局配置里用 `PAIR_CLAUDE_*_TOOLS` 放行具体命令，例如 `Bash(npm test:*)`。

## 文件与状态

| 位置 | 内容 |
|---|---|
| `<仓库根>/.agent-pair/` | 会话绑定和每轮完整日志（`<peer>-<role>.log`），自带 `.gitignore` |
| `~/.agent-pair/ledger.tsv` | 每个协作方会话由哪个主控方会话创建，供 `--clear` 使用；可用 `AGENT_PAIR_HOME` 改位置 |

主控方会话 id 由脚本自动识别：Claude Code 用 `CLAUDE_CODE_SESSION_ID`，Codex 用 `CODEX_THREAD_ID`。识别不到时可以设置 `PAIR_HOST_SESSION` 手动指定。

## 目录结构

```
SKILL.md               skill 本体，给 agent 读的流程说明
references/prompts.md  发给协作方的提示模板
scripts/pair.sh        与协作方通信、管理会话的脚本
config.env.example     配置示例
```

## License

MIT

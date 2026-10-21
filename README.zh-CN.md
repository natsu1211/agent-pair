<div align="center">

# agent-pair

让 Claude Code 和 OpenAI Codex CLI 相互审查代码的技能，可从任意一端发起。

[English](./README.md) | **中文**

</div>

---

你当前使用的智能体是**主智能体（host）**；另一个是**协作智能体（peer）**，由主智能体通过 CLI 在后台调用。支持两种分工方式：

| 模式 | 编写代码 | 审查代码 |
|---|---|---|
| A：我来写，对方审查 | 主智能体 | 协作智能体（只读） |
| B：对方写，我来审查 | 协作智能体 | 主智能体（不修改代码） |

由作者之外的另一方审查代码，更容易发现作者自身忽略的问题。因此，两种角色严格分离，审查方不会在审查过程中顺手修改代码。

## 特性

- **多轮复用同一会话**：通过 `codex exec resume` / `claude -p --resume` 继续会话，协作智能体会记住之前的反馈，每轮只需提供新增内容。
- **会话可恢复、可清理**：每次运行都会报告协作智能体的会话 ID，可通过 `--resume` 在之后继续；`--clear` 可一次性删除当前会话创建的所有协作会话。
- **严格限制权限**：审查方只读；编写方只能修改工作区文件，不能提交代码。
- **防止递归调用**：协作智能体运行时会设置 `AGENT_PAIR_PEER`，避免反过来调用主智能体。
- **使用你的语言回复**：技能本身以英文编写，但主智能体始终使用你所用的语言与你交流。

## 环境要求

- `git`、`bash`
- 已安装并登录协作方的 CLI：
  - 从 Claude Code 发起：需要支持 `codex exec resume` 的 `codex`；使用 `--clear` 还需要支持 `codex delete`
  - 从 Codex 发起：需要 `claude`
- 推荐安装 `jq`；未安装时使用 `python3` 解析 JSON

## 安装

Claude Code：

```bash
git clone https://github.com/natsu1211/agent-pair.git ~/.claude/skills/agent-pair
```

Codex：将技能放入 Codex 的用户级技能目录。如果两者都使用，只需克隆一次，再创建符号链接：

```bash
mkdir -p ~/.agents/skills
ln -s ~/.claude/skills/agent-pair ~/.agents/skills/agent-pair
```

更新：`git -C ~/.claude/skills/agent-pair pull`

## 使用方法

直接用自然语言提出要求，技能会根据你的描述判断模式：

- “实现这个功能，然后让 Codex 审查” → 模式 A
- “让 Codex 来写，你来审查” → 模式 B
- 在 Codex 中：“让 Claude 审查这次改动”

也可以显式调用并传入参数：

| 调用方式 | 行为 |
|---|---|
| `/agent-pair` | 继续与当前会话绑定的协作会话；如果没有，则新建会话 |
| `/agent-pair --new` | 新建协作会话 |
| `/agent-pair --resume <id>` | 继续指定的协作会话 |
| `/agent-pair --clear` | 永久删除当前会话创建的所有协作会话 |
| `/agent-pair branch` | 审查当前整个分支（见下文） |

在 Codex 中，使用 `$agent-pair` 代替 `/agent-pair`。

### 审查范围

- **默认只审查上次审查之后的新增改动。** 每轮结束后，脚本会为该协作会话记录工作区快照，下次审查以此为起点。如果此前没有审查记录，则审查未提交的改动，或主智能体刚编写的代码。
- **`branch`**：将当前整个分支与默认分支比较（依次使用 `origin/HEAD`、`main`、`master`），包括未提交的改动。使用 `branch develop` 可改为与其他分支比较。
- **也支持自然语言指定范围**：“审查最近 3 次提交”“只审查 src/api”“审查整个仓库”。

快照始终包含未提交的改动和新增的未跟踪文件。创建快照不会改动暂存区或工作区。

`--clear` 只会删除**由当前主会话创建**的协作会话。通过 `--resume` 接入、由其他会话创建的协作会话只会解除绑定，不会被删除。

## 配置

复制示例配置并编辑：

```bash
cp ~/.claude/skills/agent-pair/config.env.example ~/.claude/skills/agent-pair/config.env
```

可按协作智能体和角色分别设置模型与推理强度，例如：

```
PAIR_CODEX_REVIEWER_MODEL=gpt-5
PAIR_CODEX_REVIEWER_EFFORT=high
PAIR_CLAUDE_WRITER_MODEL=opus
```

优先级从高到低依次为：

1. 对话中指定的设置（技能会将其转换为 `send` 的 `--model` / `--effort` 参数）
2. 同名环境变量
3. 项目配置 `<repo root>/.agent-pair/config.env`
4. 全局配置 `<skill dir>/config.env`
5. 协作方 CLI 自身的默认设置

配置文件采用纯文本 `KEY=value` 格式，仅作为数据读取，不会执行。项目配置可能来自他人的仓库，因此只允许设置模型与推理强度。与权限有关的 `PAIR_CODEX_EXTRA`、`PAIR_CLAUDE_REVIEWER_TOOLS` 和 `PAIR_CLAUDE_WRITER_TOOLS` 仅在环境变量或全局配置中生效。

## 权限与沙箱

协作智能体需要通过网络访问自身的模型 API，并写入自身的会话目录（`~/.codex` 或 `~/.claude`）。因此，如果主智能体在沙箱中运行，`scripts/pair.sh` 就需要在沙箱外执行，此时你会收到授权提示。

脚本授予协作智能体的权限如下：

| | Codex | Claude Code |
|---|---|---|
| 审查方 | `read-only` 沙箱 | 禁用编辑工具，Bash 仅允许 `git diff/log/show/status` |
| 编写方 | `workspace-write` 沙箱 | 自动接受编辑，Bash 仅允许 `git diff/status` |

Claude 协作智能体还会忽略被审查仓库的 `.claude` 项目级和本地设置，以及所有 MCP 服务器，避免被审查的代码扩大其权限；同时禁止 git 的 `--output` 和 `--ext-diff` 选项。

Claude 协作智能体的隔离存在以下已知限制：

- 用户级设置（`~/.claude/settings.json`）仍然生效，因为其中可能保存认证或服务提供方配置。因此，用户级的 `Bash(*)` 等允许规则也会作用于协作智能体。
- `git diff` / `git log` 仍会运行 git 配置中的外部 diff 工具（`diff.external`）和 textconv 过滤器。如果这些配置指向仓库内的脚本，被审查的改动就可能改变其实际执行内容，而协作智能体会在沙箱外运行这些命令。未启用沙箱的 Claude Code 主智能体原本也会执行相同命令，但 Codex 等启用沙箱的主智能体通常会在沙箱内执行，因此在这种情况下确实扩大了执行权限。

因此，协作智能体通常无法运行测试，测试由主智能体执行。如有需要，可通过全局配置中的 `PAIR_CLAUDE_*_TOOLS` 放行特定命令，例如 `Bash(npm test:*)`。

## 文件与状态

| 位置 | 内容 |
|---|---|
| `~/.agent-pair/sessions/` | 按仓库记录各主会话绑定的协作会话 |
| `~/.agent-pair/logs/` | 按仓库保存每轮的完整输出（`<peer>-<role>.log`） |
| `~/.agent-pair/ledger.tsv` | 记录各协作会话由哪个主会话创建，供 `--clear` 使用 |
| `~/.agent-pair/reviewed/` | 各协作会话上一轮结束后的工作区快照，作为默认审查起点 |
| `<repo root>/.agent-pair/config.env` | 可选的项目配置；仅读取，不会写入 |

可通过 `AGENT_PAIR_HOME` 修改 `~/.agent-pair` 下所有内容的存放位置。脚本不会向你的仓库写入文件。

脚本会自动检测主会话 ID：在 Claude Code 中读取 `CLAUDE_CODE_SESSION_ID`，在 Codex 中读取 `CODEX_THREAD_ID`。如果检测失败，可手动设置 `PAIR_HOST_SESSION`。

## 目录结构

```
SKILL.md               技能本身：智能体遵循的工作流程
references/prompts.md  发送给协作智能体的提示词模板
scripts/pair.sh        与协作智能体通信并管理会话
config.env.example     示例配置
```

## 许可证

MIT

# 本机部署层

这个目录只服务于本机部署，不是上游项目的一部分。`local/deploy` 的基线始终是 `upstream/main`，本目录中的文件和本机部署补丁放在 `local/deploy` 分支上维护。

## 运行模型

- 中台是一个前台常驻进程：`agent-autoloop up`。不安装 macOS LaunchAgent，也不在退出后自动拉起。
- 停止服务用 `Ctrl-C`，或向该进程发送 `SIGTERM`。
- hub 监听 `127.0.0.1:3350`，不开放公网端口。
- hub、worker、桌面通知由 `~/.agent-autoloop/config.json` 决定是否在同一进程启动。
- 飞书使用内置 `feishu` 通道：卡片按钮直接回调中台，不跳转工作台。通知使用独立飞书应用和 `lark-cli` profile，避免与 Hermes 争夺同一应用的长连接。
- 运行时数据、密钥和 `hub.db` 都在 `~/.agent-autoloop/`，不进入 Git。

## 文件

| 文件 | 用途 |
|---|---|
| `rules.local.json` | 本机 Agent、来源、通道和规则快照，不含密钥 |
| `workbuddy-command.settings.json` | WorkBuddy Command 的本机文件与命令权限模板 |
| `bin/lark-cli-autoloop` | 固定使用 `agent-autoloop` profile 的 `lark-cli` 包装器；安装到 `~/.agent-autoloop/bin/lark-cli-autoloop` |
| `config.example.json` | `~/.agent-autoloop/config.json` 的结构参考，不含密钥 |
| `env.example` | `workspace.env` 和 `agent.env` 的键名说明，不含真实值 |
| `bootstrap.sh` | 检查前置条件，或在显式要求时安装两份配置和飞书 CLI 包装器 |

本机配置快照假设这些路径：

```text
workspace repo   /Users/zhangjiaxing/Documents/workspace
autoloop home    ~/.agent-autoloop
workspace skill  <workspace>/.codebuddy/skills/workspace-url
review skill     <workspace>/.codebuddy/skills/workspace-url-failure-review
skill links      ~/.codebuddy/skills/{workspace-url,workspace-url-failure-review}
staging          <workspace>/content/.automation/url
review cwd       <workspace>/content/.automation/url-failure-review
WorkBuddy Node   ~/.workbuddy/binaries/node/versions/22.22.2-6/bin/node
```

路径变化后，先改 `rules.local.json`、权限模板和 `env.example`，再重新安装配置。

## 首次部署

开发依赖只用于检查，不进入运行时：

```bash
cd /Users/zhangjiaxing/Documents/agent-autoloop
npm ci
```

先准备两个权限为 `0600` 的环境文件。键名见 `env.example`：

```bash
cp local/deploy/env.example ~/.agent-autoloop/workspace.env
cp local/deploy/env.example ~/.agent-autoloop/agent.env
chmod 600 ~/.agent-autoloop/workspace.env ~/.agent-autoloop/agent.env
```

环境变量分三处，不能混用：

| 位置 | 用途 |
|---|---|
| workspace 仓库的 `.env` | `AUTOLOOP_SOURCE_KEY`、`AUTOMATION_API_TOKEN`、autoloop 地址和 switch |
| `~/.agent-autoloop/workspace.env` | `workspace-task` 调 workspace 内部 API，token 与 `AUTOMATION_API_TOKEN` 相同 |
| `~/.agent-autoloop/agent.env` | `workbuddy-command` 的模型 API key，只交给 Agent 进程 |

按文件用途填值，不要提交任何真实值。生成 workspace 来源密钥：

```bash
node --disable-warning=ExperimentalWarning bin/agent-autoloop.ts key new source workspace
```

命令只打印新密钥，不会改写配置。把输出写入 workspace 仓库 `.env` 的 `AUTOLOOP_SOURCE_KEY`，不要写进文档或 shell 历史。内部 API token 自行生成一个高熵值，workspace `.env` 的 `AUTOMATION_API_TOKEN` 与 `workspace.env` 的 `WORKSPACE_AUTOMATION_TOKEN` 必须一致。

安装本机配置。命令会先备份已有的 `rules.json` 和 `workbuddy-command.settings.json`，再写入模板：

```bash
./local/deploy/bootstrap.sh --install-config
```

它不会生成或覆盖 `config.json`、`workspace.env`、`agent.env`、`master.key`，也不会安装系统服务。首次机器如果没有 `config.json`，先用 `init --no-service` 初始化，再执行上面的安装命令。`config.example.json` 只用于核对结构和排查，不要用占位密钥覆盖已经初始化好的 `config.json`。

## 启停与验证

启动，终端保持前台：

```bash
cd /Users/zhangjiaxing/Documents/agent-autoloop
export PATH="/opt/homebrew/bin:$PATH"
node --disable-warning=ExperimentalWarning bin/agent-autoloop.ts up
```

另开终端验证：

```bash
cd /Users/zhangjiaxing/Documents/agent-autoloop
node --disable-warning=ExperimentalWarning bin/agent-autoloop.ts check
node --disable-warning=ExperimentalWarning bin/agent-autoloop.ts doctor
node --disable-warning=ExperimentalWarning bin/agent-autoloop.ts status
curl -fsS http://127.0.0.1:3350/healthz
```

URL 任务查看：

```bash
node --disable-warning=ExperimentalWarning bin/agent-autoloop.ts status
node --disable-warning=ExperimentalWarning bin/agent-autoloop.ts why <run>
```

失败巡检默认每天 09:00 运行。需要立即验证时：

```bash
node --disable-warning=ExperimentalWarning bin/agent-autoloop.ts run "URL 失败巡检"
```

巡检查询失败、完成但不完整和长时间运行三类任务并发出确认卡片，不自动重跑。回答后由同一 Skill 调用工作台内部 API，任务重新入队、记录为忽略，或对卡住的运行做安全恢复。

巡检现在覆盖失败、完成但不完整、运行超过 30 分钟三类任务；第三类卡片使用“重新处理 / 继续等待”，只有用户选择重新处理时才恢复卡住的运行。

飞书通知验证：

```bash
node --disable-warning=ExperimentalWarning bin/agent-autoloop.ts doctor
sqlite3 -header -column ~/.agent-autoloop/hub.db \
  "select channel,card_id,version,ref,error from deliveries where channel='feishu' order by first_try_at desc limit 5;"
```

飞书的 key 必须通过 `agent-autoloop key new channel feishu` 生成，并在 `config.json` 中使用同名通道项。`lark` 指向包装器，确保只使用独立的 `agent-autoloop` profile。应用需要开启机器人能力，并订阅 `card.action.trigger`（长连接）；卡片读取还需要 `im:message:readonly`。

飞书卡片收到回答后由内置通道直接调用 `hub.answer`，随后 patch 原消息；不需要打开工作台，也不需要公网回调地址。

## 当前 URL 集成

当前生产链路只有一条：

```text
workspace outbox
  -> POST /v1/events
  -> 规则“URL 内容处理”
  -> workbuddy-command
  -> workspace-url Skill
  -> prepare -> Agent 写 content/.automation/url -> finalize
  -> workspace 校验、写不可变版本、发 content.url.completed
```

workspace 中仍保留 inline URL Worker，作为本地回退路径。生产 `.env` 必须是：

```text
AUTOMATION_EVENTS_ENABLED=1
AUTOMATION_API_ENABLED=1
URL_WORKER_ENABLED=0
```

这不是新旧双跑。旧 Worker 只在开关打开时启动；当前开关关闭，不参与生产处理。回退时先暂停 autoloop 规则，再切换开关，不能同时打开两条链路。旧 `.url-jobs` 和 inline Worker 的清理放到新链路稳定运行之后单独执行，清理前先确认数据库、`content/` 和封面目录有可恢复备份。

## 维护方式

修改本机配置后，把已验证的实际配置同步回本目录，并检查是否带入密钥。部署快照只包含配置和脚本，不包含运行记录。

通用改进优先提 upstream；只对本机路径、WorkBuddy 启动方式、权限和部署环境生效的改动留在 `local/deploy`。更新上游时保持 `main` 干净，在 `local/deploy` 上合并 `upstream/main`。

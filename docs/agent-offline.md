# 助手：连不上服务器时在手机上继续用（第 10 期）

> 状态：**Flutter 端和服务端已实现，自动化测试通过；没有在真机和真实模型上验收**（见 §8）· 2026-10-16
> 前置：[`agent-design.md`](agent-design.md)（助手本体）、[`agent-history-and-files.md`](agent-history-and-files.md)（历史与文件）。
> 范围：服务端新增两个接口；Flutter 新增一个本机助手。**H5 不做**：局域网 HTTP 下页面本身要服务端在线才能打开（见 `architecture.md` §3.3），而且浏览器直连模型会遇到跨域限制。

## 1. 要解决的问题

服务端在 Mac 上、手机走局域网，出门就连不上服务端；以前助手整个不能用，而 AI 解读（客户端直连模型）可以。现在要让助手也能用：**手机有外网，但连不上家里服务端**。完全没有网络不在范围内（需要端侧模型，质量和包体都不合适）。

## 2. 已定的决定

| 问题 | 决定 |
|---|---|
| "离线"指什么 | 连不上服务端，但手机能上网（直连模型） |
| 离线出的题要不要回传 | **要**。回传后和服务端的助手出的题一样：入库、同步到各端 |
| API Key 能不能下发到手机 | 可以（和 AI 解读一样，用访问令牌换） |
| H5 | 不做 |

## 3. 总体思路

```
                    ┌─ 服务端可达 ──→ HttpAgentApi（原来的，服务端跑循环）
Flutter AgentApi ───┤
 （HybridAgentApi） └─ 连不上   ──→ LocalAgentApi（本机跑同一个循环）
                                      ├─ 模型：直连，Anthropic Messages 协议
                                      ├─ 工具：在本机的讲义 / 题库 / 作答记录上跑
                                      └─ 出的题：先进本机题库，下次同步上传，服务端重新检查
```

- **控制器和页面基本没改**：本机助手实现同一个 `AgentApi`，吐出同样的 `AgentEvent`。新增一个 `AgentLocalEvent`，页面据此给回答打上"本机助手（离线）"的标签，并在顶部显示说明。
- **先试服务端**。只有"根本连不上"（连接超时 / 连接错误）才切到本机；服务端回了 401、404，或回答到一半断了，都不切（服务端已经收到问题，切过去会重复）。切过去之后一分钟内不再试服务端，免得每条消息都等 8 秒连接超时；一分钟后再试，通了就回到服务端。
- **说明文字和工具不抄**：`GET /agent/local-spec` 把系统提示词、工具说明（名字、描述、JSON Schema）、各项上限、模型地址和 Key 交给手机，随同步保存。服务端改了提示词，下次同步手机就跟着变；`version` 是内容的哈希。手机上没有任何提示词文字。
- **规则要抄，但有共用的测试**：题目的校验（`validate.go`）和查重（`dedupe.go`）在 Dart 里重写了一份，用来当场告诉模型哪里不合格。两端共用 `api/testdata/question_rules.json`（Go：`server/internal/pipeline/rules_golden_test.go`，Dart：`app/test/local_agent_test.dart`）；改了规则不改用例，其中一边会失败。

## 4. 服务端

| 接口 | 作用 |
|---|---|
| `GET /api/v1/agent/local-spec` | 令牌鉴权。返回 `version`、`prompt`、`tools`、`limits`、`model`（`base_url`、`api_key`、`model`、`max_tokens`、`effort`、`vision`）、`dedupe_threshold`。助手角色没绑定 Anthropic 协议的模型时 404。不含 `read_attachment`（文件在服务端对话里，手机上没有） |
| `POST /api/v1/agent/questions` | 令牌鉴权。一次最多 20 道离线出的题，每道带手机自己取的 id（ULID）。**服务端不信任手机**：走和服务端助手出的题同一套检查（规则、和整个题库查重、绑了独立复核模型就复核），通过的按"助手出的题"处理（默认直接发布，后台开了"先审核"就进审核队列）。id 就是题目的 id，所以 `/agent/drafts/{id}/accept\|discard` 和下一次同步都对得上。重复上传是幂等的；上传前被学习者取消采纳的题不会复活 |
| `POST /api/v1/ai/usage` | 新增可选字段 `role`（`explain` 默认，或 `agent`；`agent` 时 `question_id` 是对话 id）。后台用量页上能看到 `agent / client` |

实现要点：`agent.BuildSpec()` 用和对话时同一批 `tool` 定义生成说明（`propose_questions` 等只取说明，不执行）；`agentDrafter.Propose` 加了 `ClientID`，其余逻辑原样复用。

## 5. Flutter

数据库升到 **v8**：`questions` 加 `local_state` / `local_note` / `agent_conv` 三列（默认空，已有题不受影响），新增 `agent_conversations`、`agent_messages` 两张表（本机的对话）。

`local_state`：

| 值 | 含义 |
|---|---|
| `''` | 服务端的题（或已经和服务端对上了） |
| `pending` | 本机写的，还没上传。在本机题库里（`sync_seq` 为 0），学习者可以马上刷 |
| `refused` | 服务端没通过，已隐藏，原因在 `local_note` |
| `discard` / `adopt` | 服务端已有的题，离线时被取消采纳 / 重新采纳，等下次同步告诉服务端 |

`app/lib/data/local_agent/`：

| 文件 | 内容 |
|---|---|
| `agent_spec.dart` | `LocalAgentSpec` 与 `AgentSpecStore`（shared_preferences，键 `agent.spec`） |
| `anthropic_chat.dart` | Anthropic Messages 流式客户端：思考块带签名原样回传、工具调用参数分片拼接、`max_tokens` 截断时丢弃工具调用、网关噪声过滤、错误翻译。不发 `tool_choice` |
| `agent_tools.dart` | 6 个只读工具 + `propose_questions` + `list_drafts` 的移植，行为与 Go 版一致（排序、截断、`note` 文案） |
| `question_rules.dart` | 校验、归一化、查重。NFKC 只折叠全角和带圈数字，服务端用完整的 NFKC，服务端有最终决定权 |
| `local_drafter.dart` | 出题：校验 → 查重（含本对话已写的）→ 写入本机题库 → 替换旧题 |
| `local_agent.dart` | 对话循环：最多 `max_rounds` 轮、工具并行带 15 秒超时、轮数用完再问一次、虚构链接过滤（`LinkFilter`）、每次模型调用上报用量（`role=agent`） |
| `local_agent_store.dart` | 本机对话与历史（最多 30 条 / 2.4 万字，规则同服务端），题目的取消 / 重新采纳 |
| `local_agent_api.dart` | `LocalAgentApi` 和 `HybridAgentApi` |

同步（`SyncService.run`）新增，且**放在最前面**（题要先于对这些题的作答到达服务端）：

1. `_pushAgentQuestions`：上传 `pending` 且未被取消采纳的题。服务端回 `published` → 保留；`needs_review` → 暂时隐藏，通过后随同步回来；没通过 → `refused` 并隐藏，同步结果里提示"有 N 道离线出的题没通过服务器检查，已下线"。404（旧服务端）、401 留着以后再传。
2. `_pushAgentDecisions`：把离线时的取消 / 重新采纳告诉服务端。
3. 拉题时把 `local_state` 清掉：回来的题用服务端的版本覆盖本机那一行。
4. `_fetchAgentSpec`：取本机助手的配置；服务端没有助手（404）就删掉本机的。

界面：对话页顶部一条说明（"连不上服务器，正在用本机助手回答（离线）…"，带"重试"），每条本机回答前一个小标签。历史页是服务端列表和本机列表的合并；离线且本机没有历史时仍显示"连不上服务器"。

## 6. 取舍与限制

- **本机没有独立复核**：手机上没有复核模型的 Key。上传时服务端会补做（绑了复核模型的话），不一致的拒绝。本机出的题在卡片上显示"未经独立复核"，和服务端没绑复核模型时一样。
- **没有每日 token 预算**：和 AI 解读一样，直连模型绕过服务端的 `Guard`，只有每次调用的 `max_tokens` 上限。用量事后上报，后台能看到。
- **Key 明文存在手机上**（和 AI 解读一样）。
- **不能传文件**（离线时）：上传按钮会提示"连不上服务器"。图片同理，状态里 `vision` 为 false。
- **在服务端开始的对话，到本机继续**：控制器把已显示的消息当历史一起送过来，本机据此继续并存一份；之后回到有服务端的状态再继续这场对话，服务端只有它自己那部分历史（本机那几轮不会合并回去）。
- **本机的对话不上传服务端**：只在这台手机上。别的设备看不到，卸载 App 就没了。出的题则会上传，不受影响。
- 同一场对话最多 30 道题的上限，本机按本机的数，服务端上传时按服务端的数；超了的会被服务端拒绝。

## 7. 没有改动的

H5、后台页面、`/agent/chat` 与历史、附件接口、服务端的 Agent 本体都没动（`Propose` 只加了可选的 `ClientID`）。

## 8. 验证到什么程度

- Go：全部测试通过（含新增 `TestAgentLocalSpec`、`TestAgentUploadQuestions`、`TestAgentUsageReportedByApps`、共用用例 `TestGoldenValidateQuestion` / `TestGoldenDedupe`）。
- Flutter：全部测试通过。新增 `app/test/local_agent_test.dart`（规则与共用用例、过滤器、工具、Anthropic 客户端的流解析、本机循环、本机存储、服务端优先与回退、同步），以及页面和迁移（v7 → v8）各一个用例。
- **没有做**：在真机 / 模拟器上断开服务端实际走一遍；连真实模型跑一次本机出题并上传；DeepSeek 以外的 Anthropic 协议网关。第一次真机验收时建议：同步一次 → 关掉 Mac 上的服务 → 提问、出题 → 打开服务 → 同步，确认题进了服务端、没丢作答。

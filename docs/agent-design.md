# 学习 / 出题助手（Agent）改造方案

> 状态：设计稿 v1；第 1、2 期（服务端）已实现并提交，第 3 期（Flutter）代码已写完、待验证，详见 §0 · 日期：2026-10-08
> 前置：第 0 期（模型在后台配置）、第 0.5 期（AI 解读用量上报）已完成，见 [`architecture.md`](architecture.md) §4.4、§7.6。
> 范围：服务端新增一个对话式助手，**学习**和**创建题目**两种用法；Flutter 和 H5 都是它的薄客户端。

---

## 0. 实施进度

| 期 | 内容 | 状态 | 验证到什么程度 |
|---|---|---|---|
| 设计 | 本文、DeepSeek 兼容性笔记 | 已提交（`d11d465`） | — |
| 第 1 期 | 服务端核心 + 学习模式：`Converser`、对话循环、6 个学习工具、`/agent/status`、`/agent/chat`、后台"测试"按钮的兼容性探针 | 已提交（`b122d18`） | Go 全部测试（含竞态检测）通过；DeepSeek 真实端点的工具往返探针通过（`TestLive_ToolLoop`）。**还没有用真实模型从头到尾跑过一次 `/agent/chat`**（curl 验收待做） |
| 第 2 期 | 出题模式：迁移 `00014`、`propose_questions` / `list_drafts`、独立复核、草稿的采纳 / 丢弃 / 恢复 / 清理、审核页"来源：助手" | 已提交（`b122d18`，与第 1 期同一提交，见下） | 同上；独立复核、草稿相关用例只用假模型测过 |
| 第 3 期 | Flutter：数据层、控制器、对话页、草稿卡片、链接跳转、三处入口、令牌横幅 | 代码与自动化测试完成，**尚未在真机 / 模拟器上验收** | `flutter analyze lib test` 只剩一条早已存在的 info；全部 311 个测试通过（原有 276 + `app/test/agent_test.dart` 35 个） |
| 第 4 期 | H5 对话页与入口、设置页令牌项、后台用量页显示对话 id、OpenAPI、architecture 文档 | 未开始 | — |

**第 3 期还差什么**

1. `app/test/agent_test.dart`（SSE 解析、历史拼装、控制器状态机、`HttpAgentApi`、对话页与入口的 Widget 测试）已全部通过，约 3 秒跑完。此前"超过 400 秒不结束"并不是用例卡住，而是在终端代理环境下 `flutter_tester` 连不上；干净环境里没有问题。跑通时修了两处：令牌错 / 服务器无助手时，Riverpod 3 对失败的 `FutureProvider` 默认自动退避重试，横幅一直出不来，现在给 `agentStatusProvider` 关掉重试（`retry: (_, _) => null`）；两个控制器用例没有持有 `autoDispose` 的控制器，状态在两次读取之间被销毁，补了 `listen`。
2. 没有在真机或模拟器上走过验收流程（讲义页提问 → 点引用跳转 → 题库页出题 → 采纳）。
3. 与方案的差别：
   - 对话 id 由客户端生成（出题模式存在本机，重进页面用它取回草稿卡片），不是等服务端在 `start` 事件里发。
   - 讲义页的“问 AI”“用这一节出题”做成顶栏的两个图标按钮，不是页尾按钮；题库详情页的两个入口在“已填服务器地址”时才显示。
   - “让它改改”不新增接口：把“请修改这道草稿（draft_id：…）：”预填进输入框，由助手用 `replaces` 重新提交。
   - `QuizMarkdown` 新增 `onTapLink` 参数，用来拦截 `lesson:` / `question:` 链接；`question:` 链接打开只读的底部弹层。
   - `Repository` 新增 `bank(id)`、`question(id)`。

**提交说明**：第 1、2 期的服务端代码是在同一批文件上叠加写成的，没法干净地拆开，所以合成了一个提交（`b122d18`）。

**已知的遗留与风险**

- DeepSeek 网关会把 `<ds_safety>…</ds_safety>` 漏进正文，偶尔还会把回答截短；标记已被过滤，但截短的回答无法修复（后台“测试”会给出警告）。
- 后台 `POST /admin/questions/{id}/approve` 对 `draft` 状态的题放行，管理员可按 id 直接发布一道草稿，绕过“用户采纳”。
- 对话草稿 20 道的上限、独立复核的预算耗尽分支，只有代码，没有专门的测试用例。
- 用量页“调用明细”里，助手那几行的对话 id 显示在“题目”一列（与 AI 解读共用 `ref_id`），第 4 期处理。

---

## 1. 目标与非目标

### 1.1 目标

1. **学习**：围绕自己的讲义和题库答疑。能讲解某一节、解释某道题为什么这样答、根据作答记录指出薄弱处并出几道练习。
2. **创建题目**：按指定的章节、题型、难度和数量出题。题目带原文出处，经过与现有流水线同一套校验，由使用者决定是否采纳。
3. **一处实现，多端使用**：助手逻辑只在服务端写一份；Flutter 和 H5 只负责对话界面和草稿卡片。
4. **用量可见**：助手的每次模型调用都写入 `llm_call_log`，在后台用量页查询，并计入每日 token 预算。

### 1.2 非目标（本次不做）

- 联网搜索，或让模型凭自己的知识出题。出题必须挂在某一节讲义上，保持"每题有原文出处"。
- 对话的服务端持久化与跨设备同步（见 §12）。
- 把 App 里现有的"AI 解读"迁到服务端（二者并存，见 §11.1）。
- 用户上传讲义之外的材料出题（`add_material`，见 §12）。
- 自动发布。助手出的题默认进审核队列（决定 2）。

---

## 2. 已确认的决定

| # | 决定 | 来源 |
|---|---|---|
| 1 | 模型在后台「AI 与模型」页配置；助手固定使用**绑定到 `agent` 角色的 Anthropic 协议模型**（可以是兼容 Anthropic 接口的第三方网关） | 第 0 期 |
| 2 | 助手出的题**先是草稿，使用者点"采纳"后进入审核队列**，不直接发布；以后可加开关 | 讨论 |
| 3 | H5 也要有对话界面，直接调用服务端同一套接口，不另写逻辑 | 讨论 |
| 4 | 用量计入每日 token 预算，来源为 `server`、角色为 `agent` | 第 0.5 期的预算规则 |
| 5 | 访问控制复用"App 访问令牌"（`/api/v1/ai/config` 用的那个） | 本文 |

---

## 3. 现状与可复用的部分

| 已有 | 位置 | 助手怎么用 |
|---|---|---|
| 切块后的讲义 | `chunk` 表（`heading_path`、`text`），`ListLessons` 查询、`GET /api/v1/lessons` | 工具 `list_outline` / `search_lessons` / `get_lesson` 的数据来源 |
| 出题校验 | `pipeline.ValidateQuestion`（题型、选项数、`source_quote` 必须能在原文里原样找到、不含"以上都对"等） | `propose_questions` 对每道题再校验一遍，**不信任模型** |
| 去重 | `pipeline.Deduper`（精确哈希 + 字符三元组 Jaccard）、`ListLiveQuestionsByBank` | 同一题库内去重，草稿之间也去重 |
| 入库与审核 | `question` 表、`needs_review → published` 流转、`transition()`、同步 `sync_seq` | 草稿用 `draft` 状态（`question.status` 的 CHECK 里本来就有），采纳后变 `needs_review` |
| 作答记录 | `attempt`、`question_state` 表（客户端同步上来） | 工具 `get_weak_points` |
| 模型层 | `llm.Registry`（按角色取 client）、`llm.Guard`（并发、速率、每日预算、调用日志）、Anthropic 官方 SDK | 新增"多轮 + 工具 + 流式"接口，复用 Guard 的限额和日志 |
| 访问令牌 | `app_setting.ai.app_token`、`checkAppToken` | 助手接口鉴权 |
| 流式渲染 | Flutter：`QuizMarkdown` + `AiExplainCard`；H5：`Md.vue` | 助手回答的渲染 |

**缺的**：①LLM 层没有多轮、工具调用和流式；②没有全文检索（讲义总量不大，先用内存检索，见 §6.4）；③没有"草稿"的归属和清理机制；④客户端没有聊天界面。

---

## 4. 总体架构

```
 Flutter 对话页 ─┐                                  ┌─ search_lessons / get_lesson / list_outline
                 │  POST /api/v1/agent/chat (SSE)   ├─ search_questions / pick_questions
 H5 对话页 ──────┤  Authorization: Bearer <令牌>    ├─ get_weak_points
                 ▼                                  └─ propose_questions / list_drafts (仅出题模式)
        ┌──────────────────────┐   工具调用   ┌──────────────────────┐
        │ httpapi: agent 处理器 │────────────▶│ internal/agent        │
        │  鉴权 · 限流 · SSE    │◀────────────│  循环 · 工具 · 提示词  │
        └──────────────────────┘   事件流     └──────────┬───────────┘
                                                         │ llm.Converser（流式 + 工具）
                              ┌──────────────────────────▼───────────────┐
                              │ llm.Guard（并发 / 速率 / 每日预算 / 日志） │
                              └──────────────────────────┬───────────────┘
                                                         ▼
                                      Anthropic 协议端点（agent 角色绑定的模型）

  草稿：question(status=draft) + agent_draft(conversation_id)
        ── 采纳 ──▶ needs_review ── 后台审核通过 ──▶ published ──▶ 现有同步分发给各端
        ── 丢弃 ──▶ rejected
```

对话由客户端带上完整历史，服务端**不存对话**；服务端只持久化两样东西：草稿（题目本身）和用量日志。

---

## 5. 交互模型

### 5.1 两种模式

| | `learn` 学习 | `create` 出题 |
|---|---|---|
| 入口 | 讲义页"问 AI"、答题后"追问"、题库页"问 AI" | 题库页"AI 出题"、讲义页"用这一节出题" |
| 工具 | `list_outline` `search_lessons` `get_lesson` `search_questions` `pick_questions` `get_weak_points` | 学习模式的全部，外加 `propose_questions` `list_drafts` |
| 写入 | 无 | 只能创建草稿 |
| 提示词 | 讲解为主，回答要引用讲义小节 | 先确认范围和要求，再出题；每题必须挂在一节讲义上 |

模式由入口决定，对话中不切换；学习模式里助手可以建议"要不要用这一节出几道题"，客户端据此提供"切到出题"的按钮（新开一个出题对话并带上同一个上下文）。

### 5.2 上下文

请求的 `context` 字段告诉助手用户当前在看什么，服务端把它放进提示词（不是工具，省一轮调用）：

```json
{ "bank_id": "…", "lesson_id": "…", "question": { "id": "…", "selected": [1] } }
```

三项都可选。有 `lesson_id` 时服务端先取该节全文放进上下文；有 `question` 时放入题干、选项、标准答案、解析和用户所选。工具默认只在 `bank_id` 指定的题库里查，不给就查全部。

### 5.3 引用

助手引用讲义和题目时必须写成 Markdown 链接，用自定义协议：

```
[进程调度算法](lesson:01J…)      [这道题](question:01J…)
```

客户端拦截点击：`lesson:` 打开讲义页，`question:` 打开该题（只读查看）。这样"回答有出处"在界面上是可点的，不是文字摆设。服务端在输出前校验链接里的 id 确实出现在本轮工具结果或上下文里，凭空编的 id 去掉链接、保留文字。

---

## 6. 服务端设计

### 6.1 代码结构

```
server/internal/
  llm/
    converse.go            # Converser 接口、消息 / 工具 / 事件类型
    anthropic/converse.go  # Anthropic 实现（流式 + 工具）
    fake/converse.go       # 脚本化的假实现，测试用
    guard.go               # 新增 WrapConverser：每一轮独立占并发、查预算、记日志
  agent/
    agent.go               # 对话循环
    tools.go               # 工具注册、参数校验、结果截断
    tool_lessons.go        # list_outline / search_lessons / get_lesson
    tool_questions.go      # search_questions / pick_questions / get_weak_points
    tool_propose.go        # propose_questions / list_drafts
    prompt.go + prompts/   # 系统提示词（embed）
    events.go              # SSE 事件类型
  service/
    agent.go               # 草稿的采纳 / 丢弃 / 清理，对话入口，权限与限流
  httpapi/agent.go         # 路由与 SSE 输出
  db/migrations/00014_agent_draft.sql
```

`agent` 包只依赖 `llm` 和一个窄接口（`agent.Library`：题库、讲义、已发布的题、作答记录的只读视图，由 `service` 的 `agentLibrary` 实现），方便用假实现测试，不直接碰数据库连接。第 2 期出题需要写入时再加一个写接口。

### 6.2 LLM 层扩展

现有的 `llm.Client` 只有 `GenerateJSON`。新增一个独立接口，不污染原来的：

```go
// Converser 做一轮对话：给定历史和可用工具，流式产出文本，最后返回助手这一轮的完整内容。
type Converser interface {
    Converse(ctx context.Context, req ChatRequest, emit func(StreamEvent)) (ChatTurn, Usage, error)
    Name() string
    Model() string
}

type ChatRequest struct {
    System    []string      // 稳定部分在前（第一块带缓存断点），随请求变化的上下文在后
    Messages  []Message
    Tools     []ToolSpec    // 名称、描述、JSON Schema
    MaxTokens int
}
type Message struct { Role string; Blocks []Block } // Block: 文本 / tool_use / tool_result / 原样保留的思考块
type StreamEvent struct { TextDelta string }        // 只流文本；tool_use 在块结束后随 ChatTurn 返回
type ChatTurn struct { Blocks []Block; StopReason string } // end_turn | tool_use | max_tokens | refusal
```

**Anthropic 实现**（`anthropic/converse.go`）：

- 用 `Messages.NewStreaming`，用 SDK 的 `Message.Accumulate` 累积事件，文本增量即时 `emit`，结束后得到完整内容块。
- 工具声明走 `ToolParam`，`tool_choice` 只用默认的 `auto`——本项目已经确认这个模型族拒绝 `any` / `tool`（见 architecture §4.3）。
- 工具循环里**必须把助手这一轮的全部内容块原样放回历史**，包括思考块，否则下一轮会被端点拒绝。思考内容不发给客户端，只在界面上显示"思考中"。
- 系统提示和工具定义设置缓存断点；每一轮循环里历史只增不改，后续轮次大部分输入命中缓存。网关忽略 `cache_control`（DeepSeek 就是）时断点无效，但网关自己按前缀缓存，所以"稳定内容在前、变化内容在后"的顺序照样有用。
- **正文过滤**：流里的文本增量和完整文本块都要经过 `llm.NoiseFilter`（整段用 `llm.StripNoise`），去掉网关漏进正文的内部标记（目前已知：DeepSeek 的 `<ds_safety>…</ds_safety>`，见下面的实测）。过滤发生在 `emit` 之前，也发生在把这一轮放回历史之前，不让它出现在界面和后续请求里。流式时遇到 `<ds_` 开头先缓存，闭合后丢弃，输出结束仍未闭合就整段丢弃。
- 采样参数不传（见 §4.3 的约束），`effort` 来自模型配置。
- `ErrRefused`、`ErrTruncated`、预算耗尽沿用 `llm` 包里已有的错误。

**Guard 扩展**：`Guard.WrapConverser(role, c)` 返回同样的接口；`llm.CallRecord` 新增 `RefID`、`DeviceID`，通过 `llm.WithRef(ctx, refID, deviceID)` 从调用方传入，`LLMRecorder` 写进 `llm_call_log` 的 `ref_id`、`device_id` 列（第 0.5 期已加这两列）。关键是粒度——**并发名额和速率限制按"一轮模型调用"算，不按"一整次对话"算**：对话循环在两轮之间执行工具时不占名额，避免一次长对话把出题任务挤死；每轮开始前查每日预算，每轮结束后写一条 `llm_call_log`（`role=agent`、`source=server`），`ref_id` 填对话 id，`device_id` 填请求里的设备 id（用量明细里就能按对话查看）。

**兼容性探针**：后台"模型测试"按钮对 `agent` 角色的模型不只是 Ping，而是做一次"流式 + 调用一个空工具"的往返，并如实报告缺哪一项（不支持流式 / 不支持工具 / 思考块处理异常）。第三方 Anthropic 兼容网关在这几项上差异最大，应该在配置时发现，而不是用户在手机上提问时才发现。

**实测：DeepSeek（2026-10-08，`https://api.deepseek.com/anthropic`，`deepseek-flash`）**

| 项 | 结果 | 对实现的影响 |
|---|---|---|
| 非流式普通回复 | 通过，但正文里漏进了 `<ds_safety>[用户未成年]否…</ds_safety>Safe`，且前面的正文被截断（"Hi! 👋 What's on your"）。出现时 `thinking` 为空串 | 必须过滤（上文"正文过滤"）；被截断的回复不可修复，只能当一次低质量回复，遇到再观察频率 |
| 流式 + 工具 | 事件序列标准：`message_start` → 各内容块（`thinking` → `text` → `tool_use`，工具参数走 `input_json_delta`）；`input_tokens` 在 `message_start`，输出 token 数在最后的 `usage` | 标准 SDK 累积即可；`ping` 事件忽略 |
| 思考默认开启 | 没传 `thinking` 参数也返回思考块，思考内容算输出 token | 用量里输出偏大属正常；是否值得关闭另测 |
| 思考块回传 | 通过。带着上一轮的 `thinking`（`signature` 其实是消息 id）、`tool_use` 回传 `tool_result`，网关正常继续 | 沿用"整轮内容块原样放回历史" |
| 用量字段 | `input_tokens` **不含**缓存命中：299 = `input_tokens` 171 + `cache_read_input_tokens` 128；`cache_creation_input_tokens` 恒为 0 | 与 Anthropic 语义一致，`Usage{Input, Output, Cached}` 直接对应；成本估算时三项相加才是总输入 |
| 缓存 | 没有设置断点也有缓存命中（128 个 token） | 网关自动按前缀缓存 |
| 未验证 | 脚本只看了流的前 60 行，没有确认：`tool_use` 的 `input_json_delta` 拼完整后是合法 JSON、末尾 `message_delta` 的 `stop_reason` 是 `tool_use`、流式下 `<ds_safety>` 是否也会出现 | 第 1 期第一步的 Go 探针测试里补上 |

### 6.3 对话循环

```
入口：校验请求 → 取上下文 → 组装 System / Messages / Tools → 发 start 事件
for round := 1 .. maxRounds(8):
    turn := Converse(...)            // 文本增量实时 emit 成 delta 事件
    if turn.StopReason != tool_use → 结束
    对 turn 里的每个 tool_use（同一轮多个工具并行执行）：
        emit tool(running)
        result := tools.Run(name, input)     // 超时 15s；结果超长则截断并注明
        emit tool(done|error)
        若 propose_questions 产生了草稿 → emit drafts
    把 tool_result 追加到历史，继续下一轮
超过 maxRounds → 让模型不带工具总结一次（tools 置空），stop=max_rounds
```

约束：

| 项 | 值 | 说明 |
|---|---|---|
| 最大轮数 | 8 | 防止工具循环失控 |
| 单个工具结果 | ≤ 6000 字符 | 超出截断并附"（已截断）" |
| 单轮最大输出 | 模型配置的 `max_tokens` | 学习模式默认够用；出题模式建议 ≥ 8000 |
| 整次请求时限 | 3 分钟 | 超时发 `error`，已花的 token 照常记录 |
| 工具错误 | 作为 `is_error` 的 tool_result 回给模型 | 让它自己改正参数重试，不直接中断对话 |
| 客户端断开 | 取消 ctx，流式请求随之中止 | 已产生的用量照常记录（Guard 用脱离 ctx 的记录） |
| 并发 | 每个设备最多 2 个进行中的对话 | 超出返回 429 |

### 6.4 工具

所有工具的参数都用 JSON Schema 声明并在服务端再校验；返回给模型的是精简文本 / JSON，**每个结果里都带 id**，模型据此引用。工具只读，唯一的写入是 `propose_questions` 创建草稿，没有发布、删除、修改已发布题目的能力。

| 工具 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `list_outline` | `bank_id?`, `document_id?` | 题库 → 章节（文档）→ 小节的树：`lesson_id`、标题路径、该节题数、用户正确率 | 回答"讲讲第三章""我还有哪些没学"这类问题的起点；最多 200 个节点，超出要求按章节分页 |
| `search_lessons` | `query`, `bank_id?`, `limit≤8` | 命中的小节：`lesson_id`、标题路径、命中的上下文片段（≤200 字） | 见下方"检索" |
| `get_lesson` | `lesson_id`, `with_neighbors?` | 一节的全文（≤1500 字，切块上限），可带前后节标题 | 讲解和出题的依据 |
| `search_questions` | `query?`, `lesson_id?`, `bank_id?`, `limit≤10` | 已发布题目：`question_id`、题干、选项、标准答案、解析、该题的作答统计 | 查"已有的题"，避免重复出题，也用来举例 |
| `pick_questions` | `lesson_id?`, `bank_id?`, `weak?`, `count≤10` | 从已发布题里挑出的题（不含答案，答案在用户作答后另给） | "出几道小测"直接用审核过的现成题，比临时生成可靠 |
| `get_weak_points` | `bank_id?`, `limit≤10` | 薄弱题和薄弱小节：近 5 次作答的错误数、按小节聚合的正确率 | 算法与客户端一致：近 5 次，先验错误率 0.25、权重 4 个回答（见 H5 `stats.ts` 的 `WEAK_*`） |
| `list_drafts` | — | 本对话已有的草稿：`draft_id`、题干、选项、答案、状态 | 仅出题模式；客户端只带文字历史，草稿内容要靠它取回 |
| `propose_questions` | 见 §6.5 | 逐题的结果 | 仅出题模式 |

**检索**：讲义总量小（客户端本来就整库下载），不引入 FTS5。`search_lessons` 每次从 `ListLessons` 取出（带进程内缓存，按 `lessons` 的内容版本号失效），对查询切成词，在标题路径和正文里按词命中数加权打分，标题命中权重更高；中文没有空格，同时用字符二元组匹配兜底。命中片段取首个命中位置前后各 100 字。讲义增长到上千节、或体感召回不好时，再换成 SQLite FTS5（`trigram` 分词器），工具接口不变。

**为什么 `pick_questions` 不返回答案**：它的用途是"出题考我"。答案由客户端在用户作答后从本地题库取（题已经同步到本机），助手只负责组织和点评，避免模型在用户答之前就泄露。

### 6.5 `propose_questions` 与草稿

```jsonc
{
  "lesson_id": "…",          // 必填：题目挂在这一节上，source_quote 在这一节的原文里找
  "questions": [             // 1–5 道
    { "type": "single|judge", "stem": "…", "options": ["…","…","…","…"],
      "answer_index": 0, "explanation": "…", "difficulty": 1,
      "tags": ["…"], "source_quote": "原文里一句话，逐字照抄",
      "replaces": "draft_id（可选：替换本对话里一道旧草稿）" }
  ]
}
```

处理流水线（逐题，互不影响）：

1. **规则校验**：`pipeline.ValidateQuestion(cand, lesson.Text)`，与批量出题完全相同——题型和选项数、答案下标、`source_quote` 必须在该节原文中原样出现、不含"以上都对"、不指代"上文"等。
2. **去重**：`Deduper` 以本题库所有未被驳回的题（含其他草稿）为基准。
3. **独立复核**：如果后台给 `validator` 角色绑了模型，就让它**只看题干、选项和该节原文、看不到标准答案**，独立作答；答案对不上就驳回，备注"复核答案不一致"。这是 architecture §5 里一直预留的复核步骤，助手出题是第一个用上它的地方。没绑 `validator` 时跳过，并在返回结果里注明"未经独立复核"，界面上草稿卡片也显示这一点。
4. **入库**：通过的题以 `status='draft'` 入库，`gen_model` 记模型，`gen_prompt_version` 记 `agent.v1`，同时写一行 `agent_draft(question_id, conversation_id, …)`。
5. **替换**：带 `replaces` 且该草稿属于本对话、仍是 `draft` 时，新题通过后旧草稿置为 `rejected`（备注"被新草稿替换"）。

返回给模型的是逐题结果，失败时带**可操作的原因**，让它能修了重提：

```jsonc
{ "results": [
  { "ok": true,  "draft_id": "…" },
  { "ok": false, "error": "source_quote 在该节原文里找不到，请逐字摘抄原文中的一句话" },
  { "ok": false, "error": "与已有题目重复（draft_id/question_id: …）" }
]}
```

同一个 `drafts` SSE 事件把通过的草稿完整内容发给客户端，渲染成卡片。限额：每次调用 ≤5 题，每个对话存活的草稿 ≤20。

**草稿的生命周期**

```
            propose_questions                 点"采纳"                 后台审核通过
  (模型) ─────────────────────▶ draft ───────────────────▶ needs_review ──────────────▶ published ─▶ 同步到各端
                                  │ 点"丢弃" / 被替换                       │ 后台驳回
                                  ▼                                        ▼
                               rejected                                 rejected
                                  ▲
                 7 天内没人处理的 draft ──清理──▶ retired
```

- `draft` 只有本人在聊天里能看到：不出现在后台审核队列、不参与同步、不计入题库题数；去重时会算上，避免同一次对话里重复出。**这要改现有代码，不会自动成立**：后台 `ListQuestions` 在不指定状态时现在会列出所有状态，要改成排除 `draft`（只有明确筛"助手草稿"时才列出）；`QuestionStatusCounts` 的结果里 `draft` 单独成项，不并进"待审核"，题库页的题数也不含它；`appBanks` 的题数、同步、统计里确认只认 `published`。这些都在第 2 期的验收里有对应用例。
- 采纳：`draft → needs_review`，从此走现有审核流程，不绕过人工审核（决定 2）。
- 清理：服务启动时和每次对话开始时，把超过 7 天仍是 `draft` 的置为 `retired`（一条 SQL，不需要新的后台任务）。
- 之后可加开关 `agent_auto_publish`：开启时"采纳"直接走 `transition()` 发布。本次不做，但 `accept` 只有一处状态变更，加开关改动很小。

### 6.6 数据库迁移 `00014_agent_draft.sql`

```sql
CREATE TABLE agent_draft (
  question_id     TEXT PRIMARY KEY REFERENCES question(id),
  conversation_id TEXT NOT NULL,
  lesson_id       TEXT NOT NULL,           -- chunk.id
  device_id       TEXT NOT NULL DEFAULT '',
  verified        INTEGER NOT NULL DEFAULT 0, -- 经过独立复核
  created_at      INTEGER NOT NULL
);
CREATE INDEX idx_agent_draft_conv ON agent_draft(conversation_id);
CREATE INDEX idx_agent_draft_created ON agent_draft(created_at);
```

不改 `question` 表：题目本身和流水线出的题完全同构（`chunk_id` 指向那一节，`source_quote` 有出处），区别只在 `gen_prompt_version = 'agent.*'` 和多了一行 `agent_draft`。后台审核页据此加一个"来源：助手"筛选。迁移测试：`db_test.go` 里回退到旧版本的用例是手工 `DROP` 后续迁移建的表，所以要在它们的语句列表里加上 `DROP TABLE agent_draft`。

### 6.7 接口

全部在 `/api/v1/agent/*`，要 `Authorization: Bearer <访问令牌>`；令牌错或没设置返回 401。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/agent/status` | `{ "available": true, "model": "…", "verified": true }`；`available` 表示 `agent` 角色已绑定且能用。客户端据此显示或隐藏入口 |
| POST | `/agent/chat` | 一轮对话，SSE 响应，见下 |
| GET | `/agent/drafts?conversation_id=` | 该对话里仍是 `draft` 的草稿，客户端重进页面时恢复卡片 |
| POST | `/agent/drafts/{id}/accept` | `draft → needs_review`，返回草稿 |
| POST | `/agent/drafts/{id}/discard` | `draft → rejected` |

`POST /agent/chat` 请求：

```jsonc
{
  "conversation_id": "",           // 首轮留空，服务端在 start 事件里发一个；之后原样带回
  "mode": "learn",                 // learn | create
  "device_id": "…",
  "messages": [ { "role": "user", "content": "…" }, { "role": "assistant", "content": "…" }, … ],
  "context": { "bank_id": "…", "lesson_id": "…", "question": { "id": "…", "selected": [1] } }
}
```

校验：最后一条必须是 `user`；最多 30 条、总长 ≤ 24000 字符，更早的历史由客户端截断；`context` 里的 id 必须存在。历史里只有文字，**不回放以往轮次的工具调用**：助手需要时重新调工具。代价是多一两次工具往返，好处是请求小、客户端不用懂工具协议。

响应 `Content-Type: text/event-stream`，事件：

| 事件 | data | 说明 |
|---|---|---|
| `start` | `{ "conversation_id": "…" }` | 第一个事件 |
| `delta` | `{ "text": "…" }` | 回答的文本增量 |
| `tool` | `{ "id": "…", "name": "search_lessons", "label": "在讲义里查找「进程调度」", "status": "running\|done\|error" }` | 工具进度，界面显示成一行状态；`label` 由服务端生成，客户端不需要认识工具名 |
| `drafts` | `{ "drafts": [ {…题目…, "draft_id": "…", "verified": true } ] }` | 通过校验的新草稿 |
| `done` | `{ "stop": "end_turn\|max_rounds\|max_tokens", "usage": { "input": 0, "output": 0, "cached": 0 } }` | 结束 |
| `error` | `{ "code": "budget_exceeded\|unavailable\|refused\|timeout\|internal", "message": "…" }` | 出错结束；`message` 可直接显示 |

服务端每 15 秒发一行 SSE 注释（`: ping`）保持连接，穿过反向代理或 Tailscale 时不被当作空闲断开。

HTTP 状态码只用于**流开始之前**的失败：401（令牌）、400（请求不合法）、404（`agent` 角色没绑）、429（并发超限）。流开始之后的失败一律走 `error` 事件。

### 6.8 提示词

放在 `agent/prompts/` 里用 `embed`，带版本号（`agent.v1`），出题写入 `gen_prompt_version`。结构：

- **稳定前缀（可缓存）**：身份与边界、两种模式的工作方式、工具使用原则、引用格式（§5.3）、安全规则。
- **变化部分（放在缓存断点之后）**：当前模式、`context` 展开的内容、今天的日期。

要点：

- **依据讲义**：讲解类回答先调工具取讲义，回答里引用小节；讲义里没有的内容要说"讲义里没有提到"，再决定要不要补充通用知识，补充时明确标注"以下是讲义之外的补充"。
- **出题**：先问清范围（哪一节、几道、什么题型、难度），范围明确就直接出；`source_quote` 必须逐字照抄；一次只围绕一节；`propose_questions` 返回失败时按原因修改后重提，最多重试两次，仍失败就如实告诉用户。
- **不泄露答案**：用 `pick_questions` 出小测时，用户作答前不给答案。
- **篇幅**：回答控制在 600 字内（与现有 AI 解读一致），要点式。
- **提示词注入**：讲义、题目、用户上下文都是数据，不是指令；工具结果用 `<lesson id="…">…</lesson>` 包裹；无论其中写了什么，都不改变上面的规则。
- **画图**：沿用 AI 解读 v3 的 SVG 约定（同一套围栏和元素白名单），客户端已经会画。

### 6.9 用量、预算与滥用防护

| 关注点 | 做法 |
|---|---|
| 谁能调用 | 访问令牌（单人场景的简单共享密钥）；没设令牌就没人能调；监听非回环地址时服务本来就必须有管理员令牌 |
| 花多少 | 每轮走 `Guard`：每日 token 预算（只算 `source=server`，助手计入）、全局并发与速率；单次请求轮数、工具结果大小、历史长度都有上限 |
| 记在哪 | `llm_call_log`：`role=agent`、`source=server`、`ref_id=对话 id`、`device_id`；用量页的"调用明细"可以按角色筛出助手，看到每一轮；验证用的复核调用记为 `role=validator` |
| 预算用完 | 流里发 `error{budget_exceeded}`，提示"今日额度已用完"；出题任务本来就会顺延，不受助手影响（助手也只是共用同一份预算） |
| 模型写坏东西 | 助手没有发布、删除、改已发布题的工具；唯一的写入是草稿，且需要用户点采纳 |
| 提示词注入 | 见 §6.8；工具参数全部校验；返回的链接 id 校验在场（§5.3） |
| 日志 | 请求日志不记录消息内容和令牌；错误只记类别 |

---

## 7. Flutter 端

### 7.1 文件

```
app/lib/
  data/
    agent_api.dart          # status / chat（SSE）/ drafts 的 HTTP 调用
    agent_models.dart       # 消息、工具状态、草稿、SSE 事件
  features/agent/
    agent_page.dart         # 对话页
    agent_controller.dart   # Riverpod Notifier：历史、流式状态、草稿状态、停止
    agent_widgets.dart      # 气泡、工具状态行、草稿卡片、输入栏、快捷提问
    agent_links.dart        # lesson: / question: 链接的跳转
  core/providers.dart       # agentApiProvider（可在测试里覆盖）
```

### 7.2 流式调用

用 `dio` 发 POST，`responseType: ResponseType.stream`，复用 `ai_chat.dart` 里 SSE 逐行解析的写法，但事件是命名事件（`event:` + `data:`），所以解析器单独写一个小函数并单测。取消（用户点"停止"或离开页面）走 `CancelToken`，服务端据此中止模型调用。接收超时设为 90 秒（相邻两个事件之间的最长静默；服务端 15 秒一个 ping，不会误断）。

### 7.3 界面

- **对话页**：消息列表（助手用 `QuizMarkdown` 渲染，含 SVG 图）、工具状态行（"在讲义里查找…"，完成后淡化）、底部输入栏、"停止"按钮。进入时按入口给 2–3 个快捷提问（学习：讲一下这一节 / 我哪里薄弱 / 出几道题考我；出题：出 5 道单选 / 出判断题 / 偏难一点）。
- **草稿卡片**（出题模式）：题型、题干、选项（标准答案高亮）、解析、出处原文（可展开）、难度和标签，"未经独立复核"时有提示。三个按钮：**采纳**（调 `accept`，成功后卡片变"已提交审核"）、**丢弃**、**让它改改**（把"请修改这道题："预填进输入框，并带上 draft_id 的引用，助手用 `replaces` 重出）。
- **没有令牌 / 助手不可用**：页面顶部横幅，按钮跳设置页；`GET /agent/status` 返回 404 时说明服务端没给助手绑模型。
- **离线**：发送按钮禁用并说明"需要连接服务器"；已有对话内容保留在内存里。
- **对话保存**：本期只在内存里保存，离开页面即丢；草稿不会丢（在服务端），重进出题页用 `GET /agent/drafts` 恢复卡片。

### 7.4 入口

| 位置 | 入口 | 模式 / 上下文 |
|---|---|---|
| 讲义页 `lesson_page.dart` | 右上角"问 AI"；末尾"用这一节出题" | learn + `lesson_id`；create + `lesson_id` |
| 答题页 `quiz_page.dart` | `AiExplainCard` 下方"追问 AI" | learn + `question`（带用户所选）；首条消息预填"我还是没懂，……" |
| 题库详情页 | "AI 出题"、"问 AI" | create / learn + `bank_id` |

不新增底部标签页。"AI 解读"卡片保持原样（客户端直连模型，离线也有已保存的解读），"追问 AI"是它的延伸，不替代它。

### 7.5 设置

访问令牌复用已有的"AI 访问令牌"（设置页 AI 配置那一节），不新增输入项；该节的说明文字补一句"用于 AI 解读、用量上报和 AI 助手"。

---

## 8. H5 端

H5 由服务端内嵌提供（同源 `/m/`），使用方式和 Flutter 相同，只是实现在 Vue 里。

```
h5/src/
  data/agentApi.ts        # status / chat / drafts；chat 用 fetch 读 ReadableStream 解析 SSE（EventSource 不能 POST、不能带头）
  data/agentTypes.ts
  views/AgentView.vue     # 对话页，路由 /agent?mode=&bank=&lesson=&question=
  components/DraftCard.vue
  quiz/agentLinks.ts      # lesson: / question: 链接 → 路由
```

- **令牌**：H5 目前没有任何令牌概念（同源、免鉴权）。「设置」页新增一项"AI 访问令牌"，存 `localStorage`，调用助手时带上；没填就显示同样的提示横幅。
- **入口**：`LessonView`、`QuizView`（答题后）、`BankView`，与 Flutter 一致。
- **渲染**：回答用现有的 `Md.vue`。**H5 目前没有渲染助手画的 SVG**（Flutter 的 `QuizMarkdown` 有，H5 只有统计页自己画图），这是 H5 的新增工作：在 `Md.vue` 里识别 ```` ```svg ```` 围栏，先按与服务端 `checkSVG` 相同的白名单检查（只允许 rect、circle、ellipse、line、polyline、polygon、path、text、g、defs、marker；拒绝 `<script>`、`<style>`、`<foreignObject>`、`<image>`、`on*` 事件属性、外链），通过后用 `<img src="data:image/svg+xml,…">` 显示——作为图片加载的 SVG 不会执行脚本，检查是第二道防线。围栏没关闭时按代码块显示，与 Flutter 一致。
- **取消**：`AbortController`；离开页面时中止。
- **测试**：SSE 解析器、控制器状态机、SVG 白名单检查、`views.test.ts` 里加 AgentView 的渲染用例。

---

## 9. 管理后台

| 页面 | 改动 |
|---|---|
| 审核页 | 筛选新增"来源：助手出题"（`gen_prompt_version LIKE 'agent.%'`）；题目详情里显示"助手草稿 · 对话 xxxx · 是否经独立复核" |
| 用量页 | 无需改：`role=agent` 已能在角色筛选里选到（`ROLE_LABEL` 里有"学习助手"）；明细里 `ref_id` 是对话 id 时显示"对话 xxxx"而不是题目 |
| AI 与模型 | `agent` 角色的"测试"按钮升级为流式 + 工具的兼容性探针（§6.2）；`validator` 角色的说明从"预留"改为"助手出题时的独立复核" |
| AI 解读 | 标签页里的"访问令牌"说明补充：同时用于用量上报和 AI 助手 |

---

## 10. 接口契约与文档

- `api/openapi.yaml`：新增 `/api/v1/agent/status`、`/agent/chat`（`text/event-stream`，事件在描述里列出）、`/agent/drafts*`，以及 `AgentMessage`、`AgentContext`、`AgentDraft`、`AgentEvent*` 等 schema。
- `docs/architecture.md`：新增 §7.9"助手"（概述加链接到本文），§8 接口表，§9 安全里补助手的令牌和预算。
- 本文在实现完成后改为"已实现"，并记录与设计的偏差。

---

## 11. 与现有功能的关系

### 11.1 AI 解读

两者并存、互不影响：解读是"一次问一道题"，由客户端直连模型，离线可看已保存的内容；助手是多轮对话，经服务端。以后如果希望 API Key 不再下发到手机，可以把解读改成调用助手的一个精简端点，届时第 0.5 期的客户端上报就可以删除。这不在本次范围内。

### 11.2 题目审核

助手出的题和流水线出的题进入同一个审核队列、同一套审核操作；通过后经现有同步分发。客户端不需要任何改动就能拿到这些题。

---

## 12. 测试策略

| 层 | 内容 |
|---|---|
| `llm/anthropic` | 流式事件累积成完整内容块；`tool_use` 解析；思考块原样保留；`tool_choice` 不被发送；兼容端点的错误映射。用 `httptest` 构造 SSE |
| `llm` Guard | 一轮一占名额（工具执行期间不占）、每轮查预算、每轮写日志、客户端断开后仍记录 |
| `agent` 循环 | 用脚本化的假 `Converser`：纯文本回答；一轮工具调用后回答；多个并行工具；工具报错后模型改参重试；超过最大轮数；预算耗尽；取消 |
| 各工具 | 参数校验、结果截断、`search_lessons` 排序、`get_weak_points` 与客户端算法对拍、`pick_questions` 不含答案 |
| `propose_questions` | 合格题入库为 `draft`；`source_quote` 伪造被拒；与已有题 / 其他草稿重复被拒；复核不一致被拒；`replaces` 的归属与状态检查；每对话上限 |
| 草稿流转 | 采纳 / 丢弃的状态机与权限；他人对话的草稿不能操作；7 天清理；`draft` 不出现在审核队列、同步和题数里 |
| HTTP | 鉴权（无令牌 / 错令牌 / 未绑定角色）、SSE 事件顺序与格式、ping、并发上限 429、请求校验 |
| 用量 | 助手调用出现在 `/admin/usage` 里，`role=agent`，计入预算；明细里 `ref_id` 是对话 id |
| Flutter | SSE 解析器；控制器状态机（发送、流式、停止、错误）；草稿卡片的采纳 / 丢弃 / 修改；链接跳转；无令牌横幅。用假 `AgentApi` |
| H5 | SSE 解析器、控制器、AgentView 渲染 |
| 真实端点探针 | 一个默认跳过的测试（环境变量给出 Key 时才跑）：用真实 Anthropic 端点做一次工具循环，确认流式事件、思考块回传、`tool_choice` 约束与本文假设一致 |

---

## 13. 分期与验收

每期单独提交，可独立验收；顺序按依赖排。

### 第 1 期：服务端核心 + 学习模式（已实现）

实现与方案的差别：对话入口 `StartAgentChat` 把“能在流开始前失败的检查”（令牌、角色、请求、上下文 id、并发）和“流本身”拆成两步，HTTP 层据此决定返回状态码还是开始 SSE；`出题模式` 在第 2 期前返回 400“出题模式还没有开放”；`/agent/drafts*` 三个接口随第 2 期。后台“测试”按钮对绑定到 `agent` 角色的模型做四项检查（流式输出、工具调用、多轮工具往返、正文干净），前三项任一不通过则判定“不能用作助手”，第四项只是警告。

交付：`llm.Converser` 与 Anthropic 实现、`Guard.WrapConverser`、`agent` 循环与学习模式的 6 个工具、`/agent/status` 与 `/agent/chat`、鉴权与限流、用量记录、模型测试按钮的兼容性探针。

**第一步先做真实端点探针**（§12 最后一行）：确认流式事件格式、思考块回传、网关兼容性，再写其余代码——这是本方案最大的未知数，不要等到做完才发现。

验收：
- 用 `curl -N` 提问"讲讲进程调度"，看到 `start` → `tool`（查找、取讲义）→ `delta`… → `done`，回答里有可点的 `lesson:` 链接，链接 id 都在工具结果里。
- 后台用量页能按角色"学习助手"筛出这次对话的每一轮，明细里是对话 id。
- 预算调小后再问，得到 `error{budget_exceeded}`。
- 断开 `curl` 后服务端日志里这次请求被取消，用量仍有记录。
- 全部测试（含竞态检测）通过。

### 第 2 期：出题模式（已实现）

实现与方案的差别：
- 独立复核放在 `pipeline.VerifyAnswer`，只给模型教材原文、题干和选项；复核模型报错（非预算）时该题返回“独立复核暂时不可用”，不会悄悄当作已复核；预算用完则整个调用失败，对话以 `budget_exceeded` 结束。
- 对话只发 `drafts` 事件，一次工具调用里通过的草稿合成一个事件，在该轮工具 `done` 之后发出。
- 清理在每次出题对话开始时顺带做（`RetireStaleAgentDrafts`），没有新增后台任务；服务启动时不另做一次。
- 草稿的“修改”没有单独的编辑接口：让助手改，它用 `replaces` 提交新题，旧草稿自动作废。
- 后台审核页的“来源：助手”筛选在这一期一并做了（`GET /admin/questions?source=agent`）；`draft` 状态默认不出现在列表里，只有明确筛状态 `draft` 时才列出，题库页的题数不含它。
- 仍保留的旧行为：后台 `POST /admin/questions/{id}/approve` 对 `draft` 状态的题也放行（早先就这样写），绕过“用户采纳”这一步；管理员本来就能发布任何题，所以不收紧。

交付：迁移 `00014`、`propose_questions` / `list_drafts`、独立复核、草稿的采纳 / 丢弃 / 恢复 / 清理接口、审核页的"来源：助手"筛选。

验收：
- 对一节讲义让助手"出 3 道单选"，得到 `drafts` 事件；故意让假模型给出伪造的 `source_quote`，该题被拒，原因回给模型，模型修正后重提成功。
- 采纳后在后台审核队列里出现，通过后能通过 `/sync/questions` 同步到客户端；丢弃的不出现在任何地方。
- `draft` 不计入题库题数，不出现在审核队列。
- 绑定 `validator` 时，故意答案错的题被复核驳回；没绑时结果注明"未经独立复核"。

### 第 3 期：Flutter（代码已写，待验证，见 §0）

交付：`agent_api`、对话页、草稿卡片、三处入口、令牌横幅、链接跳转。

验收：真机或模拟器上完成"在讲义页提问 → 点引用跳转到讲义 → 在题库页出题 → 采纳"；断网、令牌错误、预算用完、中途停止都有明确提示；`flutter test` 与 `flutter analyze` 干净。

### 第 4 期：H5、后台与文档

交付：H5 对话页与入口、设置页令牌项、后台的筛选与文案、OpenAPI、architecture 文档。

验收：手机浏览器里 H5 的体验与 Flutter 一致（同样的入口、草稿卡片、引用跳转）；`npm test` 和类型检查通过；文档与实现一致。

### 工作量（相对大小）

第 1 期最大（新抽象 + 真实端点上的不确定性），第 2 期次之，第 3、4 期主要是界面和接线。第 1 期完成前不对整体工期下结论。

---

## 14. 风险与对策

| 风险 | 对策 |
|---|---|
| 第三方 Anthropic 兼容网关不支持流式、工具或思考块 | 配置时用兼容性探针发现；真实端点探针先行；不支持的网关在界面上明确提示"该模型不能用作助手"。DeepSeek 已实测：流式、工具、思考块回传可用 |
| 网关把内部标记漏进正文（DeepSeek 的 `<ds_safety>…</ds_safety>`），甚至截断回复 | `llm.NoiseFilter`（整段用 `llm.StripNoise`） 在发给客户端和写入历史前过滤；测试用 `httptest` 构造含该标记的 SSE，覆盖标记被拆在多个增量里的情况；兼容性探针把"正文含内部标记"列为警告 |
| 助手出的题答案错误 | 规则校验 + 出处必须原样存在 + 可选独立复核 + 人工审核四道关；采纳只是进审核队列，不是发布 |
| 对话越聊越长、成本上升 | 历史条数和总长度封顶，客户端负责截断；系统提示和工具定义命中缓存；用量页可见每次对话的消耗 |
| 同一个讲义被反复出重复的题 | 去重覆盖题库全部未驳回的题和所有草稿；`search_questions` 让助手出题前先看已有的 |
| 讲义文本里夹带指令 | 工具结果当数据包裹；助手没有任何破坏性工具；输出链接校验 |
| 搜索召回不好 | 先用内存检索观察；不够用再换 FTS5，工具接口不变 |
| 手机切后台导致流被系统断开 | 服务端对断开按取消处理并记录已花费的用量；客户端回到前台提示"已中断"并保留已收到的内容，用户可重新发送 |
| 单人场景下令牌是个共享密钥，泄露即可花钱 | 预算上限兜底；令牌可随时在后台更换；助手接口不暴露任何 Key |

---

## 15. 后续（不在本次范围）

- **用户材料出题**（`add_material`）：粘贴一段不在讲义库里的文字，存成一个文档走现有切块，再出题。
- **对话保存与同步**：服务端存 `agent_message`，多端续聊。
- **自动发布开关** `agent_auto_publish`，以及按"已复核"才自动发布的更保守策略。
- **FTS5 检索**与讲义向量化的语义检索。
- **AI 解读迁到服务端**，Key 不再下发到设备。
- **学习计划**：助手根据薄弱点和遗忘曲线给出今日复习建议，并直接生成一个刷题清单。

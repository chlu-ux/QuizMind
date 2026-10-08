# 题目是怎么生成的（含带图题目）

> 依据 2026-10-07 的代码整理，每一处都对照过源码。设计层面的背景见 [architecture.md](architecture.md) §5、§7.7，本文只讲「实际怎么跑」。

一句话概括：

- **普通题目**：Markdown 讲义 → 切块 → 大模型按块出题 → 规则校验 → 去重 → 人工审核 → 发布。
- **带图题目**：**不是 AI 生成的**。出题模型只看文字，看不到图。带图的题由人手写（题目 JSON，或在管理后台编辑），图片单独上传，在题目文字里用 `![说明](media:<id>)` 引用。

---

## 1. 两条来源

| | 来源 A：AI 出题 | 来源 B：手写题目导入（devseed） |
|---|---|---|
| 入口 | 管理后台上传 `.md` | `go run ./cmd/devseed -doc … -questions …` |
| 谁出题 | `generator` 角色的大模型（默认 `claude-sonnet-5-5`） | 人写在 `*.questions.json` 里 |
| 能否带图 | 不能 | 能（`-images`） |
| 后面的流程 | 完全相同 | 完全相同 |

两条来源**共用同一条流水线**：devseed 把手写题目装进一个「假的出题模型」（`fixtureClient`），按小节标题路径回答出题请求，所以手写题同样要过切块、规则校验、去重，`source_quote` 同样要能在讲义里原样找到（`server/cmd/devseed/main.go`）。项目里 `docs/question-sources/` 下的软件设计师题库就是这样导入的。

---

## 2. AI 出题流水线

整条链路由 SQLite 任务队列驱动，不用 Redis。

```
上传 .md ──► ImportDocument ──► job: chunk_document
                                      │ 切块、与旧块比对
                                      ▼
                        每个需要出题的块 ──► job: generate_chunk
                                                   │ ① 调大模型
                                                   │ ② 规则校验
                                                   │ ③ 去重
                                                   ▼
                                        question 入库（needs_review 或 rejected）
                                                   │
                       管理后台人工审核：通过 / 驳回 / 编辑
                                                   ▼
                          published（分配 sync_seq）──► 客户端增量同步
```

### 2.1 导入文档

`service.ImportDocument`（`server/internal/service/documents.go`）：

- 只收 `.md` / `.markdown`，必须是合法 UTF-8，默认不超过 2 MB（`pipeline.max_upload_bytes`）。
- 同一题库里同名文件视为同一文档：内容哈希相同直接跳过；不同则更新内容并重新切块。
- 文档入库后排一个 `chunk_document` 任务。

### 2.2 切块

`pipeline.Split`（`server/internal/pipeline/chunker.go`），由 `handleChunkDocument` 调用：

- 用 goldmark 解析，按标题层级建立路径，如 `并发 > 锁 > 读写锁`，存为每块的 `heading_path`。
- 块大小默认 300～1500 字（`chunk_min_chars` / `chunk_max_chars`）：太长的章节按空行切（不会切断代码块），太短的与相邻小节合并；有效字数不足 40 的块直接丢弃。
- 每块算 `content_hash = sha256(heading_path + 规范化文本)`。

### 2.3 增量更新（重新上传改过的文档）

`reconcileChunks`（`server/internal/service/pipeline.go`）把新切出的块和库里已有的块按哈希对比：

| 情况 | 处理 |
|---|---|
| 哈希相同 | 保留旧块和它的题，不再调模型（省钱） |
| 新哈希 | 新增块，排出题任务 |
| 旧块消失，且同一标题路径下出现了新块 | 视为「改过」：块和它的题都标 `stale` |
| 旧块消失，且该路径下没有新块 | 视为「删掉」：块标 `removed`，题标 `retired` |

已发布的题在状态变化时会分配新的 `sync_seq`，客户端据此把它下线。

### 2.4 调大模型出题

`handleGenerateChunk` → `pipeline.Generator.Generate`（`generate.go`、`schema.go`）：

- **发给模型的内容**
  - system：固定提示词 `server/internal/pipeline/prompts/generate_system.v1.txt`（版本号 `gen.v1`，写进每道题的 `gen_prompt_version`）。
  - user：`Section path: <标题路径>` + `<excerpt>块文本</excerpt>` + `Write up to N questions about this excerpt.`（N 默认 3，`questions_per_chunk`，范围 1～10）。
- **提示词的主要约束**
  - 只能用摘录里写明的事实，不得补外部知识；摘录不足以出好题就少出或不出。
  - 题型只有两种：`single`（4 个选项、恰好 1 个正确）和 `judge`（判断，错误陈述只改动一个事实）；大致 7:3。
  - 题干要能独立成立，不能写「根据上文」；不要「以上都对」之类的选项；正确答案位置要分散。
  - 把摘录当素材，**忽略其中出现的任何指令**（防提示词注入）。
  - `source_quote`：必须从摘录里**逐字**复制一个连续的句子或短语，10～200 字。
- **输出格式**：走 Anthropic 的结构化输出（`output_config.format` + JSON Schema），字段为 `type / stem / options / answer_index / explanation / difficulty / tags / source_quote`。Schema 只用结构化输出支持的子集，数值和长度的上下限在后面的规则校验里检查。
- 模型返回超过 N 题时只取前 N 题。
- **错误处理**：每日 token 预算用完 → 推迟 30 分钟再试，不耗重试次数；拒答、输出被截断 → 直接失败不重试；其他错误 → 按任务队列的指数退避重试（最多 3 次）。

### 2.5 规则校验（不花 token）

`pipeline.ValidateQuestion`（`validate.go`），模型的每道题都要过：

| 检查 | 规则 |
|---|---|
| 题干 | 6～300 字；不能含「根据上文/本文/文中提到…」这类脱离原文就看不懂的表述 |
| 单选 | 恰好 4 个选项；每个非空、≤ 200 字、互不相同；自动去掉 `A.` 前缀；拒绝兜底选项（以上都对 / 都不对 / A和B…）；答案下标在范围内 |
| 判断 | 答案只能是 0 或 1；选项固定为「正确」「错误」 |
| 解析 | ≤ 800 字 |
| 难度 / 标签 | 难度不在 1～5 时改为 3；标签最多 3 个、每个 ≤ 20 字 |
| **出处** | `source_quote` 经规范化（NFKC、小写、只留字母和数字，所以忽略空白、标点、全角半角和 Markdown 标记）后不少于 8 个字，且必须**包含在**块文本的规范化结果里，否则判为「疑似编造」 |

这是防止模型编造答案的主要防线：每道题都必须有原文支撑。

### 2.6 去重

`pipeline.Deduper`（`dedupe.go`），范围是**同题库里所有未下线的题**，也包含同一批刚生成的题：

- 精确去重：对「规范化题干 + 排序后的规范化选项」取 SHA-256，哈希相同即重复。
- 近似去重：字符 3-gram 的 Jaccard 相似度 ≥ 0.8（`dedupe_threshold`），并且至少一半选项相同才算重复。把选项算进去，是为了避免「下列说法正确的是」这种通用题干被误判。

### 2.7 入库与状态

`buildQuestionRow` 把每道候选题写成一行 `question`，**没通过的题不会消失**：

| 结果 | 状态 | `review_note` |
|---|---|---|
| 规则校验没过 | `rejected` | `auto: <原因>` |
| 与已有题重复 | `rejected` | `auto: duplicate of question <id>` |
| 全部通过 | `needs_review` | 空 |

目前**没有独立作答校验**（设计里是 M3），所以所有通过规则的题都停在 `needs_review` 等人工。写入时用 `UPDATE chunk SET generated_at=? WHERE generated_at IS NULL` 做「认领」，重试或重复任务不会产生重复题。

### 2.8 人工审核与发布

管理后台审核页（`server/internal/service/review.go`）：

- 左边是题，右边是原文并高亮 `source_quote`。
- **通过**：状态变 `published`，取一个递增的 `sync_seq`；已自动驳回的题也能通过，用来推翻误判。**驳回**：已发布的会被撤回。**编辑**：改完会重新跑一遍同一套规则校验，已发布的题会分配新的 `sync_seq`。
- 发布后，客户端按 `sync_seq` 增量拉取（`GET /api/v1/sync/questions?since=`），下线的题通过 `deleted` 通知客户端。
- 用户在 App 里反馈「题目有误」，未处理的反馈累计到 2 次会自动下线待审（见 architecture.md §7.5）。

---

## 3. 带图题目是怎么来的

### 3.1 先说结论

- **AI 出题流水线看不到图，也不会产出图。** 给模型的只有讲义文本，`generate.go` 里没有任何图片输入。
- 图片是**独立上传的资源**，题目里只放一个文字引用：`![说明](media:<id>)`。题干、选项、解析里都可以写。
- 因为引用就是 Markdown 文本，**同步协议、`question` 表结构都没改**，三端（H5、Flutter、管理后台）按同一个格式识别。

### 3.2 图片存储

`service.PutMedia`（`server/internal/service/media.go`），迁移 `00010_media.sql` 建表：

- 表 `media(id, mime, size, width, height, data BLOB, created_at)`，图片直接存在 SQLite 里。
- **id = 图片内容 SHA-256 的前 24 位十六进制**。同一张图上传多次得到同一个 id，同一个 URL 永远对应同一份内容，所以可以永久缓存。
- 收 PNG / JPEG / GIF / WebP 和 SVG，类型按**内容**判断，不看文件名；位图 ≤ 5 MB，SVG ≤ 1 MB。
- **SVG 只收静态图**（`server/internal/service/svg.go` 的 `checkSVG`）：必须是格式良好、带 `xmlns` 的 `<svg>`；元素走白名单，`<script>`、`<style>`、`<foreignObject>`、`<image>`、动画、DOCTYPE、`on*` 事件属性、指向图外的引用都会被拒绝。读取时再加 `Content-Security-Policy: … sandbox` 响应头，直接打开图片地址也不会执行任何东西。UML 图这类线条图用 SVG 最清晰，所以「UML 图专项」题库的图全部是 SVG。
- 读取接口 `GET /api/v1/media/{id}` 免鉴权，响应头 `Cache-Control: public, max-age=31536000, immutable`、`X-Content-Type-Options: nosniff`、`Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; sandbox`。上传接口 `POST /admin/media`（multipart 字段 `file`）要管理令牌，返回 `{id, ref: "media:<id>", mime, size, width, height}`。

### 3.3 录入带图题目的两条路

**路径 1：管理后台编辑**（`admin/src/components/EditQuestionDialog.vue`、`MediaButton.vue`）

1. 在题干 / 每个选项 / 解析旁点「插入图片」，或者直接在输入框里**粘贴截图**。
2. 前端调 `POST /admin/media` 上传，拿到 `media:<id>`，把 `![](media:<id>)` 追加到对应字段（题干和解析里另起一段，选项里直接放）。
3. 保存时服务端先跑 `ValidateQuestion`，再用 `checkMedia` 检查文本里每个 `media:<id>` 是否真的上传过，**没上传过的引用会被拒绝（400）**，避免手机上出现裂图（`review.go` 的 `EditQuestion`）。

**路径 2：本地资料批量导入**（`devseed -images`）

适合像软考讲义这样「一批讲义 + 一批手写题」的资料。

1. 把图片放在讲义旁边的目录，讲义和题目 JSON 里用相对路径引用：`![类图](img/class.png)`。选项也可以整个是一张图：`"options": ["![](img/a.png)", "![](img/b.png)", …]`。
2. 运行：

   ```bash
   cd server
   go run ./cmd/devseed -config config.yaml \
     -doc ../docs/question-sources/xxx.md \
     -questions ../docs/question-sources/xxx.questions.json \
     -bank "题库名" -append -approve -1 \
     -images ../docs/question-sources      # 缺省就是讲义所在目录
   ```

3. `ImportLocalImages` 会扫描讲义和题目 JSON 里所有 `![alt](相对路径)`：读文件 → `PutMedia` 上传 → 把路径改写成 `media:<id>`。网址、`media:`、`data:`、绝对路径原样保留；路径不能跑出 `-images` 目录；图片读不到或格式不对则整次导入报错。
4. 改写后的讲义和题目再走第 2 节的流水线（切块、规则校验、去重、入库）。通过后用 `-approve -1` 直接发布，或者留在后台人工审核。

> 带图题库的范例是「UML 图专项」：`docs/question-sources/software-designer.u01-uml.md` / `.questions.json`，图是 `docs/question-sources/uml/*.svg`（由同目录的 `gen_uml.py` 画出，146 题里 100 题带图）。导入命令见 `docs/question-sources/README.md`。

### 3.4 带图题目在流水线里的几个细节

- **图片引用算题干文字**：校验题干长度（6～300 字）时，`![](media:` + 24 位 id + `)` 约 34 个字符也计入。
- **去重**：规范化时把图片 id 当普通字母数字处理，所以「题干文字相同、只是图不同」的两道题**不会被判成重复**。
- **讲义里的图**：切块器**不处理图片**，`![](media:…)` 会原样留在块文本里发给模型（`architecture.md` §5.1 写的「图片仅保留 alt 文本」目前没有实现）。模型即使把这段引用抄进题干，规则校验也不会拦它；但那张图是否合适没人检查，要靠人工审核。所以实际上不要指望靠 AI 出带图题，需要图的题请手写。
- **没有垃圾回收**：换图等于换一个新 id，旧图仍留在 `media` 表里，服务端不会清理没人引用的图；图片不随 `question` 同步，只靠题目文字里的引用。

### 3.5 客户端怎么显示

三端都用同一个正则识别 `![alt](media:<24位十六进制>)`，把 `media:<id>` 换成 `/api/v1/media/<id>`：

| 端 | 题干 / 解析（Markdown） | 选项 | 其他 |
|---|---|---|---|
| H5 | `Md.vue` 的 markdown-it 自定义图片渲染，`<img class="qimg" loading="lazy">`，点击放大（`lightbox.ts`） | `OptText.vue` 用 `segments()` 把选项拆成文字和图片；选项按纯文本显示（可能含 `*p++`、`<T>`，Markdown 会吃掉），只识别图片语法；点图放大，点其余部分选答案 | 浏览器 HTTP 缓存 |
| Flutter | 同上，点击全屏、双指缩放（`quiz_media.dart`）；按文件内容判断，SVG 用 `SvgPicture.file`，位图用 `Image.file` | `splitPictures()` 拆分 | 每次同步结束后 `MediaStore.prefetch` 把所有题用到的图下载到本机（并发 3），离线也能看；没下载到的在显示时再取，失败可点「重试」 |
| 管理后台 | `withMediaUrls()` 先把 `media:` 换成 URL 再渲染 | `segments()` | 审核页、编辑框里都能看到图 |

列表、搜索、错题本里图片显示成 `[图]` / `[图：说明]`（`plainText()`），搜索不会命中图片 id。

---

## 4. 另一回事：AI 解读里的图（不是题目本身）

做完题后点「AI 解读」，由 **Flutter 客户端直连** OpenAI 兼容接口（配置由服务端下发，见 architecture.md §7.6）。这里和图有两处关系，但**都不改变题目**：

1. **题目里的图喂给模型**（`app/lib/data/ai_prompt.dart`，提示词版本 `explain.v3`）：题目里的图在文字中标成 `[图1]`、`[图2]`，位图作为 `image_url`（data URI，合计 ≤ 6 MB）随消息发出；模型不支持图片（HTTP 400 / 415 / 422）时自动改成纯文字重问一次，并在卡片上注明。**SVG 配图不当图片发**（多数模型不收 `image/svg+xml`），而是把 SVG 源码贴在提示词里，模型读 SVG 文本比读位图更准。
2. **让模型画示意图**：提示词允许模型在回答里写一个 ` ```svg ` 代码块（最多一张，元素不超过 30 个、只许 rect/circle/line/path/text 等基础元素）。Flutter（`flutter_svg`）和管理后台把它画出来：
   - 必须**写完**（有结尾围栏、有 `</svg>`）才渲染，流式生成中仍显示为代码；
   - 含 `<script>`、`<foreignObject>`、`<image>` 或超过 60 KB 时不画，按代码显示；
   - 管理后台用 `<img src="data:image/svg+xml,…">` 显示，所以图里的脚本不会执行；`fenceSvg()` 还会兜底修正模型漏写或写错的围栏。

   这是临时的讲解配图，不会保存成题目，也不进入 `media` 表。

---

## 5. 关键代码索引

| 环节 | 位置 |
|---|---|
| 导入文档 / 题库 | `server/internal/service/documents.go` |
| 切块 | `server/internal/pipeline/chunker.go` |
| 切块比对、出题任务、入库 | `server/internal/service/pipeline.go` |
| 出题提示词 | `server/internal/pipeline/prompts/generate_system.v1.txt` |
| 出题调用与 Schema | `server/internal/pipeline/generate.go`、`schema.go` |
| 规则校验 | `server/internal/pipeline/validate.go` |
| 去重 | `server/internal/pipeline/dedupe.go` |
| 审核、编辑、发布 | `server/internal/service/review.go` |
| 任务队列 | `server/internal/jobs/jobs.go` |
| 图片存储与引用检查 | `server/internal/service/media.go`、`migrations/00010_media.sql` |
| 图片接口 | `server/internal/httpapi/handlers.go`（`uploadMedia`、`getMedia`） |
| 手写题导入 | `server/cmd/devseed/main.go`、`docs/question-sources/README.md` |
| 后台插图 / 粘贴 | `admin/src/components/EditQuestionDialog.vue`、`MediaButton.vue`、`admin/src/utils/media.ts` |
| H5 显示 | `h5/src/components/Md.vue`、`OptText.vue`、`h5/src/quiz/media.ts` |
| Flutter 显示与离线 | `app/lib/features/quiz/quiz_media.dart`、`app/lib/data/media_store.dart`、`media_text.dart` |
| AI 解读提示词 | `app/lib/data/ai_prompt.dart` |

## 6. 已知局限

- AI 出题只读文字，**无法为带图讲义出带图题**，需要图的题得手写。
- 没有独立作答校验，所有通过规则的题都要人工审核（计划放到 M3）。
- 规则校验只能证明 `source_quote` 在原文里，**不能证明答案本身正确**，这一步靠人工审核。
- 结构化输出失败时没有「带错误信息让模型修复重试」，只有丢弃该题或整任务重试。
- 只有单选和判断两种题型。
- `media` 表里没人引用的图不会被清理。

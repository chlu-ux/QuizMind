# QuizMind

个人自用的 AI 刷题系统：把 Markdown 讲义交给 AI 生成题目，经自动校验和人工审核后发布成题库，再在手机上刷题、复习错题。

```
Markdown 文档 → AI 生成题目 → 自动校验 → 人工审核 → 发布题库 → 手机刷题 → 错题 / 复习
```

核心思路：**题目离线预生成**（客户端不等 AI 实时出题）、**每道题必须有原文出处**、**LLM 供应商可替换**，以及一个二进制加一个 SQLite 文件就能部署。

## 组成

| 目录 | 说明 | 技术 |
|---|---|---|
| [`server/`](server/) | 服务端：REST API、SSE 进度推送、出题流水线、内嵌的管理后台和 H5 | Go、chi、SQLite（modernc）、sqlc、goose |
| [`admin/`](admin/) | 管理后台：上传文档、审核题目、题库 / 任务 / 用量 / AI 解读配置 | Vue 3、Element Plus、Pinia |
| [`h5/`](h5/) | 手机网页版刷题客户端（浏览器打开 `/m/`），数据存 IndexedDB | Vue 3、Vite、TypeScript |
| [`app/`](app/) | Flutter 原生客户端（Android），功能与 H5 保持一致 | Flutter、Drift |
| [`api/openapi.yaml`](api/openapi.yaml) | 客户端使用的 `/api/v1/*` 接口契约 | OpenAPI 3.0 |
| [`docs/`](docs/) | 架构设计、迭代方案、题库素材 | — |
| `deploy.sh` | 一键构建：服务端 + 管理后台 + H5 + 签名 Android APK | Bash |
| `release/` | 打好的 APK（`quizmind-latest.apk` 为最新版） | — |

## 功能

**服务端 / 管理后台**

- 上传 Markdown，按标题切块，增量更新（内容没变的小节不重复生成）
- 在管理后台配置多个供应商和模型（Anthropic / OpenAI 兼容），按角色（出题、复核、助手、AI 解读）指定，保存即生效
- 单选 / 判断题生成，规则校验（原文出处必须能原样找到、选项不重复）、近似题去重
- 审核页：原文高亮、快捷键、批准 / 驳回；用户反馈的题自动下线待审，可「处理完毕」
- 题目支持插图（UML、流程图等），可在编辑器里粘贴截图
- 任务队列与实时进度（SSE）、LLM 用量与每日 token 预算
- AI 解读：指定一个 OpenAI 兼容的模型，客户端可请求 AI 解释题目

**H5 / Flutter 客户端**

- 题库列表、顺序 / 随机刷题、按章节（模块）和知识点刷题、题库内搜索
- 错题本（按题库区分）、收藏、题目反馈
- 模拟考试、题库统计分析（刷题时间 / 学习时间）
- 每日目标与提醒
- 离线本地存储，与服务端增量同步

## 快速开始

需要 Go、Node.js / npm；用 Flutter 客户端还需要 Flutter SDK。

```bash
cd server
cp config.example.yaml config.yaml     # 可选，默认配置即可本地使用
make web                               # 构建管理后台和 H5，嵌入二进制
make run                               # http://127.0.0.1:8080
```

- 管理后台：`http://127.0.0.1:8080/`；首次使用先到「AI 与模型」页添加供应商（Anthropic 或 OpenAI 兼容）和模型，并指定给「出题」角色，不设置也能启动，但出题任务会失败
- 手机 H5：`http://127.0.0.1:8080/m/`

没有 API Key 时，可以先灌入示例数据体验整个流程：

```bash
make seed
```

### 局域网手机访问

把 `server/config.yaml` 里的 `listen` 改成 `0.0.0.0:8080`，**并设置 `QUIZMIND_TOKEN`**（监听非回环地址时必须），然后手机打开 `http://<Mac 的局域网 IP>:8080/m/`，在「设置」里填入服务器地址和 token。

### 后台运行

```bash
cd server
./run.sh                 # 重新编译并重启
./run.sh restart -w      # 同时重新构建管理后台和 H5
./run.sh start|stop|status|logs
```

访问令牌放在 `server/.token`（其他环境变量可放 `server/.env`），两者都不会提交；模型的 API Key 在管理后台配置，存在数据库里。

## 导入题库素材

`docs/question-sources/` 里是手写的「软件设计师（中级）」讲义和题目，走与 AI 生成相同的校验与去重流水线导入：

```bash
cd server
go run ./cmd/devseed -config config.yaml \
  -doc ../docs/question-sources/software-designer.b01-computer.md \
  -questions ../docs/question-sources/software-designer.b01-computer.questions.json \
  -bank "软件设计师（中级）" -append -approve -1
```

参数说明、带图题目和修改题目的方法见 [`docs/question-sources/README.md`](docs/question-sources/README.md)。

## 开发与测试

```bash
# 服务端
cd server
make test            # go test -race ./...
make vet
make sqlc            # 修改 internal/db/migrations 或 queries 后重新生成

# 管理后台 / H5
cd admin             # 或 cd h5
npm ci
npm run dev          # admin 代理到 127.0.0.1:8080；H5 在 http://localhost:5174/m/
npm test
npm run typecheck

# Flutter 客户端
cd app
flutter pub get
flutter test
```

## 部署与发布

```bash
./deploy.sh                # 服务端 + 管理后台 + H5 + 签名 APK
./deploy.sh --skip-app     # 只构建并重启服务端和网页端
./deploy.sh --skip-server  # 只构建 Android release APK
```

APK 需要 `app/android/key.properties` 和对应的 keystore，缺少时脚本会直接报错，避免误打出 debug 签名的包。产物输出到 `release/quizmind-<版本>.apk` 和 `release/quizmind-latest.apk`。

数据都在 `data_dir/app.db`（SQLite，WAL 模式）。备份方法：

```bash
sqlite3 app.db "VACUUM INTO 'backup.db'"
```

注意数据库里存有图片和所有模型的 API Key，备份文件要按密钥对待。

## 安全说明

- 题库接口（`/api/v1`）无需鉴权；管理接口（`/admin`）由静态 Token 保护，通过 `Authorization: Bearer <token>` 发送。
- 密钥只从环境变量读取，不写进配置文件。
- 仅供个人使用，没有多用户体系；服务端建议只在可信的局域网或 Tailscale 内暴露。

## 文档

- [架构设计](docs/architecture.md)：技术栈、LLM 抽象层、出题流水线、数据模型、同步协议、路线图
- [迭代方案 2026-10-05](docs/iteration-2026-10-05.md)：每日目标、按知识点刷题、题库内搜索、反馈处理、错题本分题库
- 各子项目的详细说明：[server](server/README.md) · [admin](admin/README.md) · [h5](h5/README.md) · [app](app/README.md)

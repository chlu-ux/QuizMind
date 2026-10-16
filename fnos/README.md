# fnos：QuizMind 飞牛应用

把 QuizMind 服务（题库、手机网页版、后台管理）打成飞牛（fnOS）的 `.fpk` 应用，**题库数据一起打进包里**。做法见 `docs/飞牛应用打包指南.md`（stockdb 仓库）和 developer.fnnas.com。

## 打包

```bash
cd server && make web && cd ..      # 后台管理和手机网页版是内嵌在二进制里的，改过前端先重建
./fnos/build.sh x86                 # fnos/dist/quizmind-x86.fpk（ARM 的 NAS 用 arm）
```

需要 `fnos/tools/bin/fnpack`（官方工具，不进 git）和 `sqlite3`。`build.sh` 做了这些事：

1. `CGO_ENABLED=0` 交叉编译 `server/cmd/quizmind` 成静态 Linux 二进制。
2. 从本机运行库（`SEED_DB`，默认 `~/Library/Application Support/QuizMind/app.db`）导出**内置题库** `app/defaults/seed.db`：保留题库、讲义、题目、图片；删掉作答记录、收藏、AI 对话和笔记、任务和调用日志、**模型配置里的 API Key**，以及被 Java / C++ 拆分取代的旧合并库（`SKIP_BANKS`）。
3. 改 `manifest` 的 `platform`，`fnpack build`。

当前内置：软件设计师（中级）1027、强化训练 742、UML 图专项 146、下午题六 Java 145、下午题六 C++ 69，共 2129 题，包 8.5 MB。

## 运行方式

| 项 | 值 |
|---|---|
| 端口 | 8090（`manifest` 的 `service_port`，桌面图标打开 `/m/` 手机网页版；后台管理在 `/`） |
| 运行用户 | `quizmind`（低权限） |
| 数据 | `$TRIM_PKGVAR/data/app.db`：首次启动从 `defaults/seed.db` 拷入，之后不会被覆盖，升级、重装保留 |
| 配置 | `$TRIM_PKGETC/quizmind.env`（权限 600）：`BIND`、`TOKEN` |
| 日志 | `$TRIM_PKGVAR/service.log`（守护脚本）、`quizmind.log`（服务） |
| 管理口令 | 安装向导里设置，作为 `QUIZMIND_TOKEN` 传给服务；只保护 `/admin`，刷题页和 App 同步接口不需要口令，所以只放在局域网；外网访问走飞牛自带的 HTTPS / 域名转发 |

没有配置出题模型：NAS 上只刷题，不在 NAS 上生成题目。要用的话在后台管理里加模型和 API Key（会存进 `app.db`）。

## 验证记录

本机模拟环境变量（darwin 版程序 + 同样的脚本，2026-10-13）已验证：安装回调写配置（权限 600）→ `start` 载入内置题库并监听 → 5 个题库 2129 题可查、`/m/` 和 `/` 可打开、`/admin` 无口令 401 → `kill -9` 后 10 秒内自动重启 → `stop` 无残留进程、`status` 返回 3 → 升级回调后数据和配置保留。

**未在真机上验证**：飞牛安装流程、向导、桌面图标、`run-as: package` 下的目录权限。需要在测试用的飞牛上装一遍，顺序见指南第 7 节。

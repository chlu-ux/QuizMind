# 题库素材

每个批次由两个文件组成，文件名里的编号对应 [大纲](software-designer.outline.md) 的批次计划：

| 文件 | 内容 |
|---|---|
| `software-designer.bNN-*.md` | 讲义：每个二级标题是一个考点小节（编号对应大纲），正文只写该考点的基本事实 |
| `software-designer.bNN-*.questions.json` | 题目：以「一级标题 > 小节标题」为键的手写题目，格式与服务端流水线的生成结果相同（`type`、`stem`、`options`、`answer_index`、`explanation`、`difficulty`、`tags`、`source_quote`） |

`software-designer.md` / `software-designer.questions.json` 是批次 0（最早的 15 小节、45 题）。

另有 4 个强化训练批次（`software-designer.r01-formula` / `r02-hot` / `r03-hard` / `r04-pm`，共 742 题），侧重计算公式与速算、上午高频考点、难点和下午案例题，说明与速算公式速查表见 [强化训练大纲](software-designer.reinforce-outline.md)，导入方式相同。

## 导入

题目走真实的校验与去重流水线：`source_quote` 必须能在对应小节里原样找到，选项不能重复，近似题会被拦下。

```bash
cd server
go run ./cmd/devseed -config config.yaml \
  -doc ../docs/question-sources/software-designer.b01-computer.md \
  -questions ../docs/question-sources/software-designer.b01-computer.questions.json \
  -bank "软件设计师（中级）" -append -approve -1
```

- `-append`：往已有的同名题库里加文档（不加则题库已存在时什么也不做）。
- `-approve -1`：发布这份文档里全部通过校验的题；省略则只发布前 6 题，`0` 表示都留给后台人工审核。
- 被拒的题会连同原因打印出来。同一个文档内容没变时重复导入不会重复生成。
- 服务端正在运行时也可以导入。注意：运行中的服务端也会从同一张任务表里抢任务，如果它没有配置出题模型，抢到的小节会失败，文档状态变成 `failed`。遇到这种情况，把讲义末尾加一个空行后用同样的命令再导入一次即可（只会重新生成失败的小节）。

## 带图的题目

题干、选项、解析里可以放图（UML 图、流程图等）：把图片放在讲义旁边的文件夹里，在题目 JSON 的 `stem` / `options` / `explanation`（和讲义）里写相对路径 `![类图](img/class.png)`，导入时 devseed 会把图上传到服务端并改成 `media:` 引用。图片目录默认是讲义所在的文件夹，可以用 `-images <目录>` 指定；路径不能跑出这个目录，只收 PNG / JPEG / GIF / WebP（≤ 5 MB）。选项也可以是一张图，写成 `"options": ["![](img/a.png)", "![](img/b.png)", ...]`。

## 修改题目

题目保存在数据库里，改了 JSON 文件不会自动同步。要改某道题：在管理后台里改，或者驳回它；也可以先改 JSON，再让对应小节的讲义正文有所变动（哪怕只改一个字）后重新导入——正文变了的小节会被视为已修改，旧题标为过期，并按 JSON 重新生成。

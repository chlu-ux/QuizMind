# 题库素材

每个批次由两个文件组成，文件名里的编号对应 [大纲](software-designer.outline.md) 的批次计划：

| 文件 | 内容 |
|---|---|
| `software-designer.bNN-*.md` | 讲义：每个二级标题是一个考点小节（编号对应大纲），正文只写该考点的基本事实 |
| `software-designer.bNN-*.questions.json` | 题目：以「一级标题 > 小节标题」为键的手写题目，格式与服务端流水线的生成结果相同（`type`、`stem`、`options`、`answer_index`、`explanation`、`difficulty`、`tags`、`source_quote`） |

`software-designer.md` / `software-designer.questions.json` 是批次 0（最早的 15 小节、45 题）。

另有 4 个强化训练批次（`software-designer.r01-formula` / `r02-hot` / `r03-hard` / `r04-pm`，共 742 题），侧重计算公式与速算、上午高频考点、难点和下午案例题，说明与速算公式速查表见 [强化训练大纲](software-designer.reinforce-outline.md)，导入方式相同。

> **讲义也是学习材料**：App 的「先学后练」把这些讲义按小节原样展示给学生读（见 [architecture.md §3.6](../architecture.md)），所以讲义除了给出题提供出处，还会被人直接阅读：每个二级标题就是一节，标题要能让人一眼看出考点；正文按「一句一行」显示，写成一段话也可以，但别把列表和表格揉进一段里。改了某一节的文字后，重新导入会让这一节换新的小节 id（旧题随之过期、重新生成），已读标记因此作废。

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

## UML 图专项（带 SVG 图）

`software-designer.u01-uml.md` + `.questions.json` 是单独的一个专项题库（建议建成独立题库「UML 图专项」，不并进软件设计师题库）：15 个小节（UML 14 种图与分类、4+1 视图、类的表示、六种类间关系、关系辨析、多重度、综合读图、用例图及其关系、顺序图、通信图与对象图、状态图、活动图、构件图 / 部署图 / 包图、按需求选图），共 146 题；题干、选项里放 UML 图，读图识关系、认符号、辨图的种类。

- 图在 `uml/*.svg`，是**手写的静态 SVG**，由 `uml/gen_uml.py`（依赖同目录的 `svglib.py`）生成：`cd uml && python3 gen_uml.py`。要改图就改脚本再重新生成；箭头用多边形画，不用 `<marker>`、CSS，保证浏览器、Flutter 画出来一样。
- 服务端只收静态 SVG（见 architecture.md §7.7），导入时 devseed 把 `uml/xxx.svg` 上传并改写成 `media:` 引用。因此导入要用**新版**的 devseed（`go run` 会自动用当前源码）。
- 题目里图片的 alt 文本刻意写成「示意图」「关系图」，不透露答案（alt 会出现在列表和搜索里）。

```bash
cd server
go run ./cmd/devseed -config config.yaml \
  -doc ../docs/question-sources/software-designer.u01-uml.md \
  -questions ../docs/question-sources/software-designer.u01-uml.questions.json \
  -bank "UML 图专项" -approve -1
```

## 下午题六：设计模式代码填空（Java / C++ 分开）

下午题试题六（设计模式填空）的专项题库按语言拆成两个独立题库，各自一份讲义和题目：

| 题库 | 讲义 / 题目文件 | 内容 |
|---|---|---|
| 软件设计师·下午题六（设计模式·Java） | `software-designer.t6-pattern-java.md` + `.questions.json`，另加 `software-designer.t6-pattern-concept.md` + `.questions.json` | T6.1 Java 语法 + 21 个设计模式的 Java 代码填空，共 72 题；加上语言无关的概念题 73 题（每个模式 3 道，加一节分类与设计原则），共 145 题 |
| 软件设计师·下午题六（设计模式·C++） | `software-designer.t6-pattern-cpp.md` + `.questions.json` | T6.1 C++ 语法 + 21 个设计模式的 C++ 代码填空，共 69 题 |

两份讲义的小节编号一致（T6.1 语法，T6.2～T6.22 为 21 个模式），每个模式的「意图」「类图角色」和「常见填空」按语言各写一份；模式描述里两种语言通用的句子在两份讲义里都有。概念题讲义由脚本生成，目前只导入 Java 库，将来做 C++ 时用 `-append` 把它再导入 C++ 库即可。题干仍然是带类图（SVG）的完整代码框架，只留一个空，选项是代码片段。设计说明、题目格式、导入时服务端校验规则的调整见 [设计文档](software-designer.t6-pattern-code.outline.md)。

题目和类图由 `pattern-code/` 下的脚本从案例数据生成（案例代码都用 javac / clang++ 编译运行验证过）。导入需要 `QUIZMIND_TOKEN`（`server/run.sh` 会从 `server/.token` 读取）：

```bash
cd docs/question-sources/pattern-code && python3 build.py --check
cd ../../../server
go run ./cmd/devseed -config config.yaml \
  -doc ../docs/question-sources/software-designer.t6-pattern-java.md \
  -questions ../docs/question-sources/software-designer.t6-pattern-java.questions.json \
  -bank "软件设计师·下午题六（设计模式·Java）" -approve -1
go run ./cmd/devseed -config config.yaml \
  -doc ../docs/question-sources/software-designer.t6-pattern-concept.md \
  -questions ../docs/question-sources/software-designer.t6-pattern-concept.questions.json \
  -bank "软件设计师·下午题六（设计模式·Java）" -append -approve -1
go run ./cmd/devseed -config config.yaml \
  -doc ../docs/question-sources/software-designer.t6-pattern-cpp.md \
  -questions ../docs/question-sources/software-designer.t6-pattern-cpp.questions.json \
  -bank "软件设计师·下午题六（设计模式·C++）" -approve -1
```

## 下午题四：算法（由 `algorithms/` 的代码改写）

独立题库「软件设计师·下午题四（算法）」：把仓库根目录 `algorithms/` 下 17 个算法的 C 代码（带考点注释）改写成讲义，再按讲义出题，共 28 个小节、198 题。

| 文件 | 内容 |
|---|---|
| `software-designer.t4-algo.md` | 讲义：T4.1 设计策略、T4.2 排序对比，之后每个算法一到两节（「思想与考点」「核心代码」），代码取自 `algorithms/*.c` 的关键片段 |
| `software-designer.t4-algo.questions.json` | 题目，由 `algo-code/` 下的脚本生成，不要手改 |

题型：概念与复杂度（单选 / 判断）、手算（快排第一趟、堆的建立、归并第几趟、背包 / LCS / 矩阵连乘 / 最短路径 / 最小生成树 / KMP 的 next 数组等，数值都用 `algorithms/` 里的代码或独立脚本核对过）、代码填空（循环边界、比较符号、递推式、递归出口，对应代码里的 `【填空】` 标记）。

```bash
cd docs/question-sources/algo-code && python3 build.py          # 重新生成题目 JSON，并按服务端规则预检
cd ../../../server
go run ./cmd/devseed -config config.yaml \
  -doc ../docs/question-sources/software-designer.t4-algo.md \
  -questions ../docs/question-sources/software-designer.t4-algo.questions.json \
  -bank "软件设计师·下午题四（算法）" -approve -1
```

`build.py` 检查题干 / 选项长度、选项互不相同、`source_quote` 能在所属小节里原样找到、每节不超过 10 题（devseed 每块最多取 10 题）、每节不超过 1450 字（超过 1500 字会被切成两块）。题目写在 `algo-code/q1.py`～`q3.py`，用 `dsl.py` 里的 `S`（单选）、`J`（判断）、`F`（代码填空）三个函数。

## 基础知识速记题库（讲义 + 配套题目）

`software-designer.s01-…` 到 `s11-…` 共 11 份、66 个小节，是把 `docs/软件设计师基础知识背诵文件.pdf`（16 页速记表）逐页对着图片转写成的 Markdown：每章一份文档、每个考点一节（`## 1.1 …`），表格保留成 Markdown 表格，PDF 里的 ⚠ 提醒写成引用块。它们既是 App「先学后练」（architecture.md §3.6）的阅读材料，也配了题目，导入独立题库「软件设计师·基础知识速记」，共 583 题（单选 495、判断 88，判断题对错各 44）。

- 版权：原资料带「未来教育版权所有」。这里只是个人学习用的转写，**不要把这些文件和 PDF 公开发布**。
- 转写时的改动：把 PDF 里明显的印刷问题按通行写法改了，并在文中用「注：」标出（主定理表里的 Θ 被印成 O；外观设计专利期限 2021 年起改为 15 年；商标续展的申请时间窗），以考试用的版本为准；出题时避开了这几处有出入的内容。
- 11 份文档共 85 KB、每节 240–1100 字，都在切块上限内，所以一节就是一个小节（不会被拆成两个同名小节）。

| 文件 | 内容 |
|---|---|
| `software-designer.sNN-recite-*.md` | 讲义（转写） |
| `software-designer.sNN-recite-*.questions.json` | 题目，由 `recite-code/` 下的脚本生成，不要手改 |

题目手写在 `recite-code/q01.py`～`q11.py`（每章一个文件，用 `dsl.py` 里的 `S` 单选、`J` 判断），每节 5～10 题，只考该节写明的事实；计算题的数值（补码范围、磁盘访问时间、环路复杂度、主定理、位示图等）都按讲义里的公式手算核对过。`build.py` 生成 JSON，并按服务端规则预检：题干 / 选项长度、选项互不相同、`source_quote` 能在所属小节里原样找到、每节不超过 10 题、每节不超过 1450 字、题干不重复。

```bash
cd docs/question-sources/recite-code && python3 build.py   # 重新生成 11 份题目 JSON，并预检
cd ../../../server
for f in ../docs/question-sources/software-designer.s*-recite-*.md; do
  go run ./cmd/devseed -config config.yaml -doc "$f" -questions "${f%.md}.questions.json" \
    -bank "软件设计师·基础知识速记" -append -approve -1
done
```

> **导入前先停掉正在运行的服务端。** 服务端配了出题模型时，会和 devseed 抢同一张任务表里的出题任务，抢到的小节会改用真实模型出题（花 token，题目也不是这里手写的那批）。导入完成后再用 `server/run.sh` 启动。
> 先在临时数据目录（把 `data_dir` 指到一个空文件夹，`listen` 改成 `127.0.0.1:…`）试跑一遍最稳：这批题 583 题全部通过校验和去重。

早先这 11 份讲义还以「只学习、不出题」的方式导入过「软件设计师（中级）」题库（空题目文件，文档状态 `review`、题数 0，App 里排在 `考点精讲` 各章之后，章名带「基础知识速记」）。那一份保持不变；新题库是单独的一份，两边互不影响。

## 修改题目

题目保存在数据库里，改了 JSON 文件不会自动同步。要改某道题：在管理后台里改，或者驳回它；也可以先改 JSON，再让对应小节的讲义正文有所变动（哪怕只改一个字）后重新导入——正文变了的小节会被视为已修改，旧题标为过期，并按 JSON 重新生成。

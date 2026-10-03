package pipeline

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var testOpts = ChunkOptions{MinChars: 100, MaxChars: 400}

func para(s string, n int) string { return strings.Repeat(s, n) }

func TestSplit_HeadingPathsAndTitle(t *testing.T) {
	md := "# 并发编程\n\n" + para("并发编程是同时处理多个任务的能力。", 12) +
		"\n\n## 锁\n\n### 读写锁\n\n" + para("读写锁允许多个读者同时访问共享资源。", 12) +
		"\n\n### 互斥锁\n\n" + para("互斥锁保证同一时刻只有一个线程进入临界区。", 12) + "\n"
	title, chunks := Split(md, ChunkOptions{MinChars: 50, MaxChars: 1000})
	assert.Equal(t, "并发编程", title)
	require.Len(t, chunks, 3)
	assert.Equal(t, "并发编程", chunks[0].HeadingPath)
	assert.Equal(t, "并发编程 > 锁 > 读写锁", chunks[1].HeadingPath)
	assert.Equal(t, "并发编程 > 锁 > 互斥锁", chunks[2].HeadingPath)
	for i, c := range chunks {
		assert.Equal(t, i, c.Seq)
		assert.NotEmpty(t, c.Hash)
	}
}

func TestSplit_MergesSmallSections(t *testing.T) {
	md := "# Doc\n\n## A\n\n" + para("alpha beta gamma. ", 3) + "\n\n## B\n\n" + para("delta epsilon zeta. ", 3) + "\n"
	_, chunks := Split(md, ChunkOptions{MinChars: 200, MaxChars: 1000})
	require.Len(t, chunks, 1)
	assert.Equal(t, "Doc", chunks[0].HeadingPath, "merged chunk takes the common ancestor path")
	assert.Contains(t, chunks[0].Text, "## B", "later heading line kept inline")
	assert.Contains(t, chunks[0].Text, "alpha")
	assert.Contains(t, chunks[0].Text, "delta")
}

func TestSplit_OversizedSplitsOnBlockBoundaries(t *testing.T) {
	var blocks []string
	for i := 0; i < 6; i++ {
		blocks = append(blocks, para("这是第"+string(rune('一'+i))+"个相当长的段落用于测试切分逻辑。", 8))
	}
	md := "# T\n\n" + strings.Join(blocks, "\n\n") + "\n"
	_, chunks := Split(md, testOpts)
	require.Greater(t, len(chunks), 1)
	for _, c := range chunks {
		assert.LessOrEqual(t, len([]rune(c.Text)), testOpts.MaxChars+len([]rune(blocks[0])),
			"soft limit: at most one block over the max")
		assert.Equal(t, "T", c.HeadingPath)
	}
}

func TestSplit_CodeFenceNotSplitAndHashInFenceNotHeading(t *testing.T) {
	code := "```go\n# not a heading\n\nfunc main() {}\n\nvar x = 1\n```"
	md := "# T\n\n" + para("说明文字用来凑足长度。", 20) + "\n\n" + code + "\n\n" + para("尾部说明文字也要足够长。", 20) + "\n"
	_, chunks := Split(md, ChunkOptions{MinChars: 100, MaxChars: 250})
	found := false
	for _, c := range chunks {
		assert.Equal(t, "T", c.HeadingPath, "'# not a heading' inside a fence must not create a section")
		if strings.Contains(c.Text, "func main()") {
			found = true
			assert.Contains(t, c.Text, "```go", "fence opening stays with its body")
			assert.Contains(t, c.Text, "var x = 1\n```", "fence closing stays with its body")
		}
	}
	assert.True(t, found)
}

func TestSplit_FrontMatterAndPreamble(t *testing.T) {
	md := "---\ntitle: \"我的笔记\"\ntags: [a]\n---\n\n" + para("开头没有标题的一段文字内容。", 10) +
		"\n\n# 章节\n\n" + para("章节正文内容需要足够长才能保留。", 10) + "\n"
	title, chunks := Split(md, ChunkOptions{MinChars: 20, MaxChars: 1000})
	assert.Equal(t, "我的笔记", title)
	require.Len(t, chunks, 2)
	assert.Equal(t, "我的笔记", chunks[0].HeadingPath)
	assert.NotContains(t, chunks[0].Text, "tags:")
	assert.Equal(t, "章节", chunks[1].HeadingPath)
}

func TestSplit_SetextHeadingsAndCRLF(t *testing.T) {
	md := "Title\r\n=====\r\n\r\n" + para("正文内容足够长以保留下来。", 12) + "\r\n\r\nSub\r\n---\r\n\r\n" + para("子节内容足够长以保留下来。", 12) + "\r\n"
	title, chunks := Split(md, ChunkOptions{MinChars: 20, MaxChars: 1000})
	assert.Equal(t, "Title", title)
	require.Len(t, chunks, 2)
	assert.Equal(t, "Title", chunks[0].HeadingPath)
	assert.Equal(t, "Title > Sub", chunks[1].HeadingPath)
	assert.NotContains(t, chunks[0].Text, "=====")
	assert.NotContains(t, chunks[1].Text, "---")
}

func TestSplit_DropsTinyAndDuplicateChunks(t *testing.T) {
	body := para("重复内容用来测试去重逻辑是否生效。", 8)
	md := "# B\n\n" + body + "\n\n# B\n\n" + body + "\n\n# A\n\nhi\n"
	_, chunks := Split(md, ChunkOptions{MinChars: 10, MaxChars: 1000})
	require.Len(t, chunks, 1, "tiny chunk dropped, identical (path,text) chunk deduped")
	assert.Equal(t, "B", chunks[0].HeadingPath)
}

func TestSplit_HashStableAndSensitive(t *testing.T) {
	md := "# T\n\n" + para("稳定的内容用于哈希测试。", 12) + "\n"
	_, a := Split(md, testOpts)
	_, b := Split(md, testOpts)
	require.Len(t, a, 1)
	assert.Equal(t, a[0].Hash, b[0].Hash)
	_, c := Split(strings.Replace(md, "稳定", "变化", 1), testOpts)
	assert.NotEqual(t, a[0].Hash, c[0].Hash)
}

func TestSplit_EmptyAndHeadingOnly(t *testing.T) {
	_, chunks := Split("", testOpts)
	assert.Empty(t, chunks)
	_, chunks = Split("# only a heading\n", testOpts)
	assert.Empty(t, chunks)
}

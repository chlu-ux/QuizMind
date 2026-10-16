package pipeline

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func vq(stem string, opts ...string) ValidQuestion {
	return ValidQuestion{Stem: stem, Options: opts, Hash: ContentHash(stem, opts)}
}

func TestDeduper_ExactAndNear(t *testing.T) {
	existing := []Existing{{ID: "q1", Stem: "读写锁允许多个读者同时持有锁吗", Options: []string{"允许", "不允许", "视情况", "未知"},
		Hash: ContentHash("读写锁允许多个读者同时持有锁吗", []string{"允许", "不允许", "视情况", "未知"})}}
	d := NewDeduper(existing, 0.8)

	id, dup := d.Check("n1", vq("读写锁允许多个读者同时持有锁吗", "允许", "不允许", "视情况", "未知"))
	assert.True(t, dup)
	assert.Equal(t, "q1", id, "exact duplicate of existing")

	id, dup = d.Check("n2", vq("读写锁允许多个读者同时持有锁吗？", "允许", "不允许", "视情况", "不清楚"))
	assert.True(t, dup, "near duplicate: one option differs")
	assert.Equal(t, "q1", id)

	_, dup = d.Check("n3", vq("互斥锁在同一时刻允许几个线程进入临界区", "一个", "两个", "任意个", "零个"))
	assert.False(t, dup)

	id, dup = d.Check("n4", vq("互斥锁在同一时刻允许几个线程进入临界区", "一个", "两个", "任意个", "零个"))
	assert.True(t, dup, "batch members are remembered")
	assert.Equal(t, "n3", id)
}

func TestDeduper_GenericStemWithDifferentOptionsIsNotDuplicate(t *testing.T) {
	d := NewDeduper(nil, 0.8)
	_, dup := d.Check("a", vq("下列说法正确的是", "读写锁允许多个读者", "互斥锁允许多个写者", "自旋锁会睡眠", "信号量只能为一"))
	assert.False(t, dup)
	_, dup = d.Check("b", vq("下列说法正确的是", "TCP 是面向连接的协议", "UDP 提供可靠传输", "IP 负责端口复用", "ARP 解析域名"))
	assert.False(t, dup, "same stem, unrelated options")
}

func TestDeduper_CodeQuestionsOnTheSameSnippetAreNotNearDuplicates(t *testing.T) {
	snippet := func(blank string) string {
		return "下面是单例模式的实现，空缺处应填入：\n```java\nclass Config {\n    " + blank + " Config() { }\n    public static Config getInstance() { return instance; }\n}\n```"
	}
	d := NewDeduper(nil, 0.8)
	_, dup := d.Check("a", vq(snippet("______"), "private", "public", "protected", "abstract"))
	assert.False(t, dup)
	_, dup = d.Check("b", vq(snippet("private"), "private", "public", "protected", "static"))
	assert.False(t, dup, "same code, different blank")
	id, dup := d.Check("c", vq(snippet("______"), "private", "public", "protected", "abstract"))
	assert.True(t, dup, "an exact duplicate is still caught")
	assert.Equal(t, "a", id)
}

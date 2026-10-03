package pipeline

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const chunk = "读写锁允许多个读者同时持有锁，但写者必须独占。**互斥锁**保证同一时刻只有一个线程进入临界区。"

func goodSingle() GeneratedQuestion {
	return GeneratedQuestion{
		Type:        "single",
		Stem:        "关于读写锁，下列哪项描述是正确的？",
		Options:     []string{"A. 写者可以与读者并行", "B. 多个读者可同时持有锁", "C. 同一时刻只有一个读者", "D. 读写锁不允许写者"},
		AnswerIndex: 1,
		Explanation: "原文指出读写锁允许多个读者同时持有锁。",
		Difficulty:  2,
		Tags:        []string{"并发", "锁"},
		SourceQuote: "读写锁允许多个读者同时持有锁",
	}
}

func TestValidate_AcceptsGoodSingleAndStripsLabels(t *testing.T) {
	v, err := ValidateQuestion(goodSingle(), chunk)
	require.NoError(t, err)
	assert.Equal(t, "写者可以与读者并行", v.Options[0], "A./B. labels removed")
	assert.Equal(t, 1, v.AnswerIndex)
	assert.NotEmpty(t, v.Hash)
}

func TestValidate_QuoteMatchIgnoresMarkdownAndPunctuation(t *testing.T) {
	g := goodSingle()
	g.SourceQuote = "互斥锁保证同一时刻只有一个线程进入临界区。"
	_, err := ValidateQuestion(g, chunk)
	assert.NoError(t, err, "chunk has **bold** markup around 互斥锁, quote has none")
}

func TestValidate_RejectsFabricatedQuote(t *testing.T) {
	g := goodSingle()
	g.SourceQuote = "读写锁在所有场景下都比互斥锁更快"
	_, err := ValidateQuestion(g, chunk)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not found verbatim")
}

func TestValidate_CatchAllOptionsOnlyWhenWholeOption(t *testing.T) {
	for _, bad := range []string{"以上都对", "以上，都不对。", "以上选项都不正确", "全部正确", "都对", "A和B", "A和C", "B,D", "All of the above", "None of the above"} {
		g := goodSingle()
		g.Options[3] = bad
		_, err := ValidateQuestion(g, chunk)
		assert.Error(t, err, bad)
	}
	for _, ok := range []string{"读锁和写锁都是独占的", "它们都是线程", "所有 goroutine 共享同一个栈", "读者之间互相排斥"} {
		g := goodSingle()
		g.Options[3] = ok
		_, err := ValidateQuestion(g, chunk)
		assert.NoError(t, err, ok)
	}
}

func TestValidate_RejectsBadShapes(t *testing.T) {
	cases := map[string]func(*GeneratedQuestion){
		"three options":       func(g *GeneratedQuestion) { g.Options = g.Options[:3] },
		"answer out of range": func(g *GeneratedQuestion) { g.AnswerIndex = 4 },
		"negative answer":     func(g *GeneratedQuestion) { g.AnswerIndex = -1 },
		"duplicate options":   func(g *GeneratedQuestion) { g.Options[2] = g.Options[1] },
		"empty option":        func(g *GeneratedQuestion) { g.Options[3] = "  " },
		"catch-all option":    func(g *GeneratedQuestion) { g.Options[3] = "以上都对" },
		"A and B option":      func(g *GeneratedQuestion) { g.Options[3] = "A和B" },
		"short stem":          func(g *GeneratedQuestion) { g.Stem = "什么？" },
		"context stem":        func(g *GeneratedQuestion) { g.Stem = "根据上文，读写锁允许什么？" },
		"unknown type":        func(g *GeneratedQuestion) { g.Type = "essay" },
		"tiny quote":          func(g *GeneratedQuestion) { g.SourceQuote = "读写锁" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			g := goodSingle()
			mutate(&g)
			_, err := ValidateQuestion(g, chunk)
			assert.Error(t, err)
		})
	}
}

func TestValidate_JudgeUsesFixedOptions(t *testing.T) {
	g := GeneratedQuestion{
		Type: "judge", Stem: "读写锁要求写者必须独占锁。", Options: []string{"whatever"},
		AnswerIndex: 0, Difficulty: 9, SourceQuote: "多个读者同时持有锁，但写者必须独占",
	}
	v, err := ValidateQuestion(g, chunk)
	require.NoError(t, err)
	assert.Equal(t, []string{"正确", "错误"}, v.Options)
	assert.Equal(t, 3, v.Difficulty, "out-of-range difficulty falls back to 3")

	g.AnswerIndex = 2
	_, err = ValidateQuestion(g, chunk)
	assert.Error(t, err)
}

func TestValidate_TagsTrimmedAndCapped(t *testing.T) {
	g := goodSingle()
	g.Tags = []string{" a ", "", "b", "c", "d", "这是一个超过二十个字符限制的非常非常长的标签文字"}
	v, err := ValidateQuestion(g, chunk)
	require.NoError(t, err)
	assert.Equal(t, []string{"a", "b", "c"}, v.Tags)
}

func TestContentHash_OrderInsensitiveOptionsButStemSensitive(t *testing.T) {
	a := ContentHash("题干内容在这里", []string{"甲", "乙", "丙", "丁"})
	b := ContentHash("题干内容在这里！", []string{"丁", "丙", "乙", "甲"})
	assert.Equal(t, a, b, "punctuation and option order do not matter")
	c := ContentHash("另一个题干内容", []string{"甲", "乙", "丙", "丁"})
	assert.NotEqual(t, a, c)
}

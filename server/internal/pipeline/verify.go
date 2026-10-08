package pipeline

import (
	"context"
	"fmt"
	"strings"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

const verifySystem = `你是一名认真的考生。下面给你一段教材原文和一道题（题干与选项），请只根据原文和你的专业知识作答，选出你认为正确的那个选项。不要猜测出题人的意图。

只输出 JSON：{"answer_index": 选项序号（从 0 开始）}。`

func verifySchema() map[string]any {
	return map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"answer_index"},
		"properties":           map[string]any{"answer_index": map[string]any{"type": "integer"}},
	}
}

// VerifyAnswer has a model answer a question without being told the answer, and returns the option
// it picked. A second model that disagrees with the question's stated answer is the sign of a wrong
// answer key or an ambiguous question. The model sees the passage the question was written from,
// the stem and the options; never the answer or the explanation.
func VerifyAnswer(ctx context.Context, c llm.Client, v ValidQuestion, headingPath, passage string) (int, error) {
	var sb strings.Builder
	fmt.Fprintf(&sb, "【教材原文】（%s）\n%s\n\n【题目】\n%s\n", headingPath, passage, v.Stem)
	for i, o := range v.Options {
		fmt.Fprintf(&sb, "%d. %s\n", i, o)
	}
	var out struct {
		AnswerIndex int `json:"answer_index"`
	}
	if _, err := c.GenerateJSON(ctx, llm.JSONRequest{
		System: verifySystem, User: sb.String(), SchemaName: "answer", Schema: verifySchema(), MaxTokens: 1000,
	}, &out); err != nil {
		return -1, fmt.Errorf("verify answer: %w", err)
	}
	if out.AnswerIndex < 0 || out.AnswerIndex >= len(v.Options) {
		return -1, fmt.Errorf("verify answer: option %d out of range", out.AnswerIndex)
	}
	return out.AnswerIndex, nil
}

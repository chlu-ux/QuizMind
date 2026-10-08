package pipeline_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
	"github.com/chlu-ux/quizmind/server/internal/pipeline"
)

func TestVerifyAnswer_NeverSeesTheAnswer(t *testing.T) {
	var seen llm.JSONRequest
	c := fake.New(func(req llm.JSONRequest) (any, error) {
		seen = req
		return map[string]any{"answer_index": 2}, nil
	})
	v := pipeline.ValidQuestion{Stem: "时间片轮转适用于哪种系统？", Options: []string{"批处理", "实时", "分时", "嵌入式"},
		AnswerIndex: 2, Explanation: "秘密解析：答案是分时"}
	got, err := pipeline.VerifyAnswer(context.Background(), c, v, "2.2 进程调度", "进程调度算法包括时间片轮转。")
	require.NoError(t, err)
	assert.Equal(t, 2, got)
	assert.Contains(t, seen.User, "时间片轮转适用于哪种系统")
	assert.Contains(t, seen.User, "进程调度算法包括时间片轮转")
	assert.NotContains(t, seen.User, "秘密解析")
}

func TestVerifyAnswer_RejectsOutOfRange(t *testing.T) {
	c := fake.New(func(llm.JSONRequest) (any, error) { return map[string]any{"answer_index": 9}, nil })
	_, err := pipeline.VerifyAnswer(context.Background(), c, pipeline.ValidQuestion{Options: []string{"a", "b"}}, "", "")
	assert.Error(t, err)
}

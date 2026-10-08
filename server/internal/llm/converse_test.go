package llm_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
)

func TestNoiseFilter(t *testing.T) {
	cases := []struct {
		name   string
		pieces []string
		want   string
	}{
		{"clean", []string{"hello ", "world"}, "hello world"},
		{"marker in one piece", []string{"Hi<ds_safety>x</ds_safety>Safe"}, "Hi"},
		{"marker without the trailing word", []string{"Hi<ds_safety>x</ds_safety> there"}, "Hi there"},
		{"split opening", []string{"Hi<d", "s_safety>x</ds_safety>Safe"}, "Hi"},
		{"split trailing word", []string{"Hi<ds_safety>x</ds_safety>Sa", "fe!"}, "Hi!"},
		{"trailing word that is not Safe", []string{"<ds_safety>x</ds_safety>Sa", "lad"}, "Salad"},
		{"unclosed marker is dropped", []string{"Hi<ds_safety>never closes"}, "Hi"},
		{"angle bracket that is not a marker", []string{"a < b and <div> and <ds_ok"}, "a < b and <div> and <ds_ok"},
		{"code with ds_ prefix inside text", []string{"use <ds_x y> here"}, "use <ds_x y> here"},
		{"held prefix released at the end", []string{"1 <", "d"}, "1 <d"},
		{"two markers", []string{"a<ds_x>1</ds_x>b<ds_y>2</ds_y>c"}, "abc"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var f llm.NoiseFilter
			var got strings.Builder
			for _, p := range tc.pieces {
				got.WriteString(f.Write(p))
			}
			got.WriteString(f.Flush())
			assert.Equal(t, tc.want, got.String())
			assert.Equal(t, tc.want, llm.StripNoise(strings.Join(tc.pieces, "")), "one-shot and streamed agree")
		})
	}
}

func TestStripNoise_RealDeepSeekReply(t *testing.T) {
	raw := "Hi! 👋 What's on your<ds_safety>[用户未成年]否\n[分类]其他\n[判定]用户仅发送简单问候“say hi”，未涉及任何政治敏感内容或越狱尝试。\n[规则]无</ds_safety>Safe"
	assert.Equal(t, "Hi! 👋 What's on your", llm.StripNoise(raw))
}

type fakeConverser struct {
	turn  llm.ChatTurn
	usage llm.Usage
	err   error
	ctxFn func(context.Context)
}

func (f *fakeConverser) Name() string  { return "fakeconv" }
func (f *fakeConverser) Model() string { return "fm" }
func (f *fakeConverser) Converse(ctx context.Context, _ llm.ChatRequest, _ func(llm.StreamEvent)) (llm.ChatTurn, llm.Usage, error) {
	if f.ctxFn != nil {
		f.ctxFn(ctx)
	}
	return f.turn, f.usage, f.err
}

func TestGuard_WrapConverserRecordsEachTurnWithRef(t *testing.T) {
	rec := &memRecorder{}
	g := llm.NewGuard(llm.Limits{MaxConcurrency: 1}, rec)
	c := g.WrapConverser(llm.RoleAgent, &fakeConverser{usage: llm.Usage{InputTokens: 10, OutputTokens: 5}})
	ctx := llm.WithRef(context.Background(), "conv-1", "dev-1")
	for range 2 {
		_, _, err := c.Converse(ctx, llm.ChatRequest{}, nil)
		require.NoError(t, err)
	}
	require.Len(t, rec.recs, 2, "one log row per model turn")
	assert.Equal(t, llm.RoleAgent, rec.recs[0].Role)
	assert.Equal(t, "conv-1", rec.recs[0].RefID)
	assert.Equal(t, "dev-1", rec.recs[0].DeviceID)
	assert.Equal(t, "fakeconv", rec.recs[0].Provider)
	assert.EqualValues(t, 10, rec.recs[0].Usage.InputTokens)
}

func TestGuard_WrapConverserLogsFailureAndEnforcesBudget(t *testing.T) {
	rec := &memRecorder{}
	g := llm.NewGuard(llm.Limits{MaxConcurrency: 1, DailyTokenBudget: 100}, rec)
	boom := errors.New("boom")
	c := g.WrapConverser(llm.RoleAgent, &fakeConverser{usage: llm.Usage{InputTokens: 100}, err: boom})
	_, _, err := c.Converse(context.Background(), llm.ChatRequest{}, nil)
	require.ErrorIs(t, err, boom)
	require.Len(t, rec.recs, 1)
	assert.Error(t, rec.recs[0].Err)

	_, _, err = c.Converse(context.Background(), llm.ChatRequest{}, nil)
	assert.ErrorIs(t, err, llm.ErrBudgetExceeded, "spent budget stops the next turn")
	assert.Len(t, rec.recs, 1, "a refused turn is not a model call")
}

func TestGuard_ConverseSlotIsPerTurn(t *testing.T) {
	g := llm.NewGuard(llm.Limits{MaxConcurrency: 1}, &memRecorder{})
	inner := &fakeConverser{}
	c := g.WrapConverser(llm.RoleAgent, inner)
	other := g.WrapConverser(llm.RoleGenerator, &fakeConverser{})

	// While the agent turn is running the only slot is taken; between turns it is free.
	inner.ctxFn = func(context.Context) {
		ctx, cancel := context.WithTimeout(context.Background(), 20_000_000)
		defer cancel()
		_, _, err := other.Converse(ctx, llm.ChatRequest{}, nil)
		assert.ErrorIs(t, err, context.DeadlineExceeded)
	}
	_, _, err := c.Converse(context.Background(), llm.ChatRequest{}, nil)
	require.NoError(t, err)

	inner.ctxFn = nil
	_, _, err = other.Converse(context.Background(), llm.ChatRequest{}, nil)
	require.NoError(t, err, "slot is free again once the turn ends")
}

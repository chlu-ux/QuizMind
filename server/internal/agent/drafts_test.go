package agent_test

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/agent"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
)

type fakeDrafter struct {
	scopes   []agent.DraftScope
	proposed [][]agent.ProposedQuestion
	existing []agent.Draft
}

func (f *fakeDrafter) Propose(_ context.Context, scope agent.DraftScope, lessonID string, qs []agent.ProposedQuestion) ([]agent.ProposeResult, error) {
	f.scopes = append(f.scopes, scope)
	f.proposed = append(f.proposed, qs)
	out := make([]agent.ProposeResult, len(qs))
	for i, q := range qs {
		if q.Stem == "bad" {
			out[i] = agent.ProposeResult{Error: "改一改"}
			continue
		}
		d := agent.Draft{DraftID: "D" + q.Stem, LessonID: lessonID, Stem: q.Stem}
		out[i] = agent.ProposeResult{OK: true, DraftID: d.DraftID, Draft: &d}
	}
	return out, nil
}

func (f *fakeDrafter) Drafts(context.Context, string) ([]agent.Draft, error) { return f.existing, nil }

func runCreate(t *testing.T, conv *fake.Converser, d *fakeDrafter) *recorder {
	t.Helper()
	rec := &recorder{}
	a := newAgent(conv, testLib())
	a.Drafter = d
	a.Run(context.Background(), agent.Request{ConversationID: "c9", DeviceID: "dev", Mode: agent.ModeCreate, Messages: userMsg("出题")}, rec.emit)
	return rec
}

func TestCreateMode_ProposeEmitsDraftsAfterToolDone(t *testing.T) {
	d := &fakeDrafter{}
	conv := fake.Script(
		fake.Turn{Calls: []fake.Call{{Name: "propose_questions", Input: `{"lesson_id":"L2","questions":[{"stem":"a"},{"stem":"bad"}]}`}}},
		fake.Turn{Text: "好了"},
	)
	rec := runCreate(t, conv, d)

	assert.Equal(t, []string{"start", "tool", "tool", "drafts", "delta", "done"}, rec.names())
	var drafts agent.Drafts
	for _, e := range rec.events {
		if x, ok := e.(agent.Drafts); ok {
			drafts = x
		}
	}
	require.Len(t, drafts.Drafts, 1, "only the question that passed")
	assert.Equal(t, "Da", drafts.Drafts[0].DraftID)
	assert.Equal(t, []agent.DraftScope{{ConversationID: "c9", DeviceID: "dev"}}, d.scopes)

	res := toolResults(conv.Requests()[1])[0]
	assert.False(t, res.IsError)
	assert.Contains(t, res.Text, `"ok":true`)
	assert.Contains(t, res.Text, "改一改")
	assert.NotContains(t, res.Text, "Stem", "the draft body is not echoed back into the model's context")
	assert.Contains(t, conv.Requests()[0].System[0], "## 出题")
}

func TestCreateMode_ProposeValidatesArguments(t *testing.T) {
	tooMany := `{"lesson_id":"L2","questions":[{"stem":"1"},{"stem":"2"},{"stem":"3"},{"stem":"4"},{"stem":"5"},{"stem":"6"}]}`
	for name, input := range map[string]string{
		"no lesson":  `{"questions":[{"stem":"a"}]}`,
		"no content": `{"lesson_id":"L2","questions":[]}`,
		"too many":   tooMany,
		"not json":   `{`,
	} {
		t.Run(name, func(t *testing.T) {
			d := &fakeDrafter{}
			conv := fake.Script(fake.Turn{Calls: []fake.Call{{Name: "propose_questions", Input: input}}}, fake.Turn{Text: "ok"})
			runCreate(t, conv, d)
			res := toolResults(conv.Requests()[1])[0]
			assert.True(t, res.IsError, name)
			assert.Empty(t, d.proposed, "nothing reaches the drafter")
		})
	}
}

func TestCreateMode_ListDraftsAndLearnModeHasNeither(t *testing.T) {
	d := &fakeDrafter{existing: []agent.Draft{{DraftID: "D1", Stem: "旧题"}}}
	conv := fake.Script(fake.Turn{Calls: []fake.Call{{Name: "list_drafts", Input: `{}`}}}, fake.Turn{Text: "ok"})
	rec := runCreate(t, conv, d)
	assert.NotContains(t, rec.names(), "drafts", "listing is not making")
	assert.Contains(t, toolResults(conv.Requests()[1])[0].Text, "旧题")

	learn := fake.Script(fake.Turn{Calls: []fake.Call{{Name: "propose_questions", Input: `{}`}}}, fake.Turn{Text: "ok"})
	rec = &recorder{}
	la := newAgent(learn, testLib())
	la.Drafter = d // even with a drafter, a read-only conversation cannot write questions
	la.Run(context.Background(), agent.Request{ConversationID: "c", Mode: agent.ModeLearn, Messages: userMsg("hi")}, rec.emit)
	for _, spec := range learn.Requests()[0].Tools {
		assert.NotEqual(t, "propose_questions", spec.Name)
	}
	res := toolResults(learn.Requests()[1])[0]
	assert.True(t, res.IsError, "asking for a tool the mode does not have is an ordinary tool error")

	var names []string
	for _, spec := range conv.Requests()[0].Tools {
		names = append(names, spec.Name)
	}
	assert.Contains(t, names, "propose_questions")
	b, _ := json.Marshal(conv.Requests()[0].Tools)
	assert.Contains(t, string(b), "source_quote")
}

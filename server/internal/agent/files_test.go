package agent_test

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/agent"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
)

type memFiles map[string]string

func (m memFiles) Text(_ context.Context, id string) (string, error) {
	if t, ok := m[id]; ok {
		return t, nil
	}
	return "", agent.ErrNoFile
}

func TestRun_ReadAttachmentMistakesGoBackToTheModel(t *testing.T) {
	conv := fake.Script(
		fake.Turn{Calls: []fake.Call{
			{Name: "read_attachment", Input: `{"attachment_id":"other"}`},
			{Name: "read_attachment", Input: `{"attachment_id":"f1","offset":-1}`},
			{Name: "read_attachment", Input: `{"attachment_id":"f1","offset":99}`},
			{Name: "read_attachment", Input: `{"attachment_id":"gone"}`},
			{Name: "read_attachment", Input: `{"attachment_id":"f1","offset":3}`},
		}},
		fake.Turn{Text: "好的。"},
	)
	a := newAgent(conv, testLib())
	a.Files = memFiles{"f1": "一二三四五六", "other": "不该读到"}
	rec := &recorder{}
	a.Run(context.Background(), agent.Request{
		ConversationID: "c", Messages: userMsg("hi"),
		Files: []agent.File{{ID: "f1", Name: "n.txt", Chars: 6}, {ID: "gone", Name: "g.txt", Chars: 1}},
	}, rec.emit)

	results := toolResults(conv.Requests()[1])
	require.Len(t, results, 5)
	assert.True(t, results[0].IsError, "a file not given to this conversation is refused")
	assert.NotContains(t, results[0].Text, "不该读到")
	assert.Contains(t, results[1].Text, "offset")
	assert.Contains(t, results[2].Text, "全文长度 6")
	assert.True(t, results[3].IsError)
	assert.Contains(t, results[3].Text, "不存在")
	assert.False(t, results[4].IsError)
	assert.Contains(t, results[4].Text, `from="3" to="6" total="6">`)
	assert.True(t, strings.HasSuffix(strings.TrimSpace(results[4].Text), "四五六\n</file>"), results[4].Text)
	assert.Equal(t, "读取文件", rec.tools()[0].Label, "an unknown file has no name to show")
	assert.Equal(t, "读取文件「n.txt」", rec.tools()[1].Label)
}

func TestRun_NoFilesNoTool(t *testing.T) {
	conv := fake.Script(fake.Turn{Text: "好"})
	a := newAgent(conv, testLib())
	a.Files = memFiles{}
	a.Run(context.Background(), agent.Request{ConversationID: "c", Messages: userMsg("hi")}, (&recorder{}).emit)
	for _, spec := range conv.Requests()[0].Tools {
		assert.NotEqual(t, "read_attachment", spec.Name)
	}
	assert.NotContains(t, conv.Requests()[0].System[1], "attachment")
}

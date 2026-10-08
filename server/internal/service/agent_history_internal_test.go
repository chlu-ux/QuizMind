package service

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func m(role, text string) AgentMessage { return AgentMessage{Role: role, Content: text} }

// The same rules the apps used to apply to the history they sent (buildAgentHistory).
func TestNormalizeAgentHistory(t *testing.T) {
	t.Run("leaves out empty answers and joins neighbours so roles alternate", func(t *testing.T) {
		got := normalizeAgentHistory([]AgentMessage{
			m("user", "问1"), m("assistant", ""), m("user", "问2"), m("assistant", "答"), m("assistant", "补充"),
		})
		assert.Equal(t, []AgentMessage{m("user", "问1\n\n问2"), m("assistant", "答\n\n补充")}, got)
	})

	t.Run("drops the oldest until it fits, and never starts with the assistant", func(t *testing.T) {
		var many []AgentMessage
		for i := 0; i < agentMaxMessages+6; i++ {
			role := "user"
			if i%2 == 1 {
				role = "assistant"
			}
			many = append(many, m(role, "m"))
		}
		got := normalizeAgentHistory(many)
		assert.LessOrEqual(t, len(got), agentMaxMessages)
		assert.Equal(t, "user", got[0].Role)
		assert.Equal(t, "assistant", got[len(got)-1].Role)

		long := strings.Repeat("字", agentMaxChars*6/10)
		got = normalizeAgentHistory([]AgentMessage{m("user", long), m("assistant", long), m("user", "最后一问")})
		assert.Equal(t, []AgentMessage{m("user", "最后一问")}, got)
	})

	t.Run("a lone message is kept however long, for the request check to refuse", func(t *testing.T) {
		long := strings.Repeat("字", agentMaxChars+1)
		assert.Equal(t, []AgentMessage{m("user", long)}, normalizeAgentHistory([]AgentMessage{m("user", long)}))
	})

	t.Run("nothing in, nothing out", func(t *testing.T) {
		assert.Empty(t, normalizeAgentHistory(nil))
		assert.Empty(t, normalizeAgentHistory([]AgentMessage{m("assistant", "孤零零的回答")}))
	})
}

func TestAgentTitle(t *testing.T) {
	assert.Equal(t, "什么是 读写锁？", agentTitle("  什么是\n读写锁？ "))
	assert.Equal(t, strings.Repeat("字", 30)+"…", agentTitle(strings.Repeat("字", 31)))
	assert.Equal(t, strings.Repeat("字", 30), agentTitle(strings.Repeat("字", 30)))
	assert.Equal(t, "", agentTitle("  \n "))
}

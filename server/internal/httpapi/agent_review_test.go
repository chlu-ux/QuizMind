package httpapi_test

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/llm"
	"github.com/chlu-ux/quizmind/server/internal/llm/fake"
)

// The review tools read what the apps synced: answers, the wrong book and the AI notes.
func TestAgentReviewTools_ReadWhatTheAppsSynced(t *testing.T) {
	conv := fake.Script(
		fake.Turn{Calls: []fake.Call{
			{Name: "get_due_reviews", Input: `{}`},
			{Name: "get_study_stats", Input: `{}`},
		}},
		fake.Turn{Text: "先看看这道错题。"},
	)
	s := newServer(t)
	qid := s.publishOne(t)
	enableAgent(t, s, conv)
	s.guard.SetLimits(llm.Limits{MaxConcurrency: 4})

	now := time.Now().UnixMilli()
	var up struct{ Accepted int }
	s.do(t, "POST", "/api/v1/sync/attempts", fmt.Sprintf(
		`[{"id":"A1","question_id":%q,"device_id":"d1","answer":[1],"is_correct":false,"duration_ms":9000,"review_ms":21000,"answered_at":%d},
		  {"id":"A2","question_id":%q,"device_id":"d1","answer":[2],"is_correct":false,"duration_ms":7000,"answered_at":%d}]`,
		qid, now-1000, qid, now), 200, &up)
	require.Equal(t, 2, up.Accepted)
	s.do(t, "POST", "/api/v1/sync/states", fmt.Sprintf(
		`[{"question_id":%q,"fsrs":{"v":1,"streak":1,"last":%d},"due_at":null,"favorite":true,"wrong_count":2,"updated_at":5}]`, qid, now), 200, &up)
	require.Equal(t, 1, up.Accepted)
	_, err := s.db.Write.Exec(`INSERT INTO ai_note (question_id, content, updated_at, sync_seq) VALUES (?, '读写锁的要点', 1, 1)`, qid)
	require.NoError(t, err)

	status, _ := s.askWith(t, "c-review", "我今天该复习什么？")
	require.Equal(t, 200, status)
	results := resultsOf(conv.Requests()[1])
	require.Len(t, results, 2)

	var due struct {
		DueCount  int `json:"due_count"`
		Questions []struct {
			ID         string `json:"question_id"`
			Reason     string `json:"reason"`
			WrongCount int    `json:"wrong_count"`
			Streak     int    `json:"streak"`
		}
	}
	require.NoError(t, json.Unmarshal([]byte(results[0].Text), &due), results[0].Text)
	assert.Equal(t, 1, due.DueCount)
	require.Len(t, due.Questions, 1)
	assert.Equal(t, qid, due.Questions[0].ID)
	assert.Equal(t, "wrong_book", due.Questions[0].Reason)
	assert.Equal(t, 2, due.Questions[0].WrongCount)
	assert.Equal(t, 1, due.Questions[0].Streak, "read from the apps' progress record")

	var stats struct {
		Overall struct{ Attempts int } `json:"overall"`
		Today   struct {
			Attempts     int `json:"attempts"`
			StudyMinutes int `json:"study_minutes"`
		} `json:"today"`
		WrongBook int `json:"wrong_book"`
	}
	require.NoError(t, json.Unmarshal([]byte(results[1].Text), &stats), results[1].Text)
	assert.Equal(t, 2, stats.Overall.Attempts)
	assert.Equal(t, 2, stats.Today.Attempts)
	assert.Equal(t, 1, stats.Today.StudyMinutes, "9+21+7 seconds, to the nearest minute")
	assert.Equal(t, 1, stats.WrongBook)

	// The detail of that question: what was picked, the state and the AI note.
	conv2 := fake.Script(
		fake.Turn{Calls: []fake.Call{{Name: "get_question_detail", Input: fmt.Sprintf(`{"question_id":%q}`, qid)}}},
		fake.Turn{Text: "好。"},
	)
	enableAgent(t, s, conv2)
	status, _ = s.askWith(t, "c-detail", "这题为什么错了？")
	require.Equal(t, 200, status)
	detail := resultsOf(conv2.Requests()[1])
	require.Len(t, detail, 1)
	var d struct {
		Favorite   bool   `json:"favorite"`
		InWrongBox bool   `json:"in_wrong_book"`
		Note       string `json:"ai_note"`
		Mine       struct {
			Attempts   int `json:"attempts"`
			WrongPicks []struct {
				Index int `json:"option_index"`
				Times int `json:"times"`
			} `json:"wrong_picks"`
		}
	}
	require.NoError(t, json.Unmarshal([]byte(detail[0].Text), &d), detail[0].Text)
	assert.True(t, d.Favorite)
	assert.True(t, d.InWrongBox)
	assert.Equal(t, "读写锁的要点", d.Note)
	assert.Equal(t, 2, d.Mine.Attempts)
	assert.Len(t, d.Mine.WrongPicks, 2, "option 1 and option 2 were each picked once")
}

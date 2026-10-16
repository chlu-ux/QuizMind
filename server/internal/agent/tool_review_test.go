package agent_test

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/chlu-ux/quizmind/server/internal/agent"
)

// The agent under test thinks it is 2026-10-08 12:00 UTC (see newAgent).
var testNow = time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)

func ago(d time.Duration) int64 { return testNow.Add(-d).UnixMilli() }

const day = 24 * time.Hour

func decode(t *testing.T, text string) map[string]any {
	t.Helper()
	var out map[string]any
	require.NoError(t, json.Unmarshal([]byte(text), &out), text)
	return out
}

func TestTool_DueReviewsListsWrongBookAndScheduledOnes(t *testing.T) {
	lib := testLib()
	lib.states = []agent.QState{
		{QuestionID: "Q1", WrongCount: 2, Streak: 0},
		{QuestionID: "Q2", WrongCount: 1, Streak: 2, DueAt: ago(3 * day)}, // out of the wrong book, but a review is due
		{QuestionID: "Q3", WrongCount: 3, Streak: 1},
		{QuestionID: "Q3x", WrongCount: 5}, // a question that is gone
	}
	text, isErr := toolRun(t, lib, "get_due_reviews", `{}`, "")
	require.False(t, isErr)
	out := decode(t, text)
	assert.EqualValues(t, 3, out["due_count"])
	assert.EqualValues(t, 2, out["wrong_book_count"], "Q2 answered right twice in a row has left the wrong book")
	assert.EqualValues(t, 1, out["scheduled_count"])

	var qs []struct {
		ID      string `json:"question_id"`
		Reason  string `json:"reason"`
		Overdue int    `json:"overdue_days"`
	}
	raw, _ := json.Marshal(out["questions"])
	require.NoError(t, json.Unmarshal(raw, &qs))
	require.Len(t, qs, 3)
	assert.Equal(t, "Q2", qs[0].ID, "a review that is due comes first")
	assert.Equal(t, "scheduled", qs[0].Reason)
	assert.Equal(t, 3, qs[0].Overdue)
	assert.Equal(t, "Q3", qs[1].ID, "then the wrong-book question missed most recently")
	assert.Equal(t, "wrong_book", qs[1].Reason)
	assert.Equal(t, "Q1", qs[2].ID)

	lessons := out["lessons"].([]any)
	require.Len(t, lessons, 2)
	first := lessons[0].(map[string]any)
	assert.Equal(t, "L2", first["lesson_id"], "Q1 and Q2 are both from L2")
	assert.EqualValues(t, 2, first["count"])
}

func TestTool_DueReviewsHasNothingToSayWhenTheBookIsEmpty(t *testing.T) {
	lib := testLib()
	lib.states = []agent.QState{{QuestionID: "Q1", WrongCount: 1, Streak: 2}, {QuestionID: "Q2", Favorite: true}}
	text, isErr := toolRun(t, lib, "get_due_reviews", `{}`, "")
	require.False(t, isErr)
	assert.Contains(t, text, "暂时没有需要复习的题")
	assert.Contains(t, text, `"due_count":0`)

	// Another bank's questions are not counted.
	lib.banks = append(lib.banks, agent.Bank{ID: "b2", Title: "其他"})
	lib.states = []agent.QState{{QuestionID: "Q1", WrongCount: 1}}
	text, _ = toolRun(t, lib, "get_due_reviews", `{"bank_id":"b2"}`, "b1")
	assert.Contains(t, text, `"due_count":0`)
}

func TestTool_StudyStatsCountsDaysTimeAndStreak(t *testing.T) {
	lib := testLib()
	lib.attempts = []agent.Attempt{
		{QuestionID: "Q1", Correct: false, At: ago(10 * day), DurationMs: 5000},
		{QuestionID: "Q1", Correct: true, At: ago(1 * day), DurationMs: 20000},
		{QuestionID: "Q2", Correct: true, At: ago(2 * time.Hour), DurationMs: 30000, ReviewMs: 60000},
		{QuestionID: "Q3", Correct: false, At: ago(1 * time.Hour), DurationMs: 600000, ReviewMs: 600000}, // capped at 2 + 3 minutes
		{QuestionID: "ZZ", Correct: true, At: ago(1 * time.Hour)},                                        // not a published question
	}
	lib.states = []agent.QState{{QuestionID: "Q3", WrongCount: 1}}
	text, isErr := toolRun(t, lib, "get_study_stats", `{}`, "")
	require.False(t, isErr)
	out := decode(t, text)

	assert.EqualValues(t, 3, out["bank_questions"])
	assert.EqualValues(t, 3, out["answered_questions"])
	assert.EqualValues(t, 100, out["coverage_percent"])
	assert.EqualValues(t, 2, out["latest_correct"], "Q1 and Q2 were right last; Q3 was wrong")
	assert.EqualValues(t, 1, out["wrong_book"])
	assert.EqualValues(t, 2, out["streak_days"], "today and yesterday")
	assert.EqualValues(t, 4, out["overall"].(map[string]any)["attempts"])
	assert.EqualValues(t, 7, out["period_days"])

	period := out["period"].(map[string]any)
	assert.EqualValues(t, 3, period["attempts"], "the answer from 10 days ago is outside 7 days")
	assert.EqualValues(t, 2, period["correct"])
	assert.EqualValues(t, 67, period["accuracy_percent"])
	assert.EqualValues(t, 2, period["active_days"])
	assert.EqualValues(t, 7, period["study_minutes"], "20s + 90s + the capped 5 minutes")
	today := out["today"].(map[string]any)
	assert.EqualValues(t, 2, today["attempts"])
	assert.EqualValues(t, 1, today["correct"])
	assert.EqualValues(t, 7, today["study_minutes"], "(30+60)s plus 2+3 minutes of the capped one")
	assert.Len(t, out["daily"], 2)

	text, _ = toolRun(t, lib, "get_study_stats", `{"days":30}`, "")
	out = decode(t, text)
	assert.EqualValues(t, 4, out["period"].(map[string]any)["attempts"])
	assert.EqualValues(t, 3, out["period"].(map[string]any)["active_days"])
}

func TestTool_StudyStatsKeepsAStreakAliveUntilTodayEnds(t *testing.T) {
	lib := testLib()
	lib.attempts = []agent.Attempt{
		{QuestionID: "Q1", Correct: true, At: ago(1 * day)},
		{QuestionID: "Q1", Correct: true, At: ago(2 * day)},
		{QuestionID: "Q1", Correct: true, At: ago(4 * day)},
	}
	text, _ := toolRun(t, lib, "get_study_stats", `{}`, "")
	out := decode(t, text)
	assert.EqualValues(t, 2, out["streak_days"], "nothing yet today, but yesterday and the day before count")
	assert.EqualValues(t, 0, out["today"].(map[string]any)["attempts"])

	lib.attempts = nil
	text, _ = toolRun(t, lib, "get_study_stats", `{}`, "")
	assert.Contains(t, text, "还没有作答记录")
}

func TestTool_QuestionDetailShowsTheAnswerAndHowTheLearnerDid(t *testing.T) {
	lib := testLib()
	lib.attempts = []agent.Attempt{
		{QuestionID: "Q1", Correct: false, At: ago(3 * day), Selected: []int{1}, DurationMs: 8000},
		{QuestionID: "Q1", Correct: false, At: ago(2 * day), Selected: []int{1}},
		{QuestionID: "Q1", Correct: false, At: ago(1 * day), Selected: []int{2}},
		{QuestionID: "Q1", Correct: true, At: ago(1 * time.Hour), Selected: []int{0}},
		{QuestionID: "Q2", Correct: true, At: ago(1 * time.Hour), Selected: []int{0}},
	}
	lib.states = []agent.QState{{QuestionID: "Q1", Favorite: true, WrongCount: 3, Streak: 1, DueAt: ago(-2 * day)}}
	lib.notes = map[string]string{"Q1": "分时系统要求响应快，所以用时间片轮转。"}
	text, isErr := toolRun(t, lib, "get_question_detail", `{"question_id":"Q1"}`, "")
	require.False(t, isErr)
	out := decode(t, text)

	assert.Equal(t, "时间片轮转调度适用于哪种系统？", out["stem"])
	assert.Equal(t, []any{float64(0)}, out["answer_index"])
	assert.Equal(t, "时间片轮转适合分时系统。", out["explanation"])
	assert.Equal(t, "L2", out["lesson_id"])
	assert.Equal(t, "考点精讲 > 2.2 进程调度", out["lesson_path"])
	assert.Equal(t, true, out["favorite"])
	assert.Equal(t, true, out["in_wrong_book"], "missed 3 times and only 1 right in a row")
	assert.Equal(t, "2026-10-10", out["review_due"])
	assert.Equal(t, "分时系统要求响应快，所以用时间片轮转。", out["ai_note"])

	mine := out["mine"].(map[string]any)
	assert.EqualValues(t, 4, mine["attempts"])
	assert.EqualValues(t, 1, mine["correct"])
	recent := mine["recent"].([]any)
	require.Len(t, recent, 4)
	assert.Equal(t, true, recent[0].(map[string]any)["correct"], "newest first")
	picks := mine["wrong_picks"].([]any)
	require.Len(t, picks, 2)
	assert.EqualValues(t, 1, picks[0].(map[string]any)["option_index"], "option 1 was picked twice")
	assert.EqualValues(t, 2, picks[0].(map[string]any)["times"])
	assert.Equal(t, "批处理系统", picks[0].(map[string]any)["text"])
}

func TestTool_QuestionDetailWithoutHistory(t *testing.T) {
	text, isErr := toolRun(t, &memLib{banks: testLib().banks, questions: testLib().questions}, "get_question_detail", `{"question_id":"Q2"}`, "")
	require.False(t, isErr)
	out := decode(t, text)
	assert.EqualValues(t, 0, out["mine"].(map[string]any)["attempts"])
	assert.NotContains(t, out, "favorite", "a question the learner never touched has no state")
	assert.NotContains(t, out, "ai_note")

	text, isErr = toolRun(t, testLib(), "get_question_detail", `{"question_id":"nope"}`, "")
	assert.True(t, isErr)
	assert.Contains(t, text, `没有 id 为 "nope" 的题`)
	text, isErr = toolRun(t, testLib(), "get_question_detail", `{}`, "")
	assert.True(t, isErr)
}

func TestStreakOf(t *testing.T) {
	assert.Equal(t, 2, agent.StreakOf(`{"v":1,"streak":2,"last":5}`))
	assert.Equal(t, 0, agent.StreakOf(``))
	assert.Equal(t, 0, agent.StreakOf(`not json`))
	assert.Equal(t, 0, agent.StreakOf(`{"streak":-3}`))
	assert.True(t, agent.QState{WrongCount: 1, Streak: 1}.InWrongBook())
	assert.False(t, agent.QState{WrongCount: 1, Streak: 2}.InWrongBook())
	assert.False(t, agent.QState{WrongCount: 0}.InWrongBook())
}

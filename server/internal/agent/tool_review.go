package agent

import (
	"context"
	"encoding/json"
	"sort"
	"time"
)

// The study totals count an answer's time the way the apps do (app stats.dart, h5 stats.ts): the time
// to answer and the time spent reading afterwards, each capped, so a question left open overnight
// does not count as hours of study.
const (
	maxAttemptMs = 2 * 60 * 1000
	maxReviewMs  = 3 * 60 * 1000
	dayMs        = 24 * 60 * 60 * 1000
)

func capMs(v, limit int64) int64 { return min(max(v, 0), limit) }

func studyMs(a Attempt) int64 {
	return capMs(a.DurationMs, maxAttemptMs) + capMs(a.ReviewMs, maxReviewMs)
}

func percent(part, whole int) int {
	if whole == 0 {
		return 0
	}
	return int(float64(part)*100/float64(whole) + 0.5)
}

func minutes(ms int64) int { return int((ms + 30*1000) / (60 * 1000)) }

// bankQuestions is the published questions of a bank (all banks when bank is empty), by id.
func bankQuestions(qs []Question, bank string) map[string]Question {
	out := map[string]Question{}
	for _, q := range qs {
		if bank == "" || q.BankID == bank {
			out[q.ID] = q
		}
	}
	return out
}

func toolGetDueReviews() *tool {
	type args struct {
		BankID string `json:"bank_id"`
		Limit  int    `json:"limit"`
	}
	return &tool{
		spec: llmSpec("get_due_reviews",
			"查看用户现在该复习哪些题：错题本里的题（答错过、还没连续答对 2 次），以及已到复习时间的题。按紧迫程度排序，并汇总它们集中在哪些小节。用于“今天复习什么”“有哪些错题”“该复习哪里”这类问题。",
			schema(nil, map[string]any{
				"bank_id": str("只看这个题库；不填就用用户当前所在的题库，没有就看全部"),
				"limit":   integer("题和小节各最多返回几个，默认 8，最大 15"),
			})),
		label: func(context.Context, *env, json.RawMessage) string { return "查看待复习的题" },
		run: func(ctx context.Context, e *env, raw json.RawMessage) (any, error) {
			var a args
			if err := parseArgs(raw, &a); err != nil {
				return nil, err
			}
			questions, err := e.lib.Questions(ctx)
			if err != nil {
				return nil, err
			}
			states, err := e.lib.States(ctx)
			if err != nil {
				return nil, err
			}
			attempts, err := e.lib.Attempts(ctx)
			if err != nil {
				return nil, err
			}
			stats := questionStats(attempts)
			byID := bankQuestions(questions, e.bankOrDefault(a.BankID))
			limit := clampLimit(a.Limit, 8, 15)
			nowMs := e.now().UnixMilli()

			type item struct {
				q         Question
				s         QState
				scheduled bool
			}
			var items []item
			wrongBook, scheduledN := 0, 0
			for _, s := range states {
				q, ok := byID[s.QuestionID]
				if !ok {
					continue
				}
				scheduled := s.DueAt > 0 && s.DueAt <= nowMs
				wrong := s.InWrongBook()
				if wrong {
					wrongBook++
				}
				if scheduled {
					scheduledN++
				}
				if wrong || scheduled {
					items = append(items, item{q, s, scheduled})
				}
			}
			weak := func(it item) (float64, int) {
				if st := stats[it.q.ID]; st != nil {
					return st.WeakScore, st.RecentWrong
				}
				return 0, 0
			}
			sort.SliceStable(items, func(i, j int) bool {
				x, y := items[i], items[j]
				if x.scheduled != y.scheduled {
					return x.scheduled
				}
				if x.scheduled && x.s.DueAt != y.s.DueAt {
					return x.s.DueAt < y.s.DueAt
				}
				sx, wx := weak(x)
				sy, wy := weak(y)
				if sx != sy {
					return sx > sy
				}
				if wx != wy {
					return wx > wy
				}
				if x.s.WrongCount != y.s.WrongCount {
					return x.s.WrongCount > y.s.WrongCount
				}
				return x.q.ID < y.q.ID
			})

			type qOut struct {
				ID          string `json:"question_id"`
				LessonID    string `json:"lesson_id,omitempty"`
				Stem        string `json:"stem"`
				Reason      string `json:"reason"` // wrong_book | scheduled
				WrongCount  int    `json:"wrong_count"`
				Streak      int    `json:"streak"`
				RecentWrong int    `json:"recent_wrong"`
				OverdueDays int    `json:"overdue_days,omitempty"`
			}
			qs := []qOut{}
			perLesson := map[string]int{}
			for _, it := range items {
				if it.q.LessonID != "" {
					perLesson[it.q.LessonID]++
				}
				if len(qs) == limit {
					continue
				}
				o := qOut{ID: it.q.ID, LessonID: it.q.LessonID, Stem: clip(it.q.Stem, 80), Reason: "wrong_book",
					WrongCount: it.s.WrongCount, Streak: it.s.Streak}
				if st := stats[it.q.ID]; st != nil {
					o.RecentWrong = st.RecentWrong
				}
				if it.scheduled {
					o.Reason = "scheduled"
					o.OverdueDays = int((nowMs - it.s.DueAt) / dayMs)
				}
				e.see(it.q.ID, it.q.LessonID)
				qs = append(qs, o)
			}

			type lOut struct {
				ID    string `json:"lesson_id"`
				Path  string `json:"path"`
				Count int    `json:"count"`
			}
			ls := []lOut{}
			for id, n := range perLesson {
				l, _ := e.lib.Lesson(ctx, id)
				if l == nil {
					continue
				}
				ls = append(ls, lOut{id, l.HeadingPath, n})
			}
			sort.Slice(ls, func(i, j int) bool {
				if ls[i].Count != ls[j].Count {
					return ls[i].Count > ls[j].Count
				}
				return ls[i].ID < ls[j].ID
			})
			if len(ls) > limit {
				ls = ls[:limit]
			}
			for _, l := range ls {
				e.see(l.ID)
			}
			res := map[string]any{"due_count": len(items), "wrong_book_count": wrongBook, "scheduled_count": scheduledN,
				"questions": qs, "lessons": ls}
			if len(items) == 0 {
				res["note"] = "错题本是空的，也没有到期的复习，暂时没有需要复习的题。"
			} else if len(items) > len(qs) {
				res["note"] = "只列了最紧迫的几道；想看更多可以加大 limit，或带 bank_id 缩小范围。"
			}
			return res, nil
		},
	}
}

func toolGetStudyStats() *tool {
	type args struct {
		BankID string `json:"bank_id"`
		Days   int    `json:"days"`
	}
	return &tool{
		spec: llmSpec("get_study_stats",
			"查看用户的学习概况：近几天每天的作答数和正确率、学习时长、连续学习天数，以及整体进度（做过多少题、最近一次答对多少、错题本有多少）。用于“我最近学得怎么样”“今天学了多少”“进度如何”这类问题。",
			schema(nil, map[string]any{
				"bank_id": str("只看这个题库；不填就用用户当前所在的题库，没有就看全部"),
				"days":    integer("统计最近几天，默认 7，最大 90"),
			})),
		label: func(context.Context, *env, json.RawMessage) string { return "统计学习情况" },
		run: func(ctx context.Context, e *env, raw json.RawMessage) (any, error) {
			var a args
			if err := parseArgs(raw, &a); err != nil {
				return nil, err
			}
			questions, err := e.lib.Questions(ctx)
			if err != nil {
				return nil, err
			}
			attempts, err := e.lib.Attempts(ctx)
			if err != nil {
				return nil, err
			}
			states, err := e.lib.States(ctx)
			if err != nil {
				return nil, err
			}
			byID := bankQuestions(questions, e.bankOrDefault(a.BankID))
			days := clampLimit(a.Days, 7, 90)

			// Days are calendar days in the clock's own zone, as the apps' statistics are.
			now := e.now()
			loc := now.Location()
			dayStart := func(back int) time.Time {
				y, m, d := now.Date()
				return time.Date(y, m, d-back, 0, 0, 0, 0, loc)
			}
			key := func(t time.Time) string { return t.Format("2006-01-02") }
			today := key(dayStart(0))
			periodFrom := key(dayStart(days - 1))

			type tally struct {
				attempts, correct int
				ms                int64
			}
			var total, period, todayT tally
			perDay := map[string]*tally{}
			active := map[string]bool{}
			latest := map[string]bool{}
			for _, at := range attempts {
				if _, ok := byID[at.QuestionID]; !ok {
					continue
				}
				total.attempts++
				if at.Correct {
					total.correct++
				}
				latest[at.QuestionID] = at.Correct
				day := key(time.UnixMilli(at.At).In(loc))
				active[day] = true
				if day < periodFrom || day > today {
					continue
				}
				for _, t := range []*tally{&period, perDayOf(perDay, day)} {
					t.attempts++
					t.ms += studyMs(at)
					if at.Correct {
						t.correct++
					}
				}
			}
			if d := perDay[today]; d != nil {
				todayT = *d
			}
			streak := 0
			back := 1
			if active[today] {
				back = 0
			}
			for active[key(dayStart(back))] {
				streak++
				back++
			}

			wrongBook := 0
			for _, s := range states {
				if _, ok := byID[s.QuestionID]; ok && s.InWrongBook() {
					wrongBook++
				}
			}
			latestOK := 0
			for _, ok := range latest {
				if ok {
					latestOK++
				}
			}

			type dOut struct {
				Date     string `json:"date"`
				Attempts int    `json:"attempts"`
				Correct  int    `json:"correct"`
				Accuracy int    `json:"accuracy_percent"`
			}
			daily := []dOut{}
			activeDays := 0
			for back := days - 1; back >= 0; back-- {
				t := dayStart(back)
				if d := perDay[key(t)]; d != nil {
					activeDays++
					daily = append(daily, dOut{t.Format("01-02"), d.attempts, d.correct, percent(d.correct, d.attempts)})
				}
			}
			res := map[string]any{
				"bank_questions":     len(byID),
				"answered_questions": len(latest),
				"coverage_percent":   percent(len(latest), len(byID)),
				"latest_correct":     latestOK,
				"wrong_book":         wrongBook,
				"overall": map[string]any{"attempts": total.attempts, "correct": total.correct,
					"accuracy_percent": percent(total.correct, total.attempts)},
				"streak_days": streak,
				"period_days": days,
				"period": map[string]any{"attempts": period.attempts, "correct": period.correct,
					"accuracy_percent": percent(period.correct, period.attempts), "active_days": activeDays,
					"study_minutes": minutes(period.ms)},
				"today": map[string]any{"attempts": todayT.attempts, "correct": todayT.correct,
					"study_minutes": minutes(todayT.ms)},
				"daily": daily,
			}
			if total.attempts == 0 {
				res["note"] = "还没有作答记录。"
			}
			return res, nil
		},
	}
}

func perDayOf[T any](m map[string]*T, day string) *T {
	if m[day] == nil {
		m[day] = new(T)
	}
	return m[day]
}

func toolGetQuestionDetail() *tool {
	type args struct {
		QuestionID string `json:"question_id"`
	}
	return &tool{
		spec: llmSpec("get_question_detail",
			"查看一道题的完整信息：题干、选项、标准答案、完整解析、出自哪一节，以及用户自己的情况——作答历史、常选错的选项、是否收藏、是否在错题本、已有的 AI 解析。用户追问某道题“为什么选 B 错了”“这题怎么理解”时用。注意它会返回标准答案，用户还没作答的题不要直接透露。",
			schema([]string{"question_id"}, map[string]any{
				"question_id": str("题目 id，来自其他工具的结果或用户给出的上下文"),
			})),
		label: func(context.Context, *env, json.RawMessage) string { return "查看题目详情" },
		run: func(ctx context.Context, e *env, raw json.RawMessage) (any, error) {
			var a args
			if err := parseArgs(raw, &a); err != nil {
				return nil, err
			}
			questions, err := e.lib.Questions(ctx)
			if err != nil {
				return nil, err
			}
			var q *Question
			for i := range questions {
				if questions[i].ID == a.QuestionID {
					q = &questions[i]
					break
				}
			}
			if q == nil {
				return nil, badArgs("没有 id 为 %q 的题，请用 search_questions 取得 question_id", a.QuestionID)
			}
			attempts, err := e.lib.Attempts(ctx)
			if err != nil {
				return nil, err
			}
			states, err := e.lib.States(ctx)
			if err != nil {
				return nil, err
			}
			note, err := e.lib.Note(ctx, q.ID)
			if err != nil {
				return nil, err
			}
			e.see(q.ID, q.LessonID)

			loc := e.now().Location()
			type tryOut struct {
				At      string `json:"at"`
				Correct bool   `json:"correct"`
				Picked  []int  `json:"picked"`
				Seconds int    `json:"seconds,omitempty"`
			}
			var mine []Attempt
			for _, at := range attempts {
				if at.QuestionID == q.ID {
					mine = append(mine, at)
				}
			}
			correct := 0
			misses := map[int]int{}
			for _, at := range mine {
				if at.Correct {
					correct++
					continue
				}
				for _, i := range at.Selected {
					misses[i]++
				}
			}
			recent := []tryOut{}
			for i := len(mine) - 1; i >= 0 && len(recent) < 5; i-- {
				at := mine[i]
				picked := at.Selected
				if picked == nil {
					picked = []int{}
				}
				recent = append(recent, tryOut{time.UnixMilli(at.At).In(loc).Format("2006-01-02 15:04"), at.Correct, picked,
					int(capMs(at.DurationMs, maxAttemptMs)+500) / 1000})
			}
			type missOut struct {
				Index int    `json:"option_index"`
				Text  string `json:"text"`
				Times int    `json:"times"`
			}
			wrongPicks := []missOut{}
			for i, n := range misses {
				text := ""
				if i >= 0 && i < len(q.Options) {
					text = clip(q.Options[i], 40)
				}
				wrongPicks = append(wrongPicks, missOut{i, text, n})
			}
			sort.Slice(wrongPicks, func(i, j int) bool {
				if wrongPicks[i].Times != wrongPicks[j].Times {
					return wrongPicks[i].Times > wrongPicks[j].Times
				}
				return wrongPicks[i].Index < wrongPicks[j].Index
			})

			res := map[string]any{
				"question_id": q.ID, "type": q.Type, "difficulty": q.Difficulty,
				"stem": q.Stem, "options": q.Options, "answer_index": q.Answer,
				"explanation": clip(q.Explanation, 1500),
				"mine":        map[string]any{"attempts": len(mine), "correct": correct, "recent": recent, "wrong_picks": wrongPicks},
			}
			if q.LessonID != "" {
				res["lesson_id"] = q.LessonID
				if l, _ := e.lib.Lesson(ctx, q.LessonID); l != nil {
					res["lesson_path"] = l.HeadingPath
				}
			}
			for _, s := range states {
				if s.QuestionID != q.ID {
					continue
				}
				res["favorite"] = s.Favorite
				res["in_wrong_book"] = s.InWrongBook()
				res["wrong_count"] = s.WrongCount
				res["streak"] = s.Streak
				if s.DueAt > 0 {
					res["review_due"] = time.UnixMilli(s.DueAt).In(loc).Format("2006-01-02")
				}
				break
			}
			if note != "" {
				res["ai_note"] = clip(note, 1500)
			}
			return res, nil
		},
	}
}

package agent

import (
	"context"
	"encoding/json"
	"math/rand/v2"
	"sort"
	"strings"
)

type questionFilter struct {
	LessonID string
	BankID   string
}

func (f questionFilter) match(q Question) bool {
	return (f.LessonID == "" || q.LessonID == f.LessonID) && (f.BankID == "" || q.BankID == f.BankID)
}

func toolSearchQuestions() *tool {
	type args struct {
		Query    string `json:"query"`
		LessonID string `json:"lesson_id"`
		BankID   string `json:"bank_id"`
		Limit    int    `json:"limit"`
	}
	return &tool{
		spec: llmSpec("search_questions",
			"查找题库里已发布的题目，返回题干、选项、标准答案、解析和用户的作答统计。用来举例、核对已有的题、避免重复。",
			schema(nil, map[string]any{
				"query":     str("关键词；不填则按 lesson_id / bank_id 列出"),
				"lesson_id": str("只看出自这一节的题"),
				"bank_id":   str("只在这个题库里找；不填就用用户当前所在的题库，没有就找全部"),
				"limit":     integer("最多返回几道，默认 5，最大 10"),
			})),
		label: func(_ context.Context, _ *env, raw json.RawMessage) string {
			var a args
			_ = parseArgs(raw, &a)
			if a.Query != "" {
				return "查找题目「" + clip(a.Query, 20) + "」"
			}
			return "查找题目"
		},
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
			stats := questionStats(attempts)
			f := questionFilter{a.LessonID, e.bankOrDefault(a.BankID)}
			terms := searchTerms(a.Query)
			type hit struct {
				q     Question
				score int
			}
			var hits []hit
			for _, q := range questions {
				if !f.match(q) {
					continue
				}
				s := 1
				if len(terms) > 0 {
					text := strings.ToLower(q.Stem + "\n" + strings.Join(q.Options, "\n") + "\n" + q.Explanation)
					if s = termScore(text, terms); s == 0 {
						continue
					}
				}
				hits = append(hits, hit{q, s})
			}
			sort.SliceStable(hits, func(i, j int) bool {
				if hits[i].score != hits[j].score {
					return hits[i].score > hits[j].score
				}
				return hits[i].q.ID < hits[j].q.ID
			})
			type out struct {
				ID          string   `json:"question_id"`
				LessonID    string   `json:"lesson_id,omitempty"`
				Type        string   `json:"type"`
				Stem        string   `json:"stem"`
				Options     []string `json:"options"`
				Answer      []int    `json:"answer_index"`
				Explanation string   `json:"explanation"`
				Attempts    int      `json:"attempts"`
				Correct     int      `json:"correct"`
			}
			res := []out{}
			for _, h := range hits {
				if len(res) == clampLimit(a.Limit, 5, 10) {
					break
				}
				e.see(h.q.ID, h.q.LessonID)
				o := out{ID: h.q.ID, LessonID: h.q.LessonID, Type: h.q.Type, Stem: h.q.Stem, Options: h.q.Options,
					Answer: h.q.Answer, Explanation: clip(h.q.Explanation, 300)}
				if st := stats[h.q.ID]; st != nil {
					o.Attempts, o.Correct = st.Attempts, st.Correct
				}
				res = append(res, o)
			}
			return map[string]any{"results": res}, nil
		},
	}
}

func toolPickQuestions() *tool {
	type args struct {
		LessonID string `json:"lesson_id"`
		BankID   string `json:"bank_id"`
		Weak     bool   `json:"weak"`
		Count    int    `json:"count"`
	}
	return &tool{
		spec: llmSpec("pick_questions",
			"从已发布的题里挑几道出给用户做小测。返回题干和选项，不含答案：用户作答前不要透露答案，作答后由用户的 App 给出标准答案，你只负责点评。weak 为真时优先挑用户做错过的题。",
			schema(nil, map[string]any{
				"lesson_id": str("只从这一节的题里挑"),
				"bank_id":   str("只从这个题库里挑；不填就用用户当前所在的题库，没有就挑全部"),
				"weak":      boolean("优先挑用户的薄弱题"),
				"count":     integer("挑几道，默认 3，最大 10"),
			})),
		label: func(context.Context, *env, json.RawMessage) string { return "挑选题目" },
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
			stats := questionStats(attempts)
			f := questionFilter{a.LessonID, e.bankOrDefault(a.BankID)}
			var pool []Question
			for _, q := range questions {
				if f.match(q) {
					pool = append(pool, q)
				}
			}
			count := clampLimit(a.Count, 3, 10)
			switch {
			case a.Weak:
				sortWeak(pool, stats)
				// Only questions that have actually gone wrong are weak.
				n := 0
				for n < len(pool) && stats[pool[n].ID] != nil && stats[pool[n].ID].WeakScore > 0 {
					n++
				}
				pool = pool[:n]
			default:
				rand.Shuffle(len(pool), func(i, j int) { pool[i], pool[j] = pool[j], pool[i] })
				// Questions never answered first.
				sort.SliceStable(pool, func(i, j int) bool {
					return stats[pool[i].ID] == nil && stats[pool[j].ID] != nil
				})
			}
			if len(pool) > count {
				pool = pool[:count]
			}
			type out struct {
				ID      string   `json:"question_id"`
				Lesson  string   `json:"lesson_id,omitempty"`
				Type    string   `json:"type"`
				Stem    string   `json:"stem"`
				Options []string `json:"options"`
			}
			res := []out{}
			for _, q := range pool {
				e.see(q.ID, q.LessonID)
				res = append(res, out{q.ID, q.LessonID, q.Type, q.Stem, q.Options})
			}
			if len(res) == 0 {
				return map[string]any{"questions": res, "note": "没有符合条件的题。"}, nil
			}
			return map[string]any{"questions": res}, nil
		},
	}
}

func toolGetWeakPoints() *tool {
	type args struct {
		BankID string `json:"bank_id"`
		Limit  int    `json:"limit"`
	}
	return &tool{
		spec: llmSpec("get_weak_points",
			"查看用户的薄弱点：最近几次作答里错得多的题，以及正确率低的小节。用于“我哪里薄弱”“帮我复习”这类问题。",
			schema(nil, map[string]any{
				"bank_id": str("只看这个题库；不填就用用户当前所在的题库，没有就看全部"),
				"limit":   integer("题和小节各最多返回几个，默认 5，最大 10"),
			})),
		label: func(context.Context, *env, json.RawMessage) string { return "分析薄弱点" },
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
			stats := questionStats(attempts)
			bank := e.bankOrDefault(a.BankID)
			limit := clampLimit(a.Limit, 5, 10)

			var pool []Question
			type agg struct{ attempts, correct int }
			byLesson := map[string]*agg{}
			for _, q := range questions {
				if bank != "" && q.BankID != bank {
					continue
				}
				st := stats[q.ID]
				if st == nil {
					continue
				}
				pool = append(pool, q)
				if q.LessonID != "" {
					g := byLesson[q.LessonID]
					if g == nil {
						g = &agg{}
						byLesson[q.LessonID] = g
					}
					g.attempts += st.Attempts
					g.correct += st.Correct
				}
			}
			sortWeak(pool, stats)

			type qOut struct {
				ID       string `json:"question_id"`
				LessonID string `json:"lesson_id,omitempty"`
				Stem     string `json:"stem"`
				Recent   int    `json:"recent_attempts"`
				Wrong    int    `json:"recent_wrong"`
			}
			weakQs := []qOut{}
			for _, q := range pool {
				st := stats[q.ID]
				if st.WeakScore == 0 || len(weakQs) == limit {
					break
				}
				e.see(q.ID, q.LessonID)
				weakQs = append(weakQs, qOut{q.ID, q.LessonID, clip(q.Stem, 80), st.RecentCount, st.RecentWrong})
			}

			type lOut struct {
				ID       string `json:"lesson_id"`
				Path     string `json:"path"`
				Attempts int    `json:"attempts"`
				Accuracy int    `json:"accuracy_percent"`
			}
			var weakLs []lOut
			for id, g := range byLesson {
				if g.attempts < 3 || g.correct == g.attempts {
					continue
				}
				l, _ := e.lib.Lesson(ctx, id)
				if l == nil {
					continue
				}
				weakLs = append(weakLs, lOut{id, l.HeadingPath, g.attempts, 100 * g.correct / g.attempts})
			}
			sort.Slice(weakLs, func(i, j int) bool {
				if weakLs[i].Accuracy != weakLs[j].Accuracy {
					return weakLs[i].Accuracy < weakLs[j].Accuracy
				}
				if weakLs[i].Attempts != weakLs[j].Attempts {
					return weakLs[i].Attempts > weakLs[j].Attempts
				}
				return weakLs[i].ID < weakLs[j].ID
			})
			if len(weakLs) > limit {
				weakLs = weakLs[:limit]
			}
			for _, l := range weakLs {
				e.see(l.ID)
			}
			if weakLs == nil {
				weakLs = []lOut{}
			}
			res := map[string]any{"weak_questions": weakQs, "weak_lessons": weakLs}
			if len(weakQs) == 0 && len(weakLs) == 0 {
				res["note"] = "还没有足够的作答记录，看不出薄弱点。"
			}
			return res, nil
		},
	}
}

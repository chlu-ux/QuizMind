package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

const maxOutlineLessons = 200

func toolListOutline() *tool {
	type args struct {
		BankID     string `json:"bank_id"`
		DocumentID string `json:"document_id"`
	}
	return &tool{
		spec: llmSpec("list_outline",
			"列出题库的目录：题库 → 章节 → 小节，每节带题数和用户的作答进度。回答“讲讲第几章”“我还有哪些没学”之类的问题时先用它。小节很多时只列章节，再用 document_id 展开某一章。",
			schema(nil, map[string]any{
				"bank_id":     str("只看这个题库；不填就用用户当前所在的题库，没有就列全部"),
				"document_id": str("只展开这一章（文档）的小节"),
			})),
		label: func(context.Context, *env, json.RawMessage) string { return "查看目录" },
		run: func(ctx context.Context, e *env, raw json.RawMessage) (any, error) {
			var a args
			if err := parseArgs(raw, &a); err != nil {
				return nil, err
			}
			banks, err := e.lib.Banks(ctx)
			if err != nil {
				return nil, err
			}
			lessons, err := e.lib.Lessons(ctx)
			if err != nil {
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
			type prog struct{ total, answered, latestCorrect int }
			byLesson := map[string]*prog{}
			for _, q := range questions {
				if q.LessonID == "" {
					continue
				}
				p := byLesson[q.LessonID]
				if p == nil {
					p = &prog{}
					byLesson[q.LessonID] = p
				}
				p.total++
				if st := stats[q.ID]; st != nil {
					p.answered++
					if st.LatestCorrect {
						p.latestCorrect++
					}
				}
			}

			bank := e.bankOrDefault(a.BankID)
			wantLessons := a.DocumentID != ""
			if !wantLessons {
				n := 0
				for _, l := range lessons {
					if bank == "" || l.BankID == bank {
						n++
					}
				}
				wantLessons = n <= maxOutlineLessons
			}

			type lessonOut struct {
				ID            string `json:"lesson_id"`
				Title         string `json:"title"`
				Path          string `json:"path"`
				Questions     int    `json:"questions"`
				Answered      int    `json:"answered"`
				LatestCorrect int    `json:"latest_correct"`
			}
			type docOut struct {
				ID      string      `json:"document_id"`
				Title   string      `json:"title"`
				Count   int         `json:"lesson_count"`
				Lessons []lessonOut `json:"lessons,omitempty"`
			}
			type bankOut struct {
				ID        string   `json:"bank_id"`
				Title     string   `json:"title"`
				Documents []docOut `json:"documents"`
			}
			var out []bankOut
			for _, b := range banks {
				if bank != "" && b.ID != bank {
					continue
				}
				bo := bankOut{ID: b.ID, Title: b.Title, Documents: []docOut{}}
				idx := map[string]int{}
				for i := range lessons {
					l := &lessons[i]
					if l.BankID != b.ID || (a.DocumentID != "" && l.DocumentID != a.DocumentID) {
						continue
					}
					di, ok := idx[l.DocumentID]
					if !ok {
						di = len(bo.Documents)
						idx[l.DocumentID] = di
						bo.Documents = append(bo.Documents, docOut{ID: l.DocumentID, Title: l.DocumentTitle})
					}
					d := &bo.Documents[di]
					d.Count++
					if wantLessons {
						p := byLesson[l.ID]
						if p == nil {
							p = &prog{}
						}
						d.Lessons = append(d.Lessons, lessonOut{ID: l.ID, Title: lessonTitle(l), Path: l.HeadingPath,
							Questions: p.total, Answered: p.answered, LatestCorrect: p.latestCorrect})
						e.see(l.ID)
					}
				}
				if len(bo.Documents) > 0 {
					out = append(out, bo)
				}
			}
			res := map[string]any{"banks": out}
			if !wantLessons {
				res["note"] = "小节太多，只列了章节。要看某一章的小节，请带上它的 document_id 再调用。"
			}
			return res, nil
		},
	}
}

func toolSearchLessons() *tool {
	type args struct {
		Query  string `json:"query"`
		BankID string `json:"bank_id"`
		Limit  int    `json:"limit"`
	}
	return &tool{
		spec: llmSpec("search_lessons",
			"在讲义里按关键词查找小节，返回命中的小节和命中处的上下文片段。要引用或讲解讲义内容时先用它定位，再用 get_lesson 读全文。",
			schema([]string{"query"}, map[string]any{
				"query":   str("关键词或一句话，可以是中文"),
				"bank_id": str("只在这个题库里找；不填就用用户当前所在的题库，没有就找全部"),
				"limit":   integer("最多返回几节，默认 5，最大 8"),
			})),
		label: func(_ context.Context, _ *env, raw json.RawMessage) string {
			var a args
			_ = parseArgs(raw, &a)
			return "在讲义里查找「" + clip(a.Query, 20) + "」"
		},
		run: func(ctx context.Context, e *env, raw json.RawMessage) (any, error) {
			var a args
			if err := parseArgs(raw, &a); err != nil {
				return nil, err
			}
			terms := searchTerms(a.Query)
			if len(terms) == 0 {
				return nil, badArgs("query 不能为空")
			}
			lessons, err := e.lib.Lessons(ctx)
			if err != nil {
				return nil, err
			}
			bank := e.bankOrDefault(a.BankID)
			type hit struct {
				l     *Lesson
				score int
			}
			var hits []hit
			for i := range lessons {
				l := &lessons[i]
				if bank != "" && l.BankID != bank {
					continue
				}
				// A hit in the heading counts three times as much as one in the body.
				s := 3*termScore(strings.ToLower(l.HeadingPath), terms) + termScore(strings.ToLower(l.Text), terms)
				if s > 0 {
					hits = append(hits, hit{l, s})
				}
			}
			sort.SliceStable(hits, func(i, j int) bool {
				if hits[i].score != hits[j].score {
					return hits[i].score > hits[j].score
				}
				return hits[i].l.ID < hits[j].l.ID
			})
			limit := clampLimit(a.Limit, 5, 8)
			type out struct {
				ID      string `json:"lesson_id"`
				Path    string `json:"path"`
				Snippet string `json:"snippet"`
			}
			res := []out{}
			for _, h := range hits {
				if len(res) == limit {
					break
				}
				e.see(h.l.ID)
				res = append(res, out{h.l.ID, h.l.HeadingPath, snippet(h.l.Text, terms, 100)})
			}
			if len(res) == 0 {
				return map[string]any{"results": res, "note": "讲义里没有找到相关内容。"}, nil
			}
			return map[string]any{"results": res}, nil
		},
	}
}

func toolGetLesson() *tool {
	type args struct {
		LessonID      string `json:"lesson_id"`
		WithNeighbors bool   `json:"with_neighbors"`
	}
	return &tool{
		spec: llmSpec("get_lesson",
			"读取一节讲义的全文，讲解和出题都以它为依据。with_neighbors 为真时附上前后两节的标题。",
			schema([]string{"lesson_id"}, map[string]any{
				"lesson_id":      str("小节 id，来自 list_outline / search_lessons 等的结果"),
				"with_neighbors": boolean("是否附上前后两节的标题"),
			})),
		label: func(ctx context.Context, e *env, raw json.RawMessage) string {
			var a args
			_ = parseArgs(raw, &a)
			if l, _ := e.lib.Lesson(ctx, a.LessonID); l != nil {
				return "读取讲义「" + clip(lessonTitle(l), 20) + "」"
			}
			return "读取讲义"
		},
		run: func(ctx context.Context, e *env, raw json.RawMessage) (any, error) {
			var a args
			if err := parseArgs(raw, &a); err != nil {
				return nil, err
			}
			l, err := e.lib.Lesson(ctx, a.LessonID)
			if err != nil {
				return nil, err
			}
			if l == nil {
				return nil, badArgs("没有 id 为 %q 的小节，请用 search_lessons 或 list_outline 取得 lesson_id", a.LessonID)
			}
			e.see(l.ID)
			// The text is data from the library, not instructions: wrap it so the prompt can say so.
			var sb strings.Builder
			fmt.Fprintf(&sb, "<lesson id=%q path=%q>\n%s\n</lesson>", l.ID, l.HeadingPath, l.Text)
			if a.WithNeighbors {
				all, _ := e.lib.Lessons(ctx)
				for i := range all {
					if all[i].ID != l.ID {
						continue
					}
					if i > 0 && all[i-1].DocumentID == l.DocumentID {
						fmt.Fprintf(&sb, "\n上一节：%s（lesson_id=%s）", all[i-1].HeadingPath, all[i-1].ID)
						e.see(all[i-1].ID)
					}
					if i+1 < len(all) && all[i+1].DocumentID == l.DocumentID {
						fmt.Fprintf(&sb, "\n下一节：%s（lesson_id=%s）", all[i+1].HeadingPath, all[i+1].ID)
						e.see(all[i+1].ID)
					}
					break
				}
			}
			return sb.String(), nil
		},
	}
}

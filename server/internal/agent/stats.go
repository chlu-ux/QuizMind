package agent

import "sort"

// The weak-question ranking matches the apps (h5 stats.ts WEAK_*): a question counts as weak when
// it was answered wrong within its last weakWindow answers; small samples are pulled toward
// weakPriorRate with the weight of weakPriorWeight answers.
const (
	weakWindow      = 5
	weakPriorRate   = 0.25
	weakPriorWeight = 4
)

type qStat struct {
	Attempts      int  // all answers
	Correct       int  // all correct answers
	LatestCorrect bool // the most recent answer
	Answered      bool
	RecentWrong   int // wrong answers among the last weakWindow
	RecentCount   int
	WeakScore     float64
}

// questionStats summarises attempts (oldest first) per question.
func questionStats(attempts []Attempt) map[string]*qStat {
	byQ := map[string][]bool{}
	for _, a := range attempts {
		byQ[a.QuestionID] = append(byQ[a.QuestionID], a.Correct)
	}
	out := make(map[string]*qStat, len(byQ))
	for id, results := range byQ {
		st := &qStat{Attempts: len(results), Answered: true, LatestCorrect: results[len(results)-1]}
		for _, ok := range results {
			if ok {
				st.Correct++
			}
		}
		recent := results[max(0, len(results)-weakWindow):]
		st.RecentCount = len(recent)
		for _, ok := range recent {
			if !ok {
				st.RecentWrong++
			}
		}
		if st.RecentWrong > 0 {
			st.WeakScore = (float64(st.RecentWrong) + weakPriorRate*weakPriorWeight) / float64(st.RecentCount+weakPriorWeight)
		}
		out[id] = st
	}
	return out
}

// sortWeak orders questions weakest first, ties broken by id so the order is stable.
func sortWeak(qs []Question, stats map[string]*qStat) {
	score := func(q Question) (float64, int) {
		if st := stats[q.ID]; st != nil {
			return st.WeakScore, st.RecentWrong
		}
		return 0, 0
	}
	sort.SliceStable(qs, func(i, j int) bool {
		si, wi := score(qs[i])
		sj, wj := score(qs[j])
		if si != sj {
			return si > sj
		}
		if wi != wj {
			return wi > wj
		}
		return qs[i].ID < qs[j].ID
	})
}

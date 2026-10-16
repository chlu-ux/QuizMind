package agent

import (
	"context"
	"encoding/json"
	"sync"
)

type Bank struct {
	ID    string
	Title string
}

// Lesson is one section of a document: the unit questions are written from and cited by.
type Lesson struct {
	ID            string
	BankID        string
	DocumentID    string
	DocumentTitle string
	HeadingPath   string
	Text          string
}

// Question is a published question.
type Question struct {
	ID          string
	BankID      string
	LessonID    string // the section it was written from; empty when it has none
	Type        string
	Stem        string
	Options     []string
	Answer      []int
	Explanation string
	Difficulty  int64
}

// Attempt is one answer the learner gave, from any device.
type Attempt struct {
	QuestionID string
	Correct    bool
	At         int64 // when it was answered (ms)
	Selected   []int // the options picked
	DurationMs int64 // time from showing the question to answering it; 0 when unknown
	ReviewMs   int64 // time spent on it after answering (explanation); 0 when unknown
}

// QState is what the learner keeps per question: the wrong book, favorites and the review schedule.
// Only questions the learner has touched have one.
type QState struct {
	QuestionID string
	// DueAt is when a scheduled review falls due (ms); 0 when nothing is scheduled. No app schedules
	// reviews yet, so today the wrong book is what marks a question for review.
	DueAt      int64
	Favorite   bool
	WrongCount int
	// Streak is the right answers in a row since the last miss.
	Streak int
}

// ClearStreak is how many right answers in a row take a question out of the wrong book.
const ClearStreak = 2

// InWrongBook: missed at least once and not yet answered right twice in a row.
func (s QState) InWrongBook() bool { return s.WrongCount > 0 && s.Streak < ClearStreak }

// StreakOf reads the right-answers-in-a-row count from the opaque progress record the apps keep in a
// question state's fsrs field (`{"v":1,"streak":2,"last":...}`); anything unreadable counts as 0.
func StreakOf(fsrs string) int {
	var p struct {
		Streak int `json:"streak"`
	}
	if json.Unmarshal([]byte(fsrs), &p) != nil || p.Streak < 0 {
		return 0
	}
	return p.Streak
}

// Library is the read-only view of the study material the tools search. The whole library is
// small (the apps download all of it), so implementations return everything and the tools filter.
type Library interface {
	Banks(ctx context.Context) ([]Bank, error)
	Lessons(ctx context.Context) ([]Lesson, error)
	// Questions returns published questions only.
	Questions(ctx context.Context) ([]Question, error)
	// Attempts returns every attempt, oldest first.
	Attempts(ctx context.Context) ([]Attempt, error)
	// States returns the per-question state of every question the learner has touched.
	States(ctx context.Context) ([]QState, error)
	// Note returns the AI explanation kept for a question; empty when there is none.
	Note(ctx context.Context, questionID string) (string, error)
}

// snapshot loads each part of the library at most once, so one conversation sees a consistent
// library however many tools it calls.
type snapshot struct {
	lib Library

	once      [5]sync.Once
	banks     []Bank
	lessons   []Lesson
	questions []Question
	attempts  []Attempt
	states    []QState
	errs      [5]error

	lessonByID map[string]*Lesson
}

func newSnapshot(lib Library) *snapshot { return &snapshot{lib: lib} }

func (s *snapshot) Banks(ctx context.Context) ([]Bank, error) {
	s.once[0].Do(func() { s.banks, s.errs[0] = s.lib.Banks(ctx) })
	return s.banks, s.errs[0]
}

func (s *snapshot) Lessons(ctx context.Context) ([]Lesson, error) {
	s.once[1].Do(func() {
		s.lessons, s.errs[1] = s.lib.Lessons(ctx)
		s.lessonByID = make(map[string]*Lesson, len(s.lessons))
		for i := range s.lessons {
			s.lessonByID[s.lessons[i].ID] = &s.lessons[i]
		}
	})
	return s.lessons, s.errs[1]
}

func (s *snapshot) Lesson(ctx context.Context, id string) (*Lesson, error) {
	if _, err := s.Lessons(ctx); err != nil {
		return nil, err
	}
	return s.lessonByID[id], nil
}

func (s *snapshot) Questions(ctx context.Context) ([]Question, error) {
	s.once[2].Do(func() { s.questions, s.errs[2] = s.lib.Questions(ctx) })
	return s.questions, s.errs[2]
}

func (s *snapshot) Attempts(ctx context.Context) ([]Attempt, error) {
	s.once[3].Do(func() { s.attempts, s.errs[3] = s.lib.Attempts(ctx) })
	return s.attempts, s.errs[3]
}

func (s *snapshot) States(ctx context.Context) ([]QState, error) {
	s.once[4].Do(func() { s.states, s.errs[4] = s.lib.States(ctx) })
	return s.states, s.errs[4]
}

func (s *snapshot) Note(ctx context.Context, questionID string) (string, error) {
	return s.lib.Note(ctx, questionID)
}

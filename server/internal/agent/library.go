package agent

import (
	"context"
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
	At         int64
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
}

// snapshot loads each part of the library at most once, so one conversation sees a consistent
// library however many tools it calls.
type snapshot struct {
	lib Library

	once      [4]sync.Once
	banks     []Bank
	lessons   []Lesson
	questions []Question
	attempts  []Attempt
	errs      [4]error

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

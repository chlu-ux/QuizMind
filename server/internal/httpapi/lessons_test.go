package httpapi_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type lessonsPage struct {
	Version   int64 `json:"version"`
	Unchanged bool  `json:"unchanged"`
	Items     []struct {
		ID            string
		BankID        string `json:"bank_id"`
		DocumentID    string `json:"document_id"`
		DocumentTitle string `json:"document_title"`
		Seq           int64
		HeadingPath   string `json:"heading_path"`
		Text          string
	}
}

func TestLessons(t *testing.T) {
	s := newServer(t)

	var none lessonsPage
	s.do(t, "GET", "/api/v1/lessons", "", 200, &none)
	assert.Empty(t, none.Items, "no document yet")
	assert.NotZero(t, none.Version, "even an empty library has a version")

	qid := s.publishOne(t)

	var all lessonsPage
	s.do(t, "GET", "/api/v1/lessons", "", 200, &all)
	require.Len(t, all.Items, 1)
	l := all.Items[0]
	assert.Equal(t, s.bank, l.BankID)
	assert.Equal(t, "并发 > 读写锁", l.HeadingPath)
	assert.Contains(t, l.Text, "读写锁允许多个读者同时持有锁")
	assert.NotEqual(t, none.Version, all.Version, "adding a document moves the version")
	assert.False(t, all.Unchanged)

	// The question names the lesson it belongs to.
	var qs struct {
		Items []struct {
			ID      string
			ChunkID string `json:"chunk_id"`
		}
	}
	s.do(t, "GET", "/api/v1/sync/questions?since=0", "", 200, &qs)
	require.Len(t, qs.Items, 1)
	assert.Equal(t, qid, qs.Items[0].ID)
	assert.Equal(t, l.ID, qs.Items[0].ChunkID)

	// A device that already has this version is told so and gets no sections.
	var same lessonsPage
	s.do(t, "GET", "/api/v1/lessons?version="+itoa(all.Version), "", 200, &same)
	assert.True(t, same.Unchanged)
	assert.Empty(t, same.Items)
	assert.Equal(t, all.Version, same.Version)

	var stale lessonsPage
	s.do(t, "GET", "/api/v1/lessons?version="+itoa(all.Version+2), "", 200, &stale)
	assert.False(t, stale.Unchanged)
	assert.Len(t, stale.Items, 1)
}

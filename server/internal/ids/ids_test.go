package ids_test

import (
	"sort"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/chlu-ux/quizmind/server/internal/ids"
)

func TestNewIsStrictlyIncreasing(t *testing.T) {
	got := make([]string, 5000)
	for i := range got {
		got[i] = ids.New()
	}
	assert.True(t, sort.StringsAreSorted(got), "ids made one after another sort in that order, even within a millisecond")
	seen := map[string]bool{}
	for _, id := range got {
		assert.False(t, seen[id])
		seen[id] = true
		assert.Len(t, id, 26)
	}
}

func TestNewIsSafeForConcurrentUse(t *testing.T) {
	var wg sync.WaitGroup
	var mu sync.Mutex
	seen := map[string]bool{}
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 500; i++ {
				id := ids.New()
				mu.Lock()
				assert.False(t, seen[id], "duplicate id")
				seen[id] = true
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
}

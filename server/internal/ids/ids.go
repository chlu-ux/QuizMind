// Package ids generates time-ordered unique identifiers (ULID).
package ids

import (
	"crypto/rand"
	"sync"
	"time"

	"github.com/oklog/ulid/v2"
)

var (
	mu      sync.Mutex
	entropy = ulid.Monotonic(rand.Reader, 0)
)

// New returns a new ULID string. ULIDs sort by creation time and are safe to
// generate on clients as well, which the sync protocol relies on. Within this
// process they are also strictly increasing: two ids made in the same
// millisecond still sort in the order they were made, which lists ordered by
// "created_at, id" depend on.
func New() string {
	mu.Lock()
	defer mu.Unlock()
	return ulid.MustNew(ulid.Timestamp(time.Now()), entropy).String()
}

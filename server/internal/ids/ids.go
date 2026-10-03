// Package ids generates time-ordered unique identifiers (ULID).
package ids

import (
	"crypto/rand"
	"time"

	"github.com/oklog/ulid/v2"
)

// New returns a new ULID string. ULIDs sort by creation time and are safe to
// generate on clients as well, which the sync protocol relies on.
func New() string {
	return ulid.MustNew(ulid.Timestamp(time.Now()), rand.Reader).String()
}

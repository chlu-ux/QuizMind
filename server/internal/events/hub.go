// Package events is a tiny in-process pub/sub used to push job and document
// progress to the admin UI over SSE. Delivery is best-effort: a slow
// subscriber drops events rather than blocking the pipeline.
package events

import "sync"

type Event struct {
	Type       string `json:"type"` // job | document
	ID         string `json:"id"`
	DocumentID string `json:"document_id,omitempty"`
	Status     string `json:"status"`
	Kind       string `json:"kind,omitempty"` // job type
	Error      string `json:"error,omitempty"`
}

type Hub struct {
	mu     sync.Mutex
	subs   map[chan Event]struct{}
	done   chan struct{}
	closed bool
}

func NewHub() *Hub { return &Hub{subs: map[chan Event]struct{}{}, done: make(chan struct{})} }

// Done is closed by Close. Long-lived streams select on it so a server
// shutdown is not held up by connected browsers.
func (h *Hub) Done() <-chan struct{} { return h.done }

// Close signals every stream to finish. It is safe to call more than once.
func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.closed {
		h.closed = true
		close(h.done)
	}
}

// Subscribe returns a channel of events and a function that unsubscribes.
func (h *Hub) Subscribe() (<-chan Event, func()) {
	ch := make(chan Event, 64)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		delete(h.subs, ch)
		h.mu.Unlock()
	}
}

func (h *Hub) Publish(e Event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- e:
		default: // subscriber is behind; drop
		}
	}
}

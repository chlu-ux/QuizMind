package llm

import (
	"fmt"
	"sync"
)

// Registry maps roles to configured clients.
type Registry struct {
	mu      sync.RWMutex
	clients map[Role]Client
}

func NewRegistry() *Registry { return &Registry{clients: map[Role]Client{}} }

func (r *Registry) Set(role Role, c Client) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.clients[role] = c
}

// For returns the client for role, or an error if the role is not configured.
func (r *Registry) For(role Role) (Client, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	c, ok := r.clients[role]
	if !ok {
		return nil, fmt.Errorf("llm: no client configured for role %q", role)
	}
	return c, nil
}

// Replace swaps the whole set of clients at once, so a configuration change never leaves a
// half-updated registry visible to a running job.
func (r *Registry) Replace(clients map[Role]Client) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.clients = clients
}

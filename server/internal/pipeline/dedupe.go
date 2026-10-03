package pipeline

// Existing describes a question already in the bank.
type Existing struct {
	ID      string
	Hash    string
	Stem    string
	Options []string
}

// Deduper detects exact and near-duplicate questions within one bank. Near
// duplicates use Jaccard similarity over character trigrams, which works for
// both Chinese and space-delimited text without tokenisation.
//
// Two questions are near-duplicates when their whole text is similar, or when
// their stems are similar and they share at least half of their options. The
// second rule catches a reworded option; requiring shared options keeps generic
// stems ("which statement is correct?") from colliding with unrelated questions.
type Deduper struct {
	threshold float64
	hashes    map[string]string
	entries   []dedupeEntry
}

type dedupeEntry struct {
	id        string
	textGrams map[string]struct{}
	stemGrams map[string]struct{}
	options   map[string]struct{}
}

func NewDeduper(existing []Existing, threshold float64) *Deduper {
	d := &Deduper{threshold: threshold, hashes: map[string]string{}}
	for _, e := range existing {
		d.add(e.ID, e.Hash, e.Stem, e.Options)
	}
	return d
}

// Check reports whether q duplicates something already known. On a miss the
// question is remembered, so later questions in the same batch compare against
// it too.
func (d *Deduper) Check(id string, q ValidQuestion) (string, bool) {
	if other, ok := d.hashes[q.Hash]; ok {
		return other, true
	}
	cand := newEntry(id, q.Stem, q.Options)
	for _, e := range d.entries {
		if jaccard(cand.textGrams, e.textGrams) >= d.threshold {
			return e.id, true
		}
		if jaccard(cand.stemGrams, e.stemGrams) >= d.threshold &&
			shared(cand.options, e.options) >= 0.5 {
			return e.id, true
		}
	}
	d.hashes[q.Hash] = id
	d.entries = append(d.entries, cand)
	return "", false
}

func (d *Deduper) add(id, hash, stem string, options []string) {
	d.hashes[hash] = id
	d.entries = append(d.entries, newEntry(id, stem, options))
}

func newEntry(id, stem string, options []string) dedupeEntry {
	opts := map[string]struct{}{}
	for _, o := range options {
		opts[Normalize(o)] = struct{}{}
	}
	return dedupeEntry{
		id:        id,
		textGrams: trigrams(DedupeText(stem, options)),
		stemGrams: trigrams(Normalize(stem)),
		options:   opts,
	}
}

// shared is the fraction of a's options that also appear in b.
func shared(a, b map[string]struct{}) float64 {
	if len(a) == 0 {
		return 1
	}
	n := 0
	for k := range a {
		if _, ok := b[k]; ok {
			n++
		}
	}
	return float64(n) / float64(len(a))
}

func trigrams(s string) map[string]struct{} {
	r := []rune(s)
	out := map[string]struct{}{}
	if len(r) < 3 {
		out[s] = struct{}{}
		return out
	}
	for i := 0; i+3 <= len(r); i++ {
		out[string(r[i:i+3])] = struct{}{}
	}
	return out
}

func jaccard(a, b map[string]struct{}) float64 {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	small, large := a, b
	if len(small) > len(large) {
		small, large = large, small
	}
	inter := 0
	for k := range small {
		if _, ok := large[k]; ok {
			inter++
		}
	}
	union := len(a) + len(b) - inter
	return float64(inter) / float64(union)
}

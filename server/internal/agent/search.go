package agent

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// searchTerms splits a query into lower-case terms. Latin words and digits are kept whole; a run
// of Chinese (or other unspaced script) is split into overlapping pairs of characters, because
// there are no spaces to cut it on, plus the run itself when it is short.
func searchTerms(q string) []string {
	var terms []string
	seen := map[string]bool{}
	add := func(t string) {
		if t != "" && !seen[t] {
			seen[t] = true
			terms = append(terms, t)
		}
	}
	var word, han []rune
	flushWord := func() { add(string(word)); word = word[:0] }
	flushHan := func() {
		switch {
		case len(han) == 1:
			add(string(han))
		case len(han) >= 2:
			if len(han) <= 4 {
				add(string(han))
			}
			for i := 0; i+1 < len(han); i++ {
				add(string(han[i : i+2]))
			}
		}
		han = han[:0]
	}
	for _, r := range strings.ToLower(q) {
		switch {
		case unicode.Is(unicode.Han, r):
			flushWord()
			han = append(han, r)
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			flushHan()
			word = append(word, r)
		default:
			flushWord()
			flushHan()
		}
	}
	flushWord()
	flushHan()
	return terms
}

// termScore rates how well text matches terms: each distinct term found counts once, plus a little
// for repeats, so a text that mentions the query's words often ranks above one that mentions one.
func termScore(textLower string, terms []string) int {
	score := 0
	for _, t := range terms {
		n := strings.Count(textLower, t)
		if n == 0 {
			continue
		}
		score += 2 + min(n-1, 2)
	}
	return score
}

// snippet returns about 2*around runes of text centred on the first place any term occurs.
func snippet(text string, terms []string, around int) string {
	lower := strings.ToLower(text)
	first := -1
	for _, t := range terms {
		if i := strings.Index(lower, t); i >= 0 && (first < 0 || i < first) {
			first = i
		}
	}
	runes := []rune(text)
	if first < 0 {
		return clip(string(runes), 2*around)
	}
	at := utf8.RuneCountInString(lower[:first])
	from, to := max(0, at-around), min(len(runes), at+around)
	s := string(runes[from:to])
	if from > 0 {
		s = "…" + s
	}
	if to < len(runes) {
		s += "…"
	}
	return s
}

// clip shortens s to at most n runes.
func clip(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n]) + "…"
}

// Package pipeline turns Markdown documents into reviewed multiple-choice
// questions: chunking, generation, rule validation and de-duplication.
package pipeline

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/text"
)

// ChunkOptions bounds chunk sizes, measured in runes.
type ChunkOptions struct {
	MinChars int // sections shorter than this are merged with what follows
	MaxChars int // soft upper bound; a single code block may exceed it
}

// Chunk is a contiguous slice of a document that one generation call sees.
type Chunk struct {
	Seq         int
	HeadingPath string // e.g. "并发 > 锁 > 读写锁"
	Text        string
	Hash        string // stable across re-imports while text and path are unchanged
}

// minUsefulRunes drops chunks with too little real content to ask about.
const minUsefulRunes = 40

const pathSep = " > "

var (
	frontMatterTitle = regexp.MustCompile(`(?m)^title:\s*["']?(.+?)["']?\s*$`)
	atxLine          = regexp.MustCompile(`^ {0,3}#{1,6}(\s|$)`)
	fenceOpen        = regexp.MustCompile("^ {0,3}(`{3,}|~{3,})")
)

type section struct {
	path     string
	headLine string // raw heading line; empty for the preamble
	body     string
}

// Split parses markdown and returns the document title (front matter title or
// first H1, possibly empty) and its chunks in reading order.
func Split(markdown string, opts ChunkOptions) (string, []Chunk) {
	src := strings.ReplaceAll(markdown, "\r\n", "\n")
	src = strings.ReplaceAll(src, "\r", "\n")
	src, fmTitle := stripFrontMatter(src)

	sections, h1 := parseSections(src, fmTitle)
	title := fmTitle
	if title == "" {
		title = h1
	}

	var units []section
	for _, s := range sections {
		units = append(units, splitOversized(s, opts)...)
	}
	merged := mergeSmall(units, opts)

	var chunks []Chunk
	seen := map[string]bool{}
	for _, m := range merged {
		txt := strings.TrimSpace(m.body)
		if usefulRunes(txt) < minUsefulRunes {
			continue
		}
		h := hashChunk(m.path, txt)
		if seen[h] {
			continue
		}
		seen[h] = true
		chunks = append(chunks, Chunk{Seq: len(chunks), HeadingPath: m.path, Text: txt, Hash: h})
	}
	return title, chunks
}

func stripFrontMatter(src string) (string, string) {
	if !strings.HasPrefix(src, "---\n") {
		return src, ""
	}
	rest := src[4:]
	end := strings.Index(rest, "\n---")
	if end < 0 {
		return src, ""
	}
	after := rest[end+4:]
	if after != "" && after[0] != '\n' {
		return src, "" // "----" or "---x": not a front matter terminator
	}
	block := rest[:end]
	title := ""
	if m := frontMatterTitle.FindStringSubmatch(block); m != nil {
		title = strings.TrimSpace(m[1])
	}
	return strings.TrimPrefix(after, "\n"), title
}

type headingPos struct {
	level     int
	title     string
	lineStart int // offset of the heading's first line
	bodyStart int // offset just after the heading (and setext underline)
}

func parseSections(src, fmTitle string) ([]section, string) {
	b := []byte(src)
	doc := goldmark.DefaultParser().Parse(text.NewReader(b))

	var heads []headingPos
	for n := doc.FirstChild(); n != nil; n = n.NextSibling() {
		h, ok := n.(*ast.Heading)
		if !ok || h.Lines().Len() == 0 {
			continue
		}
		first := h.Lines().At(0)
		last := h.Lines().At(h.Lines().Len() - 1)
		lineStart := strings.LastIndexByte(src[:first.Start], '\n') + 1
		lineEnd := indexByteFrom(src, '\n', last.Stop)
		bodyStart := lineEnd
		if !atxLine.MatchString(src[lineStart:lineEnd]) {
			// Setext heading: the next line is the === / --- underline.
			bodyStart = indexByteFrom(src, '\n', min(lineEnd+1, len(src)))
		}
		heads = append(heads, headingPos{
			level:     h.Level,
			title:     headingText(h, b),
			lineStart: lineStart,
			bodyStart: min(bodyStart+1, len(src)),
		})
	}

	preamblePath := fmTitle
	var sections []section
	firstEnd := len(src)
	if len(heads) > 0 {
		firstEnd = heads[0].lineStart
	}
	if pre := src[:firstEnd]; strings.TrimSpace(pre) != "" {
		if preamblePath == "" {
			preamblePath = "开头"
		}
		sections = append(sections, section{path: preamblePath, body: pre})
	}

	h1 := ""
	var stack []headingPos
	for i, h := range heads {
		if h.level == 1 && h1 == "" {
			h1 = h.title
		}
		for len(stack) > 0 && stack[len(stack)-1].level >= h.level {
			stack = stack[:len(stack)-1]
		}
		stack = append(stack, h)
		titles := make([]string, len(stack))
		for j, s := range stack {
			titles[j] = s.title
		}
		end := len(src)
		if i+1 < len(heads) {
			end = heads[i+1].lineStart
		}
		bodyStart := min(h.bodyStart, end)
		sections = append(sections, section{
			path:     strings.Join(titles, pathSep),
			headLine: strings.TrimRight(src[h.lineStart:indexByteFrom(src, '\n', h.lineStart)], " \t"),
			body:     src[bodyStart:end],
		})
	}
	return sections, h1
}

func indexByteFrom(s string, c byte, from int) int {
	if from >= len(s) {
		return len(s)
	}
	if i := strings.IndexByte(s[from:], c); i >= 0 {
		return from + i
	}
	return len(s)
}

func headingText(h *ast.Heading, src []byte) string {
	var sb strings.Builder
	_ = ast.Walk(h, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}
		if t, ok := n.(*ast.Text); ok {
			sb.Write(t.Segment.Value(src))
		}
		return ast.WalkContinue, nil
	})
	return strings.TrimSpace(sb.String())
}

// splitOversized breaks a section whose body exceeds MaxChars into pieces on
// block boundaries (blank lines outside fenced code). The limit is soft: a
// block shorter than MinChars (typically a short code sample) always stays with
// the text before it instead of becoming a stub chunk of its own.
func splitOversized(s section, opts ChunkOptions) []section {
	max := opts.MaxChars
	if utf8.RuneCountInString(s.body) <= max {
		return []section{s}
	}
	var out []section
	var cur strings.Builder
	first := true
	flush := func() {
		if strings.TrimSpace(cur.String()) == "" {
			cur.Reset()
			return
		}
		piece := section{path: s.path, body: cur.String()}
		if first {
			piece.headLine = s.headLine
			first = false
		}
		out = append(out, piece)
		cur.Reset()
	}
	for _, blk := range splitBlocks(s.body) {
		curLen, blkLen := utf8.RuneCountInString(cur.String()), utf8.RuneCountInString(blk)
		if curLen >= opts.MinChars && blkLen >= opts.MinChars && curLen+blkLen > max {
			flush()
		}
		if cur.Len() > 0 {
			cur.WriteString("\n\n")
		}
		cur.WriteString(blk)
	}
	flush()
	return out
}

// splitBlocks splits text on blank lines, keeping fenced code blocks intact.
func splitBlocks(body string) []string {
	var blocks []string
	var cur []string
	fence := ""
	flush := func() {
		if len(cur) > 0 {
			blocks = append(blocks, strings.Join(cur, "\n"))
			cur = nil
		}
	}
	for _, line := range strings.Split(body, "\n") {
		if m := fenceOpen.FindStringSubmatch(line); m != nil {
			marker := m[1]
			switch {
			case fence == "":
				fence = marker[:1]
			case strings.HasPrefix(marker, fence):
				fence = ""
			}
			cur = append(cur, line)
			continue
		}
		if fence == "" && strings.TrimSpace(line) == "" {
			flush()
			continue
		}
		cur = append(cur, line)
	}
	flush()
	return blocks
}

// mergeSmall folds short sections into the one that follows so that tiny
// subsections do not each become a chunk. A merged chunk keeps the later
// sections' heading lines inline and takes the common ancestor path.
func mergeSmall(units []section, opts ChunkOptions) []section {
	var out []section
	var cur *section
	flush := func() {
		if cur != nil {
			out = append(out, *cur)
			cur = nil
		}
	}
	for _, u := range units {
		if strings.TrimSpace(u.body) == "" {
			continue // heading-only section: its title lives on in child paths
		}
		if cur == nil {
			c := u
			cur = &c
			continue
		}
		addition := strings.TrimSpace(u.body)
		if u.headLine != "" {
			addition = u.headLine + "\n\n" + addition
		}
		curLen := utf8.RuneCountInString(cur.body)
		if curLen < opts.MinChars && curLen+utf8.RuneCountInString(addition) <= opts.MaxChars {
			cur.body = strings.TrimSpace(cur.body) + "\n\n" + addition
			cur.path = commonPath(cur.path, u.path)
			continue
		}
		flush()
		c := u
		cur = &c
	}
	flush()
	return out
}

func commonPath(a, b string) string {
	as, bs := strings.Split(a, pathSep), strings.Split(b, pathSep)
	n := 0
	for n < len(as) && n < len(bs) && as[n] == bs[n] {
		n++
	}
	if n == 0 {
		return a // unrelated roots: keep the first section's path
	}
	return strings.Join(as[:n], pathSep)
}

func usefulRunes(s string) int {
	n := 0
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			n++
		}
	}
	return n
}

func hashChunk(path, txt string) string {
	sum := sha256.Sum256([]byte(path + "\n" + txt))
	return hex.EncodeToString(sum[:])
}

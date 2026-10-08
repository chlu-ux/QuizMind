package agent

import "strings"

// linkFilter checks the lesson: and question: links in streamed Markdown. A link whose id the
// assistant never saw (from a tool result or the request's context) is invented, so the link is
// dropped and its label kept. Text is held back only while it could still be the start of a link.
type linkFilter struct {
	known func(id string) bool
	buf   string
}

const maxLink = 400

func (f *linkFilter) Write(s string) string {
	f.buf += s
	var out strings.Builder
	for {
		i := strings.IndexByte(f.buf, '[')
		if i < 0 {
			out.WriteString(f.buf)
			f.buf = ""
			return out.String()
		}
		out.WriteString(f.buf[:i])
		f.buf = f.buf[i:]

		j := strings.IndexByte(f.buf, ']')
		nl := strings.IndexByte(f.buf, '\n')
		switch {
		case nl >= 0 && (j < 0 || nl < j): // links do not span lines
			out.WriteString(f.buf[:nl+1])
			f.buf = f.buf[nl+1:]
			continue
		case j < 0:
			if len(f.buf) > maxLink {
				out.WriteString(f.buf[:1])
				f.buf = f.buf[1:]
				continue
			}
			return out.String()
		case j+1 == len(f.buf):
			return out.String() // wait to see whether "(" follows
		case f.buf[j+1] != '(':
			out.WriteString(f.buf[:j+1])
			f.buf = f.buf[j+1:]
			continue
		}
		k := strings.IndexByte(f.buf[j:], ')')
		if k < 0 {
			if len(f.buf) > maxLink {
				out.WriteString(f.buf[:j+1])
				f.buf = f.buf[j+1:]
				continue
			}
			return out.String()
		}
		k += j
		label, target := f.buf[1:j], f.buf[j+2:k]
		if id, ok := linkID(target); ok && !f.known(id) {
			out.WriteString(label)
		} else {
			out.WriteString(f.buf[:k+1])
		}
		f.buf = f.buf[k+1:]
	}
}

// Flush returns what is still held once the text has ended.
func (f *linkFilter) Flush() string {
	rest := f.buf
	f.buf = ""
	return rest
}

// linkID extracts the id of a lesson: or question: link target.
func linkID(target string) (string, bool) {
	for _, p := range []string{"lesson:", "question:"} {
		if strings.HasPrefix(target, p) {
			return strings.TrimSpace(strings.TrimPrefix(target, p)), true
		}
	}
	return "", false
}

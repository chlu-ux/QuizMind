package pipeline

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

// Question types supported in the current scope.
const (
	TypeSingle = "single"
	TypeJudge  = "judge"
)

// JudgeOptions are the fixed options of every judge question.
var JudgeOptions = []string{"正确", "错误"}

// ValidQuestion is a GeneratedQuestion that passed every deterministic rule,
// normalised and ready to store.
type ValidQuestion struct {
	Type        string
	Stem        string
	Options     []string
	AnswerIndex int
	Explanation string
	Difficulty  int
	Tags        []string
	SourceQuote string
	// Hash identifies the question's content for exact de-duplication.
	Hash string
}

const (
	minStemRunes    = 6
	maxStemRunes    = 300
	maxOptionRunes  = 200
	maxExplainRunes = 800
	minQuoteRunes   = 8 // measured after normalisation
	maxTags         = 3
	maxTagRunes     = 20
)

var (
	optionLabel = regexp.MustCompile(`^\s*[A-Da-d]\s*[\.\)、:：．）]\s*`)
	// Options that dodge the question instead of stating a claim. Matched
	// against the whole option (punctuation and spaces removed) so a normal
	// option that merely contains "都是" is not caught.
	catchAllOption = regexp.MustCompile(`^((以上|上述|所有|全部)(选项|说法|答案|内容)?[，,]?(都|均|皆|全)?(是)?(正确|对|错误|错|不正确|不对|不是)?的?|(都|均|皆|全)(正确|对|错误|错|不正确|不对|是|不是)|[a-d]([和与及、,，][a-d])+|alloftheabove|noneoftheabove)$`)
	// Stems that only make sense next to the excerpt.
	contextualStem = regexp.MustCompile(`(?i)(根据(上文|本文|文中|原文|以上|上述|材料)|文中(提到|说|指出)|上文|本文|本段|如上所述|the (text|passage|excerpt|article) (above|says)|according to the (text|passage|excerpt))`)
)

// ValidateQuestion applies the deterministic rules from the design doc: shape,
// bounds, and that source_quote really appears in chunkText. The error message
// is stored as the rejection reason, so keep it human-readable.
func ValidateQuestion(g GeneratedQuestion, chunkText string) (ValidQuestion, error) {
	v := ValidQuestion{
		Type:        strings.TrimSpace(g.Type),
		Stem:        strings.TrimSpace(g.Stem),
		AnswerIndex: g.AnswerIndex,
		Explanation: strings.TrimSpace(g.Explanation),
		SourceQuote: strings.TrimSpace(g.SourceQuote),
		Difficulty:  g.Difficulty,
	}

	if n := utf8.RuneCountInString(v.Stem); n < minStemRunes || n > maxStemRunes {
		return v, fmt.Errorf("stem length %d outside %d..%d", n, minStemRunes, maxStemRunes)
	}
	if contextualStem.MatchString(v.Stem) {
		return v, fmt.Errorf("stem refers to the source text instead of standing alone")
	}

	switch v.Type {
	case TypeSingle:
		opts, err := cleanSingleOptions(g.Options)
		if err != nil {
			return v, err
		}
		if v.AnswerIndex < 0 || v.AnswerIndex >= len(opts) {
			return v, fmt.Errorf("answer_index %d out of range for %d options", v.AnswerIndex, len(opts))
		}
		v.Options = opts
	case TypeJudge:
		if v.AnswerIndex != 0 && v.AnswerIndex != 1 {
			return v, fmt.Errorf("judge answer_index must be 0 or 1, got %d", v.AnswerIndex)
		}
		v.Options = append([]string(nil), JudgeOptions...)
	default:
		return v, fmt.Errorf("unsupported question type %q", g.Type)
	}

	if utf8.RuneCountInString(v.Explanation) > maxExplainRunes {
		return v, fmt.Errorf("explanation longer than %d characters", maxExplainRunes)
	}
	if v.Difficulty < 1 || v.Difficulty > 5 {
		v.Difficulty = 3
	}
	v.Tags = cleanTags(g.Tags)

	q := Normalize(v.SourceQuote)
	if utf8.RuneCountInString(q) < minQuoteRunes {
		return v, fmt.Errorf("source_quote too short to verify")
	}
	if !strings.Contains(Normalize(chunkText), q) {
		return v, fmt.Errorf("source_quote not found verbatim in the source excerpt (possible fabrication)")
	}

	v.Hash = ContentHash(v.Stem, v.Options)
	return v, nil
}

func cleanSingleOptions(raw []string) ([]string, error) {
	if len(raw) != 4 {
		return nil, fmt.Errorf("single question needs exactly 4 options, got %d", len(raw))
	}
	out := make([]string, 0, 4)
	seen := map[string]bool{}
	for i, o := range raw {
		o = strings.TrimSpace(optionLabel.ReplaceAllString(strings.TrimSpace(o), ""))
		if o == "" {
			return nil, fmt.Errorf("option %d is empty", i)
		}
		if utf8.RuneCountInString(o) > maxOptionRunes {
			return nil, fmt.Errorf("option %d longer than %d characters", i, maxOptionRunes)
		}
		if isCatchAll(o) {
			return nil, fmt.Errorf("option %d is a catch-all (%q)", i, o)
		}
		key := Normalize(o)
		if key == "" || seen[key] {
			return nil, fmt.Errorf("option %d duplicates another option", i)
		}
		seen[key] = true
		out = append(out, o)
	}
	return out, nil
}

func cleanTags(raw []string) []string {
	out := []string{}
	for _, t := range raw {
		t = strings.TrimSpace(t)
		if t == "" || utf8.RuneCountInString(t) > maxTagRunes {
			continue
		}
		out = append(out, t)
		if len(out) == maxTags {
			break
		}
	}
	return out
}

// isCatchAll reports whether the whole option is a dodge such as "以上都对".
func isCatchAll(o string) bool {
	compact := strings.ToLower(strings.Join(strings.Fields(o), ""))
	compact = strings.TrimRight(compact, "。.!！")
	return catchAllOption.MatchString(compact)
}

// Normalize reduces text to lower-case letters and digits (NFKC-folded) so that
// quote matching and de-duplication ignore whitespace, punctuation, full-width
// forms and Markdown markup.
func Normalize(s string) string {
	var b strings.Builder
	for _, r := range norm.NFKC.String(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(unicode.ToLower(r))
		}
	}
	return b.String()
}

// DedupeText is the text compared when looking for duplicate questions. It
// includes the options so generic stems ("which statement is correct?") are not
// mistaken for duplicates of each other.
func DedupeText(stem string, options []string) string {
	opts := make([]string, len(options))
	for i, o := range options {
		opts[i] = Normalize(o)
	}
	sort.Strings(opts)
	return Normalize(stem) + "|" + strings.Join(opts, "|")
}

// ContentHash is the exact-duplicate key for a question.
func ContentHash(stem string, options []string) string {
	sum := sha256.Sum256([]byte(DedupeText(stem, options)))
	return hex.EncodeToString(sum[:])
}

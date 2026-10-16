#!/usr/bin/env python3
"""Build the pattern code-completion bank from the case data in this folder.

    python3 build.py                 # write ../uml/pattern-*.svg and ../software-designer.t6-pattern-code.questions.json
    python3 build.py --check         # also compile + run every case with its answers (javac / clang++)
    python3 build.py --distractors   # also compile every wrong option and report the ones that behave like the answer

Only the standard library is used. The Java check needs a JDK (JAVAC / JAVA environment variables, or `javac` on PATH),
the C++ check needs clang++ or g++ with C++17.
"""
import argparse
import concurrent.futures as cf
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata

from common import CONCEPT_KINDS, HERE, KINDS, Blank, Code, Pattern, draw_diagram
import cases_create
import cases_struct
import cases_behave
import concepts
import lang

SRC = os.path.abspath(os.path.join(HERE, ".."))
LANGS = ("java", "cpp")
LECTURE = {lg: os.path.join(SRC, f"software-designer.t6-pattern-{lg}.md") for lg in LANGS}
QUESTIONS = {lg: os.path.join(SRC, f"software-designer.t6-pattern-{lg}.questions.json") for lg in LANGS}
CONCEPT_LECTURE = os.path.join(SRC, "software-designer.t6-pattern-concept.md")
CONCEPT_QUESTIONS = os.path.join(SRC, "software-designer.t6-pattern-concept.questions.json")
UML = os.path.join(SRC, "uml")
TITLE = {"java": "软件设计师（中级）下午题六（设计模式代码填空·Java）",
         "cpp": "软件设计师（中级）下午题六（设计模式代码填空·C++）"}
CONCEPT_TITLE = "软件设计师（中级）下午题六（设计模式概念）"
MARK = re.compile(r"@@(\d+)@@")

JAVA_FENCE, CPP_FENCE = "java", "cpp"
CPP_PRELUDE = ("#include <iostream>\n#include <string>\n#include <vector>\n#include <list>\n#include <map>\n"
               "#include <memory>\n#include <algorithm>\nusing namespace std;\n\n")


LIMIT = 50  # a phone shows about 38 monospace characters; longer one-line bodies are expanded
ACCESS = re.compile(r"^(public|private|protected):\s*")
CLASS_HEAD = re.compile(r"^(abstract\s+|final\s+|public\s+|private\s+|protected\s+|static\s+)*(class|interface|struct)\b")


def split_statements(inner):
    """Split `a; b; c;` at the top level (outside braces)."""
    out, depth, cur = [], 0, ""
    for ch in inner:
        cur += ch
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        elif ch == ";" and depth == 0:
            out.append(cur.strip())
            cur = ""
    if cur.strip():
        out.append(cur.strip())
    return out


def wrap_line(line, width):
    """Expand a one-line `head { body }` that is wider than LIMIT into several lines; `width` is its length once filled."""
    indent = len(line) - len(line.lstrip())
    body = line.strip()
    if width <= LIMIT or "{" not in body:
        return [line]
    i = body.index("{")
    head = body[:i].rstrip()
    if not (head.endswith(")") or CLASS_HEAD.match(head)):
        return [line]
    m = re.match(r"^(.*)\}(;?)$", body[i + 1:].rstrip())
    if not m or not m.group(1).strip():
        return [line]
    inner, semi = m.group(1).strip(), m.group(2)
    ind = " " * indent
    out = [ind + head + " {"]
    acc = ACCESS.match(inner)
    step = 4
    if acc:
        out.append(ind + acc.group(0).strip())
        inner = inner[acc.end():]
    for part in split_statements(inner):
        sub = ind + " " * step + part
        out.extend(wrap_line(sub, len(sub) + (width - len(line))))
    out.append(ind + "}" + semi)
    return out


def format_src(code):
    def measure(l):
        return len(MARK.sub(lambda m: code.blanks[int(m.group(1))].ans, l))
    out = []
    for l in code.src.split("\n"):
        out.extend(wrap_line(l, measure(l)))
    return "\n".join(out)


_formatted = []


def patterns():
    pats = cases_create.PATTERNS + cases_struct.PATTERNS + cases_behave.PATTERNS
    if not _formatted:
        for p in pats:
            p.java.src = format_src(p.java)
            p.cpp.src = format_src(p.cpp)
        _formatted.append(True)
    return pats


def normalize(s):
    s = unicodedata.normalize("NFKC", s)
    return "".join(ch.lower() for ch in s if ch.isalpha() or ch.isdigit())


def lecture_sections(lg):
    return lecture_sections_of(LECTURE[lg])


def code_head(p):
    """Section heading of a pattern in the Java / C++ lectures: T6.1 is the language syntax, the patterns follow."""
    return f"T6.{int(p.sec.split('.')[1]) - 1} {p.name}（{p.en}）"


def lecture_sections_of(path):
    text = open(path, encoding="utf-8").read()
    out = {}
    for part in re.split(r"(?m)^## ", text)[1:]:
        head, _, body = part.partition("\n")
        out[head.strip()] = body
    return out


def fill(code: Code, blank_at=None, wrong=None):
    """Source with every blank filled with its answer, except `blank_at`, which gets `wrong` (or a placeholder)."""
    def sub(m):
        n = int(m.group(1))
        if n == blank_at:
            return wrong if wrong is not None else "______"
        return code.blanks[n].ans
    return MARK.sub(sub, code.src)


def check_marks(p, lang_name, code):
    found = sorted(int(x) for x in MARK.findall(code.src))
    assert found == sorted(code.blanks), f"{p.key}/{lang_name}: markers {found} vs blanks {sorted(code.blanks)}"
    for n, b in code.blanks.items():
        opts = [b.ans] + list(b.wrong)
        assert len(opts) == 4 and len({o.strip() for o in opts}) == 4, f"{p.key}/{lang_name}#{n}: need 4 distinct options"
        assert b.kind in KINDS, b.kind


# ---------------------------------------------------------------------------------------------------------------
# compile and run
# ---------------------------------------------------------------------------------------------------------------
def find_javac():
    for cand in (os.environ.get("JAVAC"), shutil.which("javac"),
                 "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/javac"):
        if cand and os.path.exists(cand):
            r = subprocess.run([cand, "-version"], capture_output=True)
            if r.returncode == 0:
                return cand
    return None


def run_java(javac, code, text, tag):
    java = os.path.join(os.path.dirname(javac), "java")
    d = tempfile.mkdtemp(prefix="pc-java-")
    try:
        src = text + "\n\npublic class Main {\n    public static void main(String[] args) {\n" + code.main + "\n    }\n}\n"
        open(os.path.join(d, "Main.java"), "w", encoding="utf-8").write(src)
        r = subprocess.run([javac, "-encoding", "UTF-8", "-Xlint:none", "Main.java"], cwd=d, capture_output=True, text=True)
        if r.returncode:
            return False, r.stderr
        r = subprocess.run([java, "-cp", d, "Main"], capture_output=True, text=True, timeout=10)
        return r.returncode == 0, r.stdout if r.returncode == 0 else r.stderr
    finally:
        shutil.rmtree(d, ignore_errors=True)


def run_cpp(code, text, tag):
    cxx = shutil.which("clang++") or shutil.which("g++")
    d = tempfile.mkdtemp(prefix="pc-cpp-")
    try:
        src = CPP_PRELUDE + text + "\n\nint main() {\n" + code.main + "\n    return 0;\n}\n"
        open(os.path.join(d, "a.cpp"), "w", encoding="utf-8").write(src)
        r = subprocess.run([cxx, "-std=c++17", "-w", "a.cpp", "-o", "a.out"], cwd=d, capture_output=True, text=True)
        if r.returncode:
            return False, r.stderr
        r = subprocess.run([os.path.join(d, "a.out")], capture_output=True, text=True, timeout=10)
        return r.returncode == 0, r.stdout if r.returncode == 0 else r.stderr
    finally:
        shutil.rmtree(d, ignore_errors=True)


def run(lang_name, code, text, javac, tag):
    try:
        return run_java(javac, code, text, tag) if lang_name == "java" else run_cpp(code, text, tag)
    except subprocess.TimeoutExpired:
        return False, "timeout (probably an endless loop)"


def verify(pats, distractors):
    javac = find_javac()
    if not javac:
        sys.exit("no working javac: set JAVAC")
    jobs = []
    with cf.ThreadPoolExecutor(max_workers=6) as ex:
        for p in pats:
            for lg, code in (("java", p.java), ("cpp", p.cpp)):
                jobs.append((p, lg, code, None, None, ex.submit(run, lg, code, fill(code), javac, "")))
        bad = 0
        base = {}
        for p, lg, code, _, _, fut in jobs:
            ok, out = fut.result()
            if not ok:
                bad += 1
                print(f"FAIL {p.key}/{lg}:\n{out[:1500]}")
            base[(p.key, lg)] = out
        print(f"answers: {len(jobs) - bad}/{len(jobs)} cases compile and run")
        if distractors:
            jobs = []
            for p in pats:
                for lg, code in (("java", p.java), ("cpp", p.cpp)):
                    for n, b in code.blanks.items():
                        for w in b.wrong:
                            jobs.append((p, lg, n, w, ex.submit(run, lg, code, fill(code, n, w), javac, "")))
            alt = 0
            for p, lg, n, w, fut in jobs:
                ok, out = fut.result()
                if ok and out == base[(p.key, lg)]:
                    alt += 1
                    print(f"SAME  {p.key}/{lg} #{n}: {w!r} behaves like the answer")
            print(f"distractors: {len(jobs)} checked, {alt} indistinguishable from the answer")
        if bad:
            sys.exit(1)


# ---------------------------------------------------------------------------------------------------------------
# questions
# ---------------------------------------------------------------------------------------------------------------
MAX_STEM = 1900  # the server accepts up to 2000 characters for a stem with a code block (pipeline/validate.go)


def question(stem, ans, wrong, why, quote, diff, tags, rng_key):
    assert len(stem) <= MAX_STEM, f"{rng_key}: stem has {len(stem)} characters"
    if ans is True or ans is False:
        return {"type": "judge", "stem": stem, "options": ["正确", "错误"], "answer_index": 0 if ans else 1,
                "explanation": why, "difficulty": diff, "tags": tags, "source_quote": quote}
    opts = [ans] + list(wrong)
    random.Random(rng_key).shuffle(opts)
    return {
        "type": "single",
        "stem": stem,
        "options": opts,
        "answer_index": opts.index(ans),
        "explanation": why,
        "difficulty": diff,
        "tags": tags,
        "source_quote": quote,
    }


def make_stem(p, lg, code, n):
    fence = JAVA_FENCE if lg == "java" else CPP_FENCE
    name = "Java" if lg == "java" else "C++"
    tail = "代码省略了 #include 和 using namespace std;。" if lg == "cpp" else ""
    return (f"{code.scene}下面是用 {name} 实现的{p.name}模式，类图如下，代码中只有一处空缺。{tail}\n\n"
            f"![类图](uml/pattern-{p.key}{'-cpp' if lg == 'cpp' and p.diagram_cpp else ''}.svg)\n\n"
            f"```{fence}\n{fill(code, n).rstrip()}\n```\n\n"
            f"空缺处 ______ 应填入：")


def build(pats, lg):
    """The code-completion questions of one language, keyed by "title > section"."""
    sections = lecture_sections(lg)
    title = TITLE[lg]
    out = {}
    problems = 0

    def quote_ok(head, quote, what):
        nonlocal problems
        if normalize(quote) not in normalize(sections[head]):
            print(f"quote not in lecture: {what}: {quote}")
            problems += 1

    sec_head, qs = dict(lang.questions())[lg]
    if sec_head not in sections:
        print(f"missing lecture section: {sec_head}")
        problems += 1
    else:
        built = []
        for i, q in enumerate(qs):
            quote_ok(sec_head, q["quote"], f"{sec_head} #{i}")
            built.append(question(q["stem"], q["ans"], q.get("wrong", []), q["why"], q["quote"], q.get("diff", 2),
                                  ["下午题六", q["topic"], KINDS[q["kind"]]], f"{sec_head}/{i}"))
        out[f"{title} > {sec_head}"] = built
    for p in pats:
        head = code_head(p)
        if head not in sections:
            print(f"missing lecture section: {head}")
            problems += 1
            continue
        code = p.java if lg == "java" else p.cpp
        check_marks(p, lg, code)
        qs = []
        for n in sorted(code.blanks):
            b = code.blanks[n]
            quote_ok(head, b.quote, f"{p.key}/{lg}#{n}")
            qs.append(question(make_stem(p, lg, code, n), b.ans, b.wrong, b.why, b.quote, b.diff,
                               ["下午题六", p.name, KINDS[b.kind]], f"{p.key}/{lg}/{n}"))
        out[f"{title} > {head}"] = qs
    return out, problems


def concept_head(p):
    return f"C6.{int(p.sec.split('.')[1]) - 2} {p.name}（{p.en}）的概念"


def intro_lines(code_sections, p):
    """The intent and class-diagram lines of the pattern's code lecture, repeated at the top of its concept section."""
    body = code_sections[code_head(p)]
    keep = [l.strip() for l in body.split("\n") if l.startswith("**意图**") or l.startswith("**类图角色**")]
    return "\n\n".join(keep)


def build_concepts(pats):
    """Write the concept lecture and return its questions, keyed like the code questions."""
    code_sections = lecture_sections("java")
    lecture = [f"# {CONCEPT_TITLE}", ""]
    for p in pats:
        lecture += [f"## {concept_head(p)}", "", intro_lines(code_sections, p), "", concepts.CONCEPTS[p.key]["lecture"], ""]
    last = int(pats[-1].sec.split(".")[1]) - 2
    lecture += [f"## C6.{last + 1} {concepts.OVERVIEW_TITLE}", "", concepts.OVERVIEW_LECTURE, ""]
    with open(CONCEPT_LECTURE, "w", encoding="utf-8") as f:
        f.write("\n".join(lecture))
    sections = lecture_sections_of(CONCEPT_LECTURE)
    out, problems = {}, 0

    def add(head, items, topic_of):
        nonlocal problems
        norm = normalize(sections[head])
        built = []
        for i, c in enumerate(items):
            if normalize(c["quote"]) not in norm:
                print(f"quote not in concept lecture: {head} #{i}: {c['quote']}")
                problems += 1
            built.append(question(c["stem"], c["ans"], c["wrong"], c["why"], c["quote"], c["diff"],
                                  ["下午题六", topic_of, CONCEPT_KINDS[c["kind"]]], f"{head}/{i}"))
        out[f"{CONCEPT_TITLE} > {head}"] = built

    for p in pats:
        add(concept_head(p), concepts.CONCEPTS[p.key]["qs"], p.name)
    add(f"C6.{last + 1} {concepts.OVERVIEW_TITLE}", concepts.OVERVIEW, "设计模式总览")
    return out, problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--distractors", action="store_true")
    args = ap.parse_args()
    pats = patterns()
    for p in pats:
        draw_diagram(os.path.join(UML, f"pattern-{p.key}.svg"), f"{p.name}类图", **p.diagram)
        if p.diagram_cpp:
            draw_diagram(os.path.join(UML, f"pattern-{p.key}-cpp.svg"), f"{p.name}类图", **p.diagram_cpp)
    if args.check or args.distractors:
        verify(pats, args.distractors)
    built = [build(pats, lg) for lg in LANGS]
    cdata, cproblems = build_concepts(pats)
    problems = sum(b[1] for b in built) + cproblems
    if problems:
        sys.exit(f"{problems} problem(s); questions files not written")
    for path, d in [(QUESTIONS[lg], b[0]) for lg, b in zip(LANGS, built)] + [(CONCEPT_QUESTIONS, cdata)]:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print(f"{len(d)} sections, {sum(len(v) for v in d.values())} questions -> {os.path.relpath(path, SRC)}")


if __name__ == "__main__":
    main()

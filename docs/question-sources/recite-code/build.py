#!/usr/bin/env python3
"""Build software-designer.sNN-recite-*.questions.json from the q*.py modules and check them the way the server pipeline will.

    python3 build.py            write the 11 JSON files next to the lectures
    python3 build.py --check    only check

Checks (mirroring server/internal/pipeline/validate.go): stem / option / explanation lengths, four distinct options,
no catch-all options, `source_quote` found word for word in its section, at most 10 questions per section
(devseed asks for 10 per chunk), no section above the 1500-character chunk limit, no duplicate stems.
"""
import glob
import json
import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SRC = os.path.join(HERE, "..")

CODE_SYMBOLS = set("<>=:*&[]{}()+-/\\@#%^|~;")
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
MEMBER = re.compile(r"[A-Za-z0-9_]\.[A-Za-z_]")
CATCH_ALL = re.compile(r"^((以上|上述|所有|全部)(选项|说法|答案|内容)?[，,]?(都|均|皆|全)?(是)?(正确|对|错误|错|不正确|不对|不是)?的?|(都|均|皆|全)(正确|对|错误|错|不正确|不对|是|不是)|[a-d]([和与及、,，][a-d])+|alloftheabove|noneoftheabove)$")
CONTEXTUAL = re.compile(r"(根据(上文|本文|文中|原文|以上|上述|材料)|文中(提到|说|指出)|上文|本文|本段|如上所述)")


def normalize(s):
    s = unicodedata.normalize("NFKC", s)
    return "".join(c.lower() for c in s if c.isalpha() or c.isdigit())


def option_key(o):
    f = unicodedata.normalize("NFKC", o)
    if any(c in CODE_SYMBOLS for c in f) or IDENT.match(f.strip()) or MEMBER.search(f):
        return "".join(f.split())
    return normalize(o)


def lectures():
    """{chapter number: (path, h1, {section title: body})}"""
    out = {}
    for path in sorted(glob.glob(os.path.join(SRC, "software-designer.s[0-9][0-9]-recite-*.md"))):
        text = open(path, encoding="utf-8").read()
        h1 = text.split("\n", 1)[0][2:].strip()
        secs = {}
        for part in re.split(r"\n(?=## )", text)[1:]:
            head, _, body = part.partition("\n")
            secs[head[3:].strip()] = body.strip()
        num = int(re.search(r"\.s(\d\d)-", path).group(1))
        out[num] = (path, h1, secs)
    return out


def main():
    import importlib
    mods = [importlib.import_module(os.path.basename(p)[:-3])
            for p in sorted(glob.glob(os.path.join(HERE, "q[0-9][0-9].py")))]
    allq = {}
    for mod in mods:
        for title, qs in mod.SECTIONS.items():
            assert title not in allq, f"section defined twice: {title}"
            allq[title] = qs
    lec = lectures()
    known = {t for _, _, secs in lec.values() for t in secs}
    problems = []
    extra = [t for t in allq if t not in known]
    if extra:
        problems.append(f"questions for unknown sections: {extra}")

    counter, stems, total = 0, {}, 0
    for num, (path, h1, secs) in lec.items():
        result = {}
        for title, body in secs.items():
            qs = allq.get(title, [])
            if not qs:
                problems.append(f"[{title}] no questions")
            if len(body) > 1450:
                problems.append(f"[{title}] section is {len(body)} characters (chunk limit 1500)")
            if len(qs) > 10:
                problems.append(f"[{title}] {len(qs)} questions, devseed takes at most 10 per chunk")
            nbody = normalize(body)
            rows = []
            for q in qs:
                tag = f"[{title}] {q['stem'][:30]!r}"
                stem = q["stem"].strip()
                n = len(stem)
                if not 6 <= n <= 300:
                    problems.append(f"{tag} stem length {n}")
                if CONTEXTUAL.search(stem):
                    problems.append(f"{tag} stem refers to the text")
                if stem in stems:
                    problems.append(f"{tag} duplicate stem of [{stems[stem]}]")
                stems[stem] = title
                if len(q["why"]) > 800:
                    problems.append(f"{tag} explanation {len(q['why'])} characters")
                nq = normalize(q["quote"])
                if len(nq) < 8:
                    problems.append(f"{tag} quote too short")
                elif nq not in nbody:
                    problems.append(f"{tag} quote not found in section: {q['quote']!r}")
                if q["type"] == "judge":
                    options, ans = ["正确", "错误"], 0 if q["truth"] else 1
                else:
                    pos = counter % 4
                    counter += 1
                    options = list(q["wrongs"])
                    options.insert(pos, q["right"])
                    ans = pos
                    keys = [option_key(o) for o in options]
                    if len(set(keys)) != 4 or "" in keys:
                        problems.append(f"{tag} options not distinct: {options}")
                    for o in options:
                        if len(o) > 200 or CATCH_ALL.match("".join(o.lower().split()).rstrip("。.!！")):
                            problems.append(f"{tag} bad option {o!r}")
                chapter = re.sub(r"^软件设计师（中级）基础知识速记（|）$", "", h1)
                rows.append(dict(
                    type=q["type"], stem=stem, options=options, answer_index=ans, explanation=q["why"].strip(),
                    difficulty=q["d"], tags=["基础知识速记", chapter[:20], q["kind"]], source_quote=q["quote"].strip()))
            result[f"{h1} > {title}"] = rows
        n = sum(len(v) for v in result.values())
        total += n
        print(f"s{num:02d}  {n:3d} questions in {len(result)} sections")
        if "--check" not in sys.argv:
            out = path.replace(".md", ".questions.json")
            with open(out, "w", encoding="utf-8") as f:
                json.dump(result, f, ensure_ascii=False, indent=1)
                f.write("\n")
    print("total", total)
    # judge balance
    if problems:
        print("\nPROBLEMS:")
        for p in problems:
            print("  -", p)
        sys.exit(1)


if __name__ == "__main__":
    main()

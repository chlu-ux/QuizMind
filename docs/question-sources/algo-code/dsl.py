"""Tiny DSL for writing the hand-made algorithm questions (see build.py).

    S(stem, right, wrongs, why, quote, d=2, kind="概念")   single choice; `right` is placed at a rotating position
    J(stem, truth, why, quote, d=2, kind="概念")           true / false statement
    F(intro, code, right, wrongs, why, quote, d=3)         code completion; `@@` marks the blank in `code`

`quote` is a sentence that appears word for word in the lecture section (the pipeline checks it).
"""

BLANK = "______"


def S(stem, right, wrongs, why, quote, d=2, kind="概念"):
    assert len(wrongs) == 3, (stem, wrongs)
    return dict(type="single", stem=stem, right=right, wrongs=list(wrongs), why=why, quote=quote, d=d, kind=kind)


def J(stem, truth, why, quote, d=2, kind="判断"):
    return dict(type="judge", stem=stem, truth=bool(truth), why=why, quote=quote, d=d, kind=kind)


def F(intro, code, right, wrongs, why, quote, d=3, lang="c"):
    assert code.count("@@") == 1, intro
    stem = f"{intro}\n\n```{lang}\n{code.strip(chr(10)).replace('@@', BLANK)}\n```\n\n空缺处应填入："
    return dict(type="single", stem=stem, right=right, wrongs=list(wrongs), why=why, quote=quote, d=d, kind="填空")

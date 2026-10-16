"""Tiny DSL for the hand-made questions of the 速记 (recite) bank (see build.py).

    S(stem, right, wrongs, why, quote, d=2, kind="概念")   single choice; `right` is placed at a rotating position
    J(stem, truth, why, quote, d=2, kind="判断")           true / false statement

`quote` is a sentence or phrase that appears word for word (ignoring spaces, punctuation and Markdown marks)
in the lecture section; the pipeline checks it.
"""


def S(stem, right, wrongs, why, quote, d=2, kind="概念"):
    assert len(wrongs) == 3, (stem, wrongs)
    return dict(type="single", stem=stem, right=right, wrongs=list(wrongs), why=why, quote=quote, d=d, kind=kind)


def J(stem, truth, why, quote, d=2, kind="判断"):
    return dict(type="judge", stem=stem, truth=bool(truth), why=why, quote=quote, d=d, kind=kind)

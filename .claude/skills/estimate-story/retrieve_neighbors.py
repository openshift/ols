#!/usr/bin/env python3
"""Retrieve the k most similar past OLS stories (with their actual story points)
for a given story's text, using TF-IDF cosine similarity over story-corpus.jsonl.

Pure standard-library (no numpy/sklearn). Deterministic. Adds ~0 LLM tokens —
the estimator only ever sees the small JSON list this prints, never the corpus.

Usage:
  python retrieve_neighbors.py --summary "..." --description "..." [--k 5]
  python retrieve_neighbors.py --text "summary + description ..." [--k 5]

Prints a JSON array: [{"key","summary","sp","sim"}], most similar first.
"""
import argparse, json, math, os, re, collections

CORPUS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "story-corpus.jsonl")
STOP = set("the a an and or of to in for on with is are be this that it as by from at "
           "we should will can our your you i".split())


def toks(s):
    return [t for t in re.findall(r"[a-z0-9\-]+", (s or "").lower())
            if len(t) > 2 and t not in STOP]


def load_corpus():
    rows = []
    with open(CORPUS) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def build_index(rows):
    docs = []
    df = collections.Counter()
    for r in rows:
        blob = " ".join([r.get("summary", ""), r.get("description", ""),
                         " ".join(r.get("components", [])), " ".join(r.get("labels", []))])
        tk = toks(blob)
        docs.append(tk)
        df.update(set(tk))
    n = len(rows) or 1
    idf = {t: math.log(n / dfc) for t, dfc in df.items()}
    vecs = []
    for tk in docs:
        tf = collections.Counter(tk)
        v = {t: (1 + math.log(c)) * idf.get(t, 0.0) for t, c in tf.items()}
        nrm = math.sqrt(sum(x * x for x in v.values())) or 1.0
        vecs.append({t: x / nrm for t, x in v.items()})
    return idf, vecs


def query_vec(text, idf):
    tf = collections.Counter(toks(text))
    v = {t: (1 + math.log(c)) * idf.get(t, 0.0) for t, c in tf.items()}
    nrm = math.sqrt(sum(x * x for x in v.values())) or 1.0
    return {t: x / nrm for t, x in v.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", default="")
    ap.add_argument("--description", default="")
    ap.add_argument("--text", default="")
    ap.add_argument("--k", type=int, default=5)
    a = ap.parse_args()
    text = a.text or (a.summary + " " + a.description)

    rows = load_corpus()
    idf, vecs = build_index(rows)
    q = query_vec(text, idf)
    scored = []
    for r, v in zip(rows, vecs):
        s = sum(q.get(t, 0.0) * w for t, w in v.items())
        scored.append((s, r))
    scored.sort(key=lambda x: -x[0])
    out = [{"key": r["key"], "summary": r.get("summary", ""),
            "sp": r["sp"], "sim": round(s, 3)}
           for s, r in scored[:a.k]]
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()

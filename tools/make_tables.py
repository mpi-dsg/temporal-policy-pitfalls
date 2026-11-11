#!/usr/bin/env python3
"""Emit the verdict tables from captured engine output and the answer key.

The answer key is the only hand-written thing here. A position is undetermined
when an earlier refund's outcome never becomes visible in the history, either
because it returned an ::error or because nothing ever came back for it.
"""
import re, io, sys, os

TRACES = ["seq", "overlap", "error", "silence", "reapproval", "slide", "denied"]
HEAD   = {"seq":"seq","overlap":"overlap","error":"error","silence":"silence",
          "reapproval":"re-appr","slide":"slide","denied":"denied"}
REQUIRED = {"seq":"AD","overlap":"A?","error":"A?","silence":"A?",
            "reapproval":"AA","slide":"AA?","denied":"A?A"}
POLICIES = [
    ("1",  "1-count-responses",              "no refund `::response` is counted"),
    ("2",  "2-count-requests",               "no refund `::request` is counted"),
    ("3",  "3-offset-errors",                "`requests == errors + 1`, no responses"),
    ("3b", "3b-offset-errors-no-arithmetic", "rule 3 without arithmetic, one rule per retry"),
    ("4",  "4-since-request",                "no `::request` since the approval"),
    ("5",  "5-since-response",               "no `::response` since the approval"),
    ("6",  "6-count-approvals",              "`requests == approvals`"),
    ("7",  "7-approvals-plus-errors",        "`requests == errors + approvals`"),
    ("8",  "8-reversed-since",               "`requests with no later approval == 1`"),
]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def verdicts(policy_file, trace):
    path = os.path.join(ROOT, "results", "replays", f"{policy_file}--{trace}.txt")
    text = io.open(path, encoding="utf-8").read()
    return "".join("A" if v == "ALLOW" else "D"
                   for v in re.findall(r"\b(ALLOW|DENY)\b", text))

def wrong(got, req):
    return any(g != r for g, r in zip(got, req) if r != "?")

def render(got, req, nbsp):
    sep = {"nbsp": "&nbsp;", "space": " ", "none": ""}[nbsp]
    cell = sep.join(got)
    return f"**{cell}**" if wrong(got, req) else cell

def table(rows, nbsp="nbsp", files=False):
    sep = {"nbsp": "&nbsp;", "space": " ", "none": ""}[nbsp]
    cols = [HEAD[t] for t in TRACES]
    head = "| # | the policy admits a refund when |" + ("| file |" if files else "")
    out = []
    h = ["#", "admits a refund when"] + (["file"] if files else []) + cols
    out.append("| " + " | ".join(h) + " |")
    out.append("|" + "|".join([":--", ":--"] + ([":--"] if files else []) + [":--"] * len(cols)) + "|")
    key = ["", "*what the rule requires*"] + ([""] if files else []) \
          + [sep.join(REQUIRED[t]) for t in TRACES]
    out.append("| " + " | ".join(key) + " |")
    for label, pfile, desc in POLICIES:
        if label not in rows: continue
        cells = [render(verdicts(pfile, t), REQUIRED[t], nbsp) for t in TRACES]
        row = [label, desc] + ([f"`policies/{pfile}.dw`"] if files else []) + cells
        out.append("| " + " | ".join(row) + " |")
    return "\n".join(out)

def audit():
    bad = 0
    for label, pfile, _ in POLICIES:
        for t in TRACES:
            got, req = verdicts(pfile, t), REQUIRED[t]
            if len(got) != len(req):
                print(f"LENGTH {label} {t}: {got} vs key {req}"); bad += 1
    conv = {l: [t for t in TRACES if wrong(verdicts(f, t), REQUIRED[t])]
            for l, f, _ in POLICIES}
    clean = [l for l in conv if not conv[l]]
    if clean != ["5"]:
        print(f"CLEAN SET CHANGED: {clean}, expected policy 5 only"); bad += 1
    nq = sum(r.count("?") for r in REQUIRED.values())
    nb = sum(len(v) for v in conv.values())
    print(f"histories {len(TRACES)}  undetermined positions {nq}  bold cells {nb}  problems {bad}")
    for l in conv: print(f"  policy {l:>2} wrong on: {', '.join(conv[l])}")
    return bad

def latex(rows):
    """A fixed-width LaTeX table, so seven verdict columns cannot squeeze the
    description column into wrapping."""
    import re as _re

    def tt(d):
        d = d.replace("&", r"\&")
        return _re.sub(r"`([^`]*)`",
                       lambda m: r"\texttt{" + m.group(1).replace("_", r"\_") + "}", d)

    def cell(c):
        return r"\textbf{" + c.replace("**", "") + "}" if c.startswith("**") else c

    nl = r" \\"
    out = [r"\begin{center}", r"\small",
           r"\begin{tabular}{@{}r@{~}p{6.1cm}" + "c" * len(TRACES) + r"@{}}",
           r"\toprule",
           " & ".join(["", r"\textbf{admits a refund when}"]
                      + [r"\textbf{" + HEAD[t] + "}" for t in TRACES]) + nl,
           r"\midrule",
           " & ".join(["", r"\emph{what the rule requires}"]
                      + ["".join(REQUIRED[t]) for t in TRACES]) + nl,
           r"\addlinespace[2pt]"]
    for label, pfile, desc in POLICIES:
        if label not in rows:
            continue
        cells = [cell(render(verdicts(pfile, t), REQUIRED[t], "none")) for t in TRACES]
        out.append(" & ".join([label, tt(desc)] + cells) + nl)
    out += [r"\bottomrule", r"\end{tabular}", r"\end{center}"]
    return "\n".join(out)

if __name__ == "__main__":
    if "--audit" in sys.argv: sys.exit(1 if audit() else 0)
    which = sys.argv[1] if len(sys.argv) > 1 else "compact"
    if which == "compact": print(latex({"1","2","3","4","5","6","7"}))
    elif which == "readme": print(table({l for l,_,_ in POLICIES}, nbsp="nbsp"))
    elif which == "appendix": print(latex({l for l,_,_ in POLICIES}))
    elif which == "method": print(table({l for l,_,_ in POLICIES}, nbsp="space", files=True))

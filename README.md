# One approval, one refund

An AI agent handles customer refunds, and you want one rule to hold. A human approves a refund,
the agent issues that refund, and the approval is then spent. One approval, one refund, valid for
fifteen minutes. It is exactly the kind of rule that ought to be enforceable by a policy.

We wrote that rule nine ways in [Dogwood](https://github.com/dogwood-policy/dogwood), the temporal
policy language AWS shipped in August 2026 for agent authorization, then replayed all nine against
the Dogwood reference engine over seven event histories. Eleven of the sixteen refund decisions are
determined by the events the gateway has recorded. At those eleven, no policy authorizes a refund
the rule forbids, while eight of the nine refuse one it requires, at twenty-five decisions in all,
and six of those eight are reported clean by the toolchain. The failures do not go the way we
expected. One of the eight refuses every refund in the corpus.

This repository holds the material behind that summary, including the policies, the histories, the
captured engine output for all sixty-three replays behind the table, and a script that reruns every
one of them against your own build.

## Why the rule is hard to write

A policy gateway used to judge each request on its own. Dogwood changed that. A temporal policy
decides using the events that came before, so "this agent already spent its approval" becomes
something a policy can finally say. That is the feature and it is genuinely useful.

The difficulty is that the gateway sees a request before it sees what came of it. The gateway
records `::request` when a call is submitted, then `::response` or `::error` once the service behind
the gateway, the receiver, answers. This growing sequence of events is the history a policy reasons
over. Between those two events the refund is in flight, meaning it has been authorized and has not
yet settled, and it stays entirely invisible to any count of settled refunds. Your rule must decide
what to count, and all but one of the choices here is wrong in some history.

## The failure, concretely

Here is the first and most natural way to write the rule. Permit a refund when a human approved this
claim within the last fifteen minutes, and no refund for this claim has settled since:

```
permit (principal, action == Drupe::Action::"Refund", resource)
when temporal {
    formerly within 15m Drupe::Action::"Approve"::response{
        input.claimId: context.input.claimId, output.approved: true }
    && (count for (t: Timepoint). where (
        formerly within 15m (Drupe::Action::"Refund"::response{
            input.claimId: context.input.claimId } && tp(t))
    )) == 0
};
```

This is the accounting AWS's own `refund_budget_settled_plus_current` example calls more accurate,
on the stated grounds that "counting responses is also the more accurate accounting: a denied
refund does not consume budget."

On a well-behaved history it does exactly what you want. One approval, a refund that settles, then
a second attempt:

```
@0   Approve::response  claimId=c1 approved=true
@10  Refund::request    claimId=c1 amount=60   -> ALLOW
@11  Refund::response   claimId=c1 amount=60
@20  Refund::request    claimId=c1 amount=60   -> DENY
```

Now the agent retries at `@11`, a second before the first refund's response lands. The policy
text is identical, and only the arrival order has changed:

```
@0   Approve::response  claimId=c1 approved=true
@10  Refund::request    claimId=c1 amount=60   -> ALLOW
@11  Refund::request    claimId=c1 amount=60   -> ALLOW     <-- pays twice
@12  Refund::response   claimId=c1 amount=60
```

At `@11` no refund has settled, so the count is zero and the retry is permitted. In this history the
first refund did commit, and its response lands at `@12`, so the customer is paid $120 on a $60
claim, and the gateway authorized both requests, although validation had reported no errors and no
warnings.

The table below marks that decision `?` all the same. The history at `@11` cannot distinguish a
first refund that committed and lost its response from one that never ran, and those two cases need
opposite verdicts, so no verdict there can be graded wrong. The $120 follows from what the receiver
actually did rather than from anything the gateway had recorded, which is exactly why a test for
this rule has to read the receiver rather than the gateway's history.

Those two runs are `results/replays/1-count-responses--seq.txt` and `--overlap.txt`, produced by
the engine and committed here.

## Nine ways to write it

For each refund request the gateway returns a verdict, ALLOW or DENY. `A` is ALLOW and `D` is DENY,
one verdict per refund request in order. A `?` marks a decision the history leaves undetermined,
because an earlier refund against the same approval has no recorded outcome when the retry is
judged, so no verdict there is counted wrong. Five of the sixteen decisions are marked that way.
Cells holding a verdict that disagrees with the rule are bold.

| # | admits a refund when | seq | overlap | error | silence | re-appr | slide | denied |
|:--|:--|:--|:--|:--|:--|:--|:--|:--|
|  | *what the rule requires* | A&nbsp;D | A&nbsp;? | A&nbsp;? | A&nbsp;? | A&nbsp;A | A&nbsp;A&nbsp;? | A&nbsp;?&nbsp;A |
| 1 | no refund `::response` is counted | A&nbsp;D | A&nbsp;A | A&nbsp;A | A&nbsp;A | A&nbsp;**D** | A&nbsp;A&nbsp;A | A&nbsp;A&nbsp;**D** |
| 2 | no refund `::request` is counted | A&nbsp;D | A&nbsp;D | A&nbsp;D | A&nbsp;D | A&nbsp;**D** | A&nbsp;**D**&nbsp;D | A&nbsp;D&nbsp;**D** |
| 3 | `requests == errors + 1`, no responses | A&nbsp;D | A&nbsp;D | A&nbsp;A | A&nbsp;D | A&nbsp;**D** | A&nbsp;A&nbsp;A | A&nbsp;D&nbsp;**D** |
| 3b | rule 3 without arithmetic, one rule per retry | A&nbsp;D | A&nbsp;D | A&nbsp;A | A&nbsp;D | A&nbsp;**D** | A&nbsp;A&nbsp;A | A&nbsp;D&nbsp;**D** |
| 4 | no `::request` since the approval | **D**&nbsp;D | **D**&nbsp;D | **D**&nbsp;D | **D**&nbsp;D | **D**&nbsp;**D** | **D**&nbsp;**D**&nbsp;D | **D**&nbsp;D&nbsp;**D** |
| 5 | no `::response` since the approval | A&nbsp;D | A&nbsp;A | A&nbsp;A | A&nbsp;A | A&nbsp;A | A&nbsp;A&nbsp;A | A&nbsp;A&nbsp;A |
| 6 | `requests == approvals` | A&nbsp;D | A&nbsp;D | A&nbsp;D | A&nbsp;D | A&nbsp;A | A&nbsp;**D**&nbsp;D | A&nbsp;D&nbsp;**D** |
| 7 | `requests == errors + approvals` | A&nbsp;D | A&nbsp;D | A&nbsp;A | A&nbsp;D | A&nbsp;A | A&nbsp;A&nbsp;A | A&nbsp;D&nbsp;**D** |
| 8 | `requests with no later approval == 1` | A&nbsp;D | A&nbsp;D | A&nbsp;D | A&nbsp;D | A&nbsp;**D** | A&nbsp;**D**&nbsp;D | A&nbsp;D&nbsp;**D** |
| C | *correlated control, from a Dogwood author's constructions* | A&nbsp;D | A&nbsp;D | A&nbsp;D | A&nbsp;D | A&nbsp;A | A&nbsp;A&nbsp;D | A&nbsp;D&nbsp;A |

The seven histories: **seq**, a refund settles before the next is attempted. **overlap**, the second
request arrives before the first response. **error**, a refund returns `::error`. **silence**, a
refund is never answered at all, which is what a timeout or a dropped connection leaves behind.
**re-appr**, a refund succeeds and a second human approves. **slide**, a refund errors, a second
approval arrives once the window has moved, and the refund it authorizes is never answered.
**denied**, two refund requests overlap, the first settles, a second human approves, and one more
refund follows.

Seven of the nine validate with no errors and no warnings. Each of the two that use arithmetic draws
a single warning, and it concerns the arithmetic feature rather than the defect.

## Two regions, two remedies

The bold cells and the question marks are different problems, and a replay against the history can
answer only one of them.

**Bold cells are harm a test can catch.** The history fixes a right answer there, yet eight of nine
serious attempts at the rule miss it, at twenty-five decisions, while six of the eight validate with
no errors and no warnings. Every one of the twenty-five is a refusal of a refund the
rule requires. A suite that replays policies against what the receiver actually did would catch
every one.

**Question marks are harm no test against the history can catch.** An earlier refund's outcome never
became visible, so the history is identical whether the money moved or not, and those two outcomes
need opposite verdicts. There is no correct function from that history to a verdict, so we mark the
decision `?` and count no policy wrong at it.

That is not the same as nothing going wrong. At each of the five undetermined decisions the nine
policies split: two allow and seven deny on `overlap`, five and four on `error`, two and seven on
`silence`, five and four on `slide`, two and seven on `denied`. Whichever way the earlier refund
settled, exactly one of the two answers is wrong at each such request, and no replay against the
history can say which. The table is blind there by construction, and so is any replay built the same
way.

Row `C` shows what that costs. The correlated control is right at every determined decision, as is
policy 5, and at all five undetermined decisions the control denies while policy 5 allows. The
history cannot prefer either. Denial is conservative rather than correct. The control trades a
possible double refund for a possible unpaid claim every time, because the interface gives it
nothing better to go on, and policy 5 makes the opposite trade. A status endpoint at the receiver
would determine the undetermined decision in `error`, where the invocation terminated and the
outcome exists unreported. At the other four it would determine the decision whenever the earlier
refund has already settled, leaving it open only while that refund is still in flight.

## Three things go wrong

**Counting what settled permits double spending.** Policies 1 and 5 count settled refunds, so a
refund still in flight counts for nothing and a second one can be authorized against the same
approval. This is the walkthrough above.

**Counting what was requested charges the approval for a failure.** Policy 2 denies the overlapping
retry by counting requests, and a refund that errored then spends the approval anyway, even though
it may have committed nothing. A customer must then wait for a second human approval after nothing
worse than a dropped connection.

**Stating the rule directly denies everything.** Policy 4 says no refund request has occurred since
the approval, which is what the rule says in English. It denies every refund including the first,
because the engine appends the event under decision to the history before evaluating the policy
(`08-formal-specification.md` §6.1, A-Observe: `H' := H · e`), so the request thereby falsifies its
own condition. `probes/anchor-reachable.dw` is the probe for that, showing that the anchor and the
window behave as intended.

All three rest on one fact about the event model. The engine records a `::request` whatever
the verdict, and nothing removes it on DENY, so every policy here that counts requests inherits a
permanent charge for attempts the gateway refused. That is why no policy that counts requests gets the
`denied` column right, and why policy 5, which counts responses, is the only one of the nine that
does.

## The recording convention decides one of the nine

The table above holds for the way the reference engine handles a refusal, where the request stays in
the history and no outcome event is appended for it. The AgentCore developer guide documents a
different recording, under which a denied action is also written as an `error` event.

`traces/denied-error-on-deny.log` is the `denied` history with that extra event, and
`results/replays/*--denied-error-on-deny.txt` holds all nine policies replayed against it. Exactly
one verdict changes. Policy 7 goes from `A D D` to `A D A`, which is what the rule requires, so
policy 7 is right at every determined decision under the documented gateway convention and wrong
under the reference engine's.

    policy 7 on denied        reference engine   A D D
                              denial as error    A D A   <- correct

No other policy moves. The convention a given deployment actually implements therefore decides
whether one of these nine policies is correct, and nothing in the policy text changes between the
two runs.

## What we claim, and what we do not

We do not claim that no correct policy exists, and in fact a Dogwood author read an earlier version
of this table and showed us two constructions we had missed. A correlation field scopes a count to
one particular approval, and a `formerly` inside the body of a `count for ... where` makes the count
range over the correlated requests, which makes the rule expressible after all. We wrote that policy
and replayed it over the same seven histories, enriched so the refund names its approval. It
validates cleanly and is right at every determined decision, `denied` included, as is policy 5 of
the nine. Our own first attempt counted on the approval alone, so a denied refund for another claim
spent the approval anyway. Both versions, the two counterexamples, and the captured output are in
`control/`.

Our claim is narrower and, we think, more useful. An author reaching for this rule actually writes
these nine policies, including the accounting AWS's own documentation recommends. Validation accepts
them all, although eight of the nine are wrong on at least one history, with the failures differing
from one another, so an author gets no signal telling them reliably which one they have.

The recovered constructions also join on a correlation identifier that the request under decision
carries. Whether the rule holds must therefore depend on the interface supplying the history, and on
who may populate that identifier, as much as on the policy text.

## Why we built this

Our group works on what can happen when an authorization decision and the effect it authorizes come
apart. *Guarded Commits* ([arXiv:2610.00037](https://arxiv.org/abs/2610.00037)) measured that gap
over 271,035 traces from public agent workloads. *Atomix*
([arXiv:2602.14849](https://arxiv.org/abs/2602.14849)) closes it whenever a runtime fully mediates
every effect before commit. A policy gateway does not, since it intercepts only the request, while
the effect lands at a receiver it neither controls nor directly observes.

*Rubicon* (under review) asks what a mediator can promise at all given the capabilities the receiver
exposes, and scores a runtime against that limit. This repository is the smallest concrete thing we
could build to show what the same separation costs in a shipped authorization system.

## Reproducing

Dogwood reference engine v1.1.0, cloned from `github.com/dogwood-policy/dogwood` at commit
`4ec5e2c0`, built with rustc 1.99.1. Policies 3 and 7 need a build with
`--features experimental-arithmetic`, which is off by default and was marked experimental in the
language changelog on 2026-10-09. Everything replays in under a second.

```
./reproduce.sh /path/to/dogwood /path/to/dogwood-experimental-arithmetic /path/to/dogwood-language
```

The script replays every policy against every history and diffs the result against the committed
output, reporting `replays: 63   diffs: 0`, `convention: 9   diffs: 0`, `control: 9   diffs: 0`, and
`schema: 11   diffs: 0`. The third argument supplies the unpinned event schema. Without it the
script skips the schema block, and given only a default build it checks the other seven policies and
says which ones it skipped.

```
policies/    the nine candidates, numbered as in the table
traces/      the seven histories, named as the table's columns
schema/      the action schema
probes/      probes that isolate why a policy behaves as it does
results/     captured engine output, under replays/, validate/ and probes/
control/     the correlated positive control, its two counterexamples, and the
             captured output under both the pinned and the unpinned event schema
docs/        METHOD.md, the per-policy analysis and the scope limits
```

## Scope

These are fixed histories replayed against each policy rather than executions generated under
enforcement, so a history is not guaranteed to be reachable under every policy in the table, and
`docs/METHOD.md` says where that matters.

Everything here is replay against the reference engine, so we have not measured whether the live
AgentCore Gateway ingests these schedules and retains denied requests the same way.

A verdict comes from the policy and the event schema together, so every claim here names the schema
it holds under. All seven histories have a single principal, so the nine policies and the control
decide them identically under the pinned default and the unpinned schema. `control/README.md`
carries the case where that stops being true.

This is preliminary work and the policies are ours, so some of them are surely wrong in ways we have
not caught, which is precisely why we publish every captured replay rather than only the summary.
Issues and corrections are welcome, and we will gladly credit them here.

## License

MIT, see `LICENSE`. Dogwood itself is Apache-2.0 and is not vendored here but referenced by commit.
The policies, the schema, the histories, and the analysis are ours.

## Citing

Data Systems Group, Max Planck Institute for Software Systems. *One approval, one refund: nine
statements of a single temporal authorization rule, eight of them wrong somewhere.* Artifact, 2026.

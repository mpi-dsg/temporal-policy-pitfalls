# A correlated control, and what it took to get right

The nine candidates in the repository's main table are ours, and eight of the nine are wrong
somewhere. This directory holds a correlated positive control, built from the two constructions a
Dogwood author supplied after reading an earlier version of that table. A correlation field scopes
the count to one particular approval, and a `formerly` inside the body of a `count for ... where`
makes the count range over the correlated requests rather than every request in the window. The two
`formerly` expressions are conjoined, not nested one inside the other. An earlier version of this
file said otherwise.

This is a positive control rather than a correctness proof. It answers every determined decision in
these seven histories the way the rule requires, under both the pinned default and the unpinned
event schema, and we have not broken it since. That is a claim about this corpus rather than about
the policy in general, and the two counterexamples below show why it must be that narrow.

## The enriched schema

The refund here carries an `approvalId` naming the approval it spends, so the policy runs under
`control/schema.cedarschema` rather than the table's schema, and the seven histories in
`control/traces/` are the table's seven enriched to carry that field. The correlation the
constructions need changes the interface as well as the policy, so this is not an unchanged-input
comparison against the nine policies.

## Verdicts

| | seq | overlap | error | silence | re-appr | slide | denied |
|:--|:--|:--|:--|:--|:--|:--|:--|
| *what the rule requires* | A D | A&nbsp;? | A&nbsp;? | A&nbsp;? | A A | A&nbsp;A&nbsp;? | A&nbsp;?&nbsp;A |
| correlated | A D | A D | A D | A D | A A | A A D | A D A |

`denied` is the column no policy that counts requests gets right. At the five undetermined decisions
the control denies, which is the conservative choice rather than the correct one, since no
gateway-only policy can know whether the earlier refund committed.

## Both event schemas

A verdict comes from the policy and the event schema together. The pinned default hides events from
other principals, while the unpinned schema does not and warns in its own header that a policy "can
match events from any principal unless it explicitly constrains callerPrincipal." The control
constrains it, with `callerPrincipal: principal` in the approval match, and gives the verdicts above
under both.

`counterexamples/unpinned-unconstrained.dw` is the same policy with that one line removed, and
`counterexamples/cross-principal.log` is an approval granted to Bob and a refund requested by
Alice naming it:

    policy                          pinned   unpinned
    correlated (current)            DENY     DENY
    unpinned-unconstrained          DENY     ALLOW   <- Alice spends Bob's approval

`dogwood validate` reports the unconstrained variant clean under both schemas, so nothing in the
toolchain can catch the difference. Only the replay does.

## The defect we had to fix first

The first version of this policy counted refund requests on `approvalId` alone. There is enough in
`approvalId` to scope the count to one approval but not enough to scope it to one claim, so a refund
request for a *different* claim naming this approval was wrongly counted against it, including a
request the gateway denied. `counterexamples/wrong-claim.log` is a history where approval `a1` is
granted for claim `c1`, a refund for claim `c2` names `a1` and is correctly denied, and the
legitimate refund for `c1` is then denied too, against an approval nothing ever spent.

    counterexamples/unscoped-count.dw   DENY DENY   <- wrong at the second decision
    correlated (current)                DENY ALLOW

The fix adds `input.claimId` to the count body. We report this because it is the same defect the
table is about, found in the policy written to escape it. A denied attempt stays in the history and
is counted, and the request under decision supplies the join that decides what counts.

## Running it

    dogwood validate control/one-approval-one-refund-correlated.dw --policy-schema control/schema.cedarschema
    dogwood replay   control/one-approval-one-refund-correlated.dw --policy-schema control/schema.cedarschema --trace control/traces/<case>.log

Add `--event-schema <dogwood-language>/configuration/event-schemas/unpinned.dwschema` for the
unpinned run. `../reproduce.sh <dogwood> [<dogwood-exp>] [<dogwood-language>]` does all of it and
diffs against the committed output.

The control validates with no errors and no warnings on a default build. Captured output for all
seven histories under both schemas, and for both counterexamples, is in `control/results/`.

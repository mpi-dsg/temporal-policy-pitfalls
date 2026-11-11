# Can "one approval, one refund" be stated correctly?

Executed 2026-11-03 against the Dogwood open-source reference engine v1.1.0, cloned from
`github.com/dogwood-policy/dogwood` at commit `4ec5e2c0` and built with rustc 1.99.1.

    dogwood validate policies/<policy>.dw --policy-schema schema/refund.cedarschema
    dogwood replay   policies/<policy>.dw --policy-schema schema/refund.cedarschema --trace traces/<case>.log

We needed two builds, a default one and one compiled with `--features experimental-arithmetic`,
which policies 3 and 7 require. The feature is off by default and was marked experimental in the
language changelog on 2026-10-09. `results/validate/` records the result for each policy under both
builds, including the warning the experimental build emits.

All nine policies express exactly the same rule, that one human approval authorizes one refund for
the same claim, within fifteen minutes. They differ only in how they decide the approval is spent.

The gateway records events as they cross it, and that growing sequence of events is the history a
policy reasons over. The seven histories here use timestamps in seconds that increase strictly, as
the specification requires.
`Approve::response` and `Refund::response`/`::error` are history-only kinds and produce no decision
line, so each replay prints one line per refund request.

- `traces/seq.log`: refund 1 settles before refund 2 is attempted.
- `traces/overlap.log`: refund 2 is authorized before refund 1's response is ingested.
- `traces/error.log`: refund 1 is authorized and returns `::error`, then refund 2 is attempted.
- `traces/silence.log`: refund 1 is authorized and is never answered, then refund 2 is attempted.
- `traces/reapproval.log`: refund 1 succeeds, a second human approves, refund 2 is attempted.
- `traces/slide.log`: refund 1 errors, a second approval arrives fifteen minutes later, and two
  refunds follow, the first of which is never answered.
- `traces/denied.log`: two overlapping requests, one settles, a second human approves, one more refund.

These are fixed histories replayed against each policy rather than executions generated under
enforcement, which bounds what the table can be read to mean.
A history is therefore not guaranteed to be reachable under every policy in the table. For example,
`policies/4-since-request.dw` denies the first refund in every history, so the response events the
other policies produce could not occur under it. Replay is still the right instrument, because the
question is simply what each policy decides on a given history, and holding the history fixed makes
the policies comparable.
Where a policy's decision depends on an event it would itself have prevented, the README says so
explicitly.

## Result

For each refund request the gateway returns a verdict, ALLOW or DENY. `A` is ALLOW and `D` is DENY,
one verdict per refund request, in order. Verdicts that disagree with the rule are in bold. A `?`
marks a decision the history leaves undetermined, because an earlier refund's outcome never becomes
visible, having either errored or gone unanswered, so no verdict is marked wrong there.

| # | admits a refund when | file | seq | overlap | error | silence | re-appr | slide | denied |
|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|
|  | *what the rule requires* | | A D | A ? | A ? | A ? | A A | A A ? | A ? A |
| 1 | no refund `::response` is counted | `policies/1-count-responses.dw` | A D | A A | A A | A A | A **D** | A A A | A A **D** |
| 2 | no refund `::request` is counted | `policies/2-count-requests.dw` | A D | A D | A D | A D | A **D** | A **D** D | A D **D** |
| 3 | `requests == errors + 1`, no responses | `policies/3-offset-errors.dw` | A D | A D | A A | A D | A **D** | A A A | A D **D** |
| 3b | rule 3 without arithmetic, one rule per retry | `policies/3b-offset-errors-no-arithmetic.dw` | A D | A D | A A | A D | A **D** | A A A | A D **D** |
| 4 | no `::request` since the approval | `policies/4-since-request.dw` | **D** D | **D** D | **D** D | **D** D | **D** **D** | **D** **D** D | **D** D **D** |
| 5 | no `::response` since the approval | `policies/5-since-response.dw` | A D | A A | A A | A A | A A | A A A | A A A |
| 6 | `requests == approvals` | `policies/6-count-approvals.dw` | A D | A D | A D | A D | A A | A **D** D | A D **D** |
| 7 | `requests == errors + approvals` | `policies/7-approvals-plus-errors.dw` | A D | A D | A A | A D | A A | A A A | A D **D** |
| 8 | `requests with no later approval == 1` | `policies/8-reversed-since.dw` | A D | A D | A D | A D | A **D** | A **D** D | A D **D** |

The rows carry the same numbers used throughout this repository. Row 3b is the arithmetic-free
rewrite of row 3 and is identical to it on every history, while row 8 fails wherever row 6 does and
on one history more. Policies 3 and 7 need the `experimental-arithmetic` build, and the rest, row 3b
included, validate by default.

### Counting over a window (policies 1 to 3b)

**Counting responses admits double use under overlap.** At `@11` the second refund is authorized
while refund 1 has no response event yet, so the count of settled refunds is zero and a second
refund request goes through against one approval. That decision is undetermined, because the history
at `@11` cannot distinguish a first refund that committed from one that never ran, so no verdict
there can be graded wrong. In `traces/overlap.log` the first refund does commit, and its response
lands at `@12`, so the claim is actually paid twice. This is the accounting AWS's own shipped
`refund_budget_settled_plus_current` example recommends for refund budgets, although that example's
history settles every allowed request before the next decision point, so the idiom is simply never
exercised there against an overlapping history. The example promises a budget invariant rather than
single-use approval consumption, and these replays show that the same accounting does not preserve
that invariant when it is applied to a single-use rule.

**Counting requests denies the overlapping retry and charges the approval for a failure.** On the
`error` history policy 2 denies refund 2 after an error that may well have committed nothing,
because the engine records the request event unconditionally. That decision is undetermined too,
since the history never shows what the errored refund did, so the denial is merely the conservative
answer rather than a demonstrably correct one. This is the trade the two event-kind choices force on
an author.

**Treating errors as offsets needs an experimental feature.** `policies/3-offset-errors.dw` permits precisely when
one refund request is outstanding and none has succeeded. A default build rejects it with
`arithmetic in comparison operands is not yet supported` (`results/validate/3-offset-errors.txt`). A build with
`experimental-arithmetic` accepts it, warning once that the operators may change, and replays as row 3.
`policies/3b-offset-errors-no-arithmetic.dw` is the same accounting written without arithmetic, using one rule per tolerated
retry because the temporal sublanguage has no disjunction, and it gives identical verdicts on all
seven histories.

**All four fail on a second approval.** There is one history none of them survives. Give the same
claim a second human approval after a successful refund and every one of them denies the refund that
approval was granted for. A count ranges over refunds in a window, so a new approval simply cannot
restore a permission an earlier refund has already consumed.

### Anchoring to the approval (policies 4 and 5)

`since` anchors a condition to an event rather than to a window, and the guide's open-session idiom,
`!A since within W B`, is written for this shape (`04-temporal-expressions.md`, "Negated left").

**Policy 4 never permits anything.** It says that no refund request has been sent since the
approval, which is exactly what the rule says, and yet it denies every refund including the very
first one. The engine appends the event being decided to the history before computing the decision
(`08-formal-specification.md` §6.1, A-Observe: `H' := H · e` for every ingested `e`, observe runs
first), so the request under decision falsifies the negated left operand.
`probes/anchor-reachable.dw` is the probe for that. This probe uses the same policy shape with a
left operand that never occurs, and it allows every request, so the anchor is reachable and the
window is correct. At the first decision in each history no earlier refund request exists, so the
self-match is the only thing that can falsify the condition there, while at later decisions earlier
requests would falsify it too, which is a case the probe cannot separate.

**Policy 5 handles a second approval and is blind to a refund in flight.** Watching responses keeps
the decision from self-matching. Policy 5 cannot see a refund that has been authorized and has not
yet returned, so it authorizes two. This is the same blindness policy 1 has, produced by a different
construction.

### Rationing by approvals (policies 6 to 8)

These three came directly from reviewers asked to break the result. `policies/6-count-approvals.dw`
compares the refund-request count to the approval count rather than to a constant. Windows are
closed and reflexive, so the request under decision is already counted, and "one approval, one
refund" quietly becomes "as many refunds as approvals." It is count-to-count with no arithmetic, so
a default build accepts it readily. It is correct on every determined decision in five of the seven
histories, including both the overlap and the re-approve cases that defeat policies 1 to 5.

`policies/7-approvals-plus-errors.dw` adds an error term, `requests == errors + approvals`,
forgiving one retry per error. It needs the experimental feature, and after the window slides it
authorizes two refunds against the second approval, the later of them at a decision the history
leaves undetermined. `policies/8-reversed-since.dw` reverses the anchor, counting the refund
requests that have no successful approval after them and requiring exactly one. It parses on the
default build, which answers whether `since` can compose inside a `count` body, and it behaves much
like policy 2 on a fresh approval.

**Counting requests cannot tell a denied attempt from an authorized one.** A-Observe appends the
`::request` event before the decision and nothing removes it when the decision is DENY, so a request
the gateway refused is counted exactly like one it authorized. In `traces/denied.log` the attempt at
`@11` is one any correct policy denies, and it still raises the count permanently, so at `@110`,
after a settled refund and a second human approval, a policy that counts requests denies the refund
that approval was granted for. The counts rebalance only when the window slides, which can take
fifteen minutes. Every policy here that counts `::request` inherits that permanent charge, and no
policy that counts them gets the `denied` column right. Policy 5, which counts `::response`, is the
only one of the nine that does.

### What the table shows

The nine policies cover both event-kind choices, the direct statement of the rule, both uses of the
operator the guide recommends for it, and three candidates adversarial review produced. Eight of the
nine are demonstrably wrong on at least one of the seven histories, and the failures differ from one
another. At the eleven decisions the recorded events determine, no policy authorizes a refund the
rule forbids, and eight refuse one it requires, at twenty-five decisions in all. The dominant
failure here is wrongful refusal rather than wrongful authorization, which is the opposite of what
we expected when we started. The claim is about what an author writing this rule today gets, with no
analysis tooling that can tell them reliably which failure they have. A correct policy does exist
for this corpus, and `control/` holds it.

An earlier version of this file said that two constructions would change the result and that neither
existed. One was a way to count only the requests that were authorized, the other a way to scope a
count to an anchor event the way `since` scopes an absence. That was wrong. A Dogwood author
supplied constructions for both, and `control/` holds the resulting policy. We leave the correction
visible because the mistake is the same kind the table is about.

The engine emits authorization decisions and nothing more. Two ALLOW verdicts mean two refund
requests were authorized against one approval, and whether both actually reach a payment processor
depends entirely on the service behind the gateway, the receiver. Everything here is replay against
the reference engine, so we have not measured whether the live AgentCore Gateway ingests these
schedules and retains denied requests the same way.

### The event schema decides as much as the policy

The policy text and the event schema together produce a verdict, so a policy is never correct on its
own. The default pinned schema puts a symmetric pin on `callerPrincipal`, which
makes every temporal predicate see only the calling principal's events. The unpinned schema drops
the pin, and its own header says a policy "can match events from any principal unless it explicitly
constrains callerPrincipal."

We replayed every policy under both. On these seven histories the nine candidates and the control
give identical verdicts either way, because each history has a single principal. The difference
appears as soon as a history has a second principal, and `control/README.md` carries that case. A
variant of the control missing one line permits Alice to spend Bob's approval under the unpinned
schema while looking entirely correct under the default. `dogwood validate` reports that variant
clean under both schemas.

So every verdict claim in this repository names the schema it holds under, and no claim rests on the
default alone.

## Files

- `schema/refund.cedarschema`: the action schema for both actions.
- `policies/`: the nine candidates, numbered as in the table above. Each file's header comment
  names its row.
- `traces/`: the seven histories, named as the table's columns.
- `control/`: the correlated positive control, its enriched schema and histories, its
  counterexamples, and captured output under both event schemas. See `control/README.md`.
- `probes/anchor-reachable.dw`: the probe for policy 4's denial.
- `probes/arithmetic-1.dw` to `arithmetic-5.dw`: probes isolating which comparisons the default
  build rejects.
- `results/replays/<policy>--<trace>.txt`: one captured replay per cell of the table.
- `results/validate/<policy>.txt`: each policy validated under the build it requires.
- `results/probes/`: the probe outputs.

Every captured file opens with a `#` line recording the command that produced it. The engine does
not print that line, so `reproduce.sh` ignores it when diffing.

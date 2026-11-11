#!/usr/bin/env bash
# Replay every policy against every trace and diff the result against the
# output committed under results/.
#
#   ./reproduce.sh <dogwood> [<dogwood-with-experimental-arithmetic>] [<dogwood-language-dir>]
#
# Policies 3 and 7 need a build with --features experimental-arithmetic. Without
# a second binary those two are skipped, and the script says so.
#
# The third argument is a dogwood-language checkout, used to replay under the
# unpinned event schema as well as the pinned default. Without it the unpinned
# block is skipped, and the script says so.
#
# Committed output carries a leading "# <command>" line recording how it was
# produced. The engine does not print that line, so the diff ignores it.
set -uo pipefail

DW="${1:-}"
DW_EXP="${2:-}"
DW_LANG="${3:-}"
if [[ -z "$DW" ]]; then
    echo "usage: $0 <dogwood> [<dogwood-with-experimental-arithmetic>] [<dogwood-language-dir>]" >&2
    exit 2
fi

cd "$(dirname "$0")"
SCHEMA=schema/refund.cedarschema
TRACES=(seq overlap error silence reapproval slide denied)
UNPINNED_REL=configuration/event-schemas/unpinned.dwschema
UNPINNED=""
if [[ -n "$DW_LANG" ]]; then
    UNPINNED="$DW_LANG/$UNPINNED_REL"
    [[ -f "$UNPINNED" ]] || { echo "no $UNPINNED; unpinned replays will be skipped" >&2; UNPINNED=""; }
fi

# policy stem -> needs the experimental-arithmetic build
declare -a POLICIES=(
    "1-count-responses:no"
    "2-count-requests:no"
    "3-offset-errors:yes"
    "3b-offset-errors-no-arithmetic:no"
    "4-since-request:no"
    "5-since-response:no"
    "6-count-approvals:no"
    "7-approvals-plus-errors:yes"
    "8-reversed-since:no"
)

fail=0; ran=0; skipped=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

for entry in "${POLICIES[@]}"; do
    IFS=: read -r stem needs_exp <<<"$entry"
    bin="$DW"
    if [[ "$needs_exp" == "yes" ]]; then
        if [[ -z "$DW_EXP" ]]; then
            echo "SKIP  $stem (needs the experimental-arithmetic build)"
            skipped=$((skipped + ${#TRACES[@]})); continue
        fi
        bin="$DW_EXP"
    fi
    for t in "${TRACES[@]}"; do
        want="results/replays/${stem}--${t}.txt"
        [[ -f "$want" ]] || { echo "SKIP  $want (nothing committed)"; skipped=$((skipped+1)); continue; }
        "$bin" replay "policies/${stem}.dw" --policy-schema "$SCHEMA" \
               --trace "traces/${t}.log" >"$tmp/got" 2>&1
        ran=$((ran + 1))
        if diff -q <(grep -v '^#' "$want") "$tmp/got" >/dev/null; then
            echo "ok    $want"
        else
            echo "DIFF  $want"
            diff -u <(grep -v '^#' "$want") "$tmp/got" | sed 's/^/        /'
            fail=$((fail + 1))
        fi
    done
done

# The AgentCore guide records a denied action as an `error`; the reference engine does not.
# Replaying `denied` under that convention flips exactly one policy, which is the point.
conv_ran=0; conv_fail=0
for entry in "${POLICIES[@]}"; do
    IFS=: read -r stem needs_exp <<<"$entry"
    bin="$DW"
    if [[ "$needs_exp" == "yes" ]]; then
        [[ -z "$DW_EXP" ]] && { skipped=$((skipped+1)); continue; }
        bin="$DW_EXP"
    fi
    want="results/replays/${stem}--denied-error-on-deny.txt"
    [[ -f "$want" ]] || { echo "SKIP  $want (nothing committed)"; skipped=$((skipped+1)); continue; }
    "$bin" replay "policies/${stem}.dw" --policy-schema "$SCHEMA" \
           --trace traces/denied-error-on-deny.log >"$tmp/got" 2>&1
    conv_ran=$((conv_ran + 1))
    if diff -q <(grep -v '^#' "$want") "$tmp/got" >/dev/null; then
        echo "ok    $want"
    else
        echo "DIFF  $want"
        diff -u <(grep -v '^#' "$want") "$tmp/got" | sed 's/^/        /'
        conv_fail=$((conv_fail + 1))
    fi
done

cran=0; cfail=0
for t in "${TRACES[@]}"; do
    want="control/results/correlated--${t}.txt"
    [[ -f "$want" ]] || { echo "SKIP  $want (nothing committed)"; skipped=$((skipped+1)); continue; }
    "$DW" replay control/one-approval-one-refund-correlated.dw \
           --policy-schema control/schema.cedarschema \
           --trace "control/traces/${t}.log" >"$tmp/got" 2>&1
    cran=$((cran + 1))
    if diff -q <(grep -v '^#' "$want") "$tmp/got" >/dev/null; then
        echo "ok    $want"
    else
        echo "DIFF  $want"
        diff -u <(grep -v '^#' "$want") "$tmp/got" | sed 's/^/        /'
        cfail=$((cfail + 1))
    fi
done

for pair in "counterexamples/unscoped-count.dw:unscoped-count" "one-approval-one-refund-correlated.dw:correlated"; do
    IFS=: read -r pol stem <<<"$pair"
    want="control/results/${stem}--wrong-claim.txt"
    [[ -f "$want" ]] || { echo "SKIP  $want (nothing committed)"; skipped=$((skipped+1)); continue; }
    "$DW" replay "control/${pol}" --policy-schema control/schema.cedarschema \
           --trace control/counterexamples/wrong-claim.log >"$tmp/got" 2>&1
    cran=$((cran + 1))
    if diff -q <(grep -v '^#' "$want") "$tmp/got" >/dev/null; then
        echo "ok    $want"
    else
        echo "DIFF  $want"; cfail=$((cfail + 1))
    fi
done

# The pinned default hides events from other principals, so a policy can be
# correct under it and still permit cross-principal approval theft under the
# unpinned schema. Both are replayed, and the unsafe variant is kept beside the
# control to show the difference.
uran=0; ufail=0
if [[ -n "$UNPINNED" ]]; then
    for t in "${TRACES[@]}"; do
        want="control/results/correlated--${t}--unpinned.txt"
        [[ -f "$want" ]] || { echo "SKIP  $want (nothing committed)"; skipped=$((skipped+1)); continue; }
        "$DW" replay control/one-approval-one-refund-correlated.dw \
               --policy-schema control/schema.cedarschema \
               --event-schema "$UNPINNED" \
               --trace "control/traces/${t}.log" >"$tmp/got" 2>&1
        uran=$((uran + 1))
        if diff -q <(grep -v '^#' "$want") "$tmp/got" >/dev/null; then
            echo "ok    $want"
        else
            echo "DIFF  $want"
            diff -u <(grep -v '^#' "$want") "$tmp/got" | sed 's/^/        /'
            ufail=$((ufail + 1))
        fi
    done
    for pair in "one-approval-one-refund-correlated.dw:correlated" \
                "counterexamples/unpinned-unconstrained.dw:unpinned-unconstrained"; do
        IFS=: read -r pol stem <<<"$pair"
        for variant in "" "--unpinned"; do
            want="control/results/${stem}--cross-principal${variant}.txt"
            [[ -f "$want" ]] || { echo "SKIP  $want (nothing committed)"; skipped=$((skipped+1)); continue; }
            if [[ -n "$variant" ]]; then
                "$DW" replay "control/${pol}" --policy-schema control/schema.cedarschema \
                       --event-schema "$UNPINNED" \
                       --trace control/counterexamples/cross-principal.log >"$tmp/got" 2>&1
            else
                "$DW" replay "control/${pol}" --policy-schema control/schema.cedarschema \
                       --trace control/counterexamples/cross-principal.log >"$tmp/got" 2>&1
            fi
            uran=$((uran + 1))
            if diff -q <(grep -v '^#' "$want") "$tmp/got" >/dev/null; then
                echo "ok    $want"
            else
                echo "DIFF  $want"
                diff -u <(grep -v '^#' "$want") "$tmp/got" | sed 's/^/        /'
                ufail=$((ufail + 1))
            fi
        done
    done
else
    echo "SKIP  unpinned replays (no dogwood-language checkout given)"
fi

echo
echo "replays: $ran   diffs: $fail   skipped: $skipped"
echo "convention: $conv_ran   diffs: $conv_fail"
echo "control: $cran   diffs: $cfail"
echo "schema:  $uran   diffs: $ufail"
[[ $fail -eq 0 && $conv_fail -eq 0 && $cfail -eq 0 && $ufail -eq 0 ]] || exit 1

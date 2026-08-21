#!/usr/bin/env bash
# Gate for samples/tour — cajeta-coco's consumer tour.
#
# It asserts what the tour is FOR, not merely that it ran: the tour exists to
# produce one instance of every finding coco can report, so a run that produces
# only some of them is a regression even when it exits 0. Each check below names
# the class the tour plants for that finding.
#
# Deliberately NOT wired into run-tests.sh: this takes two ~80s front-end passes
# plus a mutation pass, and it resolves dev.cajeta.coverage from Olla rather
# than from this checkout. That is the point — it measures the PUBLISHED plugin,
# so it is a release check, not an edit-loop check.
set -euo pipefail
cd "$(dirname "$0")/../samples/tour"

CAJETA="${CAJETA:-cajeta}"
OUT=build/coco

"$CAJETA" cover
"$CAJETA" mutate

fail() { echo "check-tour: $1" >&2; exit 1; }
have() { grep -q "$1" "$2" || fail "$3"; }

[ -f "$OUT/sites.tsv" ]   || fail "no site table — instrument did not complete"
[ -f "$OUT/link.tsv" ]    || fail "no link.tsv — mutate cannot replay the link line"
[ -f "$OUT/crap.tsv" ]    || fail "no crap.tsv — the Risk tab would be empty"
[ -f "$OUT/mutation.tsv" ]|| fail "no mutation.tsv — mutate did not complete"

# Dead vs untested: the distinction coco exists for.
have 'Dead code'                 "$OUT/coverage.html" "LegacyPricing is not reported as dead code"
have 'Reachable but never tested' "$OUT/coverage.html" "Coupon.isExpired is not reported as untested"

# Risk: the rate table must outrank the two-line predicate, or CRAP is doing
# nothing a flat uncovered-list would not.
head -2 "$OUT/crap.tsv" | tail -1 | grep -q 'TaxTable.rateBasisPoints' \
    || fail "TaxTable.rateBasisPoints is not top of the CRAP queue"

# Attribution: a redundancy candidate, and the framework's own tests excluded.
have 'unique=0' "$OUT/attribution.tsv" "no redundancy candidate — is the test package still excluded?"

# Mutation: exactly the planted survivor, and Pricing's identical mutation killed.
grep -q 'Shipping.*SURVIVED'      "$OUT/mutation.tsv" || fail "Shipping.rateCents' mutant did not survive"
grep -q 'Pricing.*killed'         "$OUT/mutation.tsv" || fail "Pricing.discountCents' mutant was not killed"

echo "check-tour: every planted finding reported"

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

# The plugin is AOT-compiled by the toolchain that runs it, and 0.21.0
# miscompiles coco's file reads — every verb then throws `uncaught exception
# (value=0x3)` from whichever method reads a file first. Refuse up front: that
# stack names coco and blames the wrong thing.
#
# 0.25.0 raises the floor again, and this one is a HARD requirement rather than
# a miscompile: `Pipeline.instrumentLink` adds `build/exe/__cajeta_session_stub.c`
# to its link line unconditionally, because the compiler drops that file beside
# the exe and a caller building its own link line has to take it. The compiler
# only started emitting it in 70ef31ae, which landed ELEVEN HOURS AFTER v0.24.0
# was tagged — so on 0.24.0 or older the file does not exist and the link fails
# on a missing input, which is a worse failure than the undefined
# `__cajeta_install_hook` it was added to fix.
#
# 0.29.0 does NOT raise it, and the reason is worth writing down because the
# instinct was to raise it. The probe runtime ships as BITCODE inside the
# published archive (`cajeta/coco/rt/Probe.bc`, `ProbeDump.bc`) and is lowered
# and linked against the CONSUMER's stdlib, so an archive is only as portable as
# the symbols its bitcode names. 0.6.0 was cut by 0.25.0, whose bitcode calls
# `__cajeta_drop_entry_flag`; v0.28.0 deleted that symbol with the
# ownership-title-classifier work, so 0.6.0 cannot link on 0.28.0 or newer at
# all. 0.6.1 is the re-cut. Its bitcode names only
# __cajeta_drop_mark_inactive, __cajeta_drop_pop_run, __cajeta_drop_push_debug
# and __cajeta_return_flag_set, all of which have been in the runtime since
# 0.25.0 — so the floor stays where it is, and this gate was run green on both
# 0.28.0 and 0.29.0 to prove it. Re-cut coco on every toolchain that moves the
# drop runtime, and check this list before assuming an old floor still holds.
ver="$("$CAJETA" --version 2>/dev/null | awk '{print $2}')"
case "$ver" in
    0.[0-9].*|0.1?.*|0.2[0-4].*) echo "check-tour: cajeta $ver is too old — coco needs 0.25.0+ (its link line takes __cajeta_session_stub.c, which only 0.25.0 emits)" >&2; exit 1 ;;
esac

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

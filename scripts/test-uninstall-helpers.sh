#!/usr/bin/env bash
# Tests for the size-reporting helpers in scripts/uninstall.sh.
#
# uninstall.sh cannot be run for real to check what it prints -- running it
# removes Wyn, and the Wine tree it deletes takes hours to rebuild. So the parts
# worth trusting are functions, and this exercises them by sourcing the script
# with WYN_UNINSTALL_LIB=1, which defines them and stops before it inspects or
# removes anything.
#
# Run: ./scripts/test-uninstall-helpers.sh
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# shellcheck source=./uninstall.sh
WYN_UNINSTALL_LIB=1 . "$ROOT/scripts/uninstall.sh"

passed=0
failed=0
GIB=1073741824

ok() {
  passed=$((passed + 1))
  printf '  ok    %s\n' "$1"
}

bad() {
  failed=$((failed + 1))
  printf '  FAIL  %s\n' "$1" >&2
}

expect_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi
}

expect_warns() {
  if shortfall_is_significant "$2" "$3"; then ok "$1"; else bad "$1 (expected a warning)"; fi
}

expect_quiet() {
  if shortfall_is_significant "$2" "$3"; then bad "$1 (warned when it should not)"; else ok "$1"; fi
}

echo
echo "human_gb"
expect_eq "rounds to one decimal"      "$(human_gb $((34 * GIB)))" "34.0"
expect_eq "zero is zero, not blank"    "$(human_gb 0)"             "0.0"
expect_eq "no argument is zero"        "$(human_gb)"               "0.0"
expect_eq "half a gig"                 "$(human_gb $((GIB / 2)))"  "0.5"

echo
echo "shortfall_is_significant"
# The case this whole change exists for: a parked bottle shares every block
# with the live one, so a 34 GB removal returns nothing.
expect_warns "clone freed nothing"                  $((34 * GIB)) 0
expect_warns "clone freed a fraction"               $((34 * GIB)) $((4 * GIB))
expect_quiet "a healthy uninstall is silent"        $((34 * GIB)) $((34 * GIB))
expect_quiet "rounding noise is silent"             $((34 * GIB)) $((33 * GIB))
# Under a quarter short: real, but not worth a warning on its own.
expect_quiet "a fifth short is still silent"        $((20 * GIB)) $((17 * GIB))
# Proportion alone is not enough, or a --keep-bottles run that frees a few
# hundred MB less than estimated would lecture about APFS. Both sides of the
# 1 GiB floor, because the floor is the part that is easy to get wrong.
expect_quiet "under the 1 GiB floor stays quiet"    $((GIB - 1))  0
expect_warns "2 GB that frees nothing does warn"    $((2 * GIB))  0
expect_quiet "nothing was being removed"            0             0
# Freed more than promised (something else on the Mac released space at the
# same time). Not a shortfall.
expect_quiet "freed more than estimated"            $((10 * GIB)) $((12 * GIB))

echo
echo "volume_free_bytes"
free_now="$(volume_free_bytes)"
if [[ "$free_now" =~ ^[0-9]+$ ]] && (( free_now > 0 )); then
  ok "returns a positive byte count ($(human_gb "$free_now") GB free)"
else
  bad "returns a positive byte count (got '$free_now')"
fi

# It has to notice real change, or the reclaimed figure is decoration. Write a
# file, read the volume again, remove it. 256 MiB is big enough to clear df's
# 1 KiB granularity and any background noise, small enough to be polite.
probe="$(mktemp -d "$HOME/.wyn-free-probe.XXXXXX")" || probe=""
if [[ -n "$probe" ]]; then
  before="$(volume_free_bytes)"
  if mkfile 256m "$probe/probe.bin" 2>/dev/null; then
    after="$(volume_free_bytes)"
    dropped=$(( before - after ))
    # Allow generous slack in both directions: other processes write too.
    if (( dropped > 200 * 1024 * 1024 )); then
      ok "sees 256 MiB appear (free space fell by $(human_gb "$dropped") GB)"
    else
      bad "sees 256 MiB appear (free space fell by $dropped bytes)"
    fi
  else
    bad "could not write the probe file"
  fi
  rm -rf "$probe"
fi

echo
if (( failed > 0 )); then
  echo "$failed failed, $passed passed" >&2
  exit 1
fi
echo "$passed passed"

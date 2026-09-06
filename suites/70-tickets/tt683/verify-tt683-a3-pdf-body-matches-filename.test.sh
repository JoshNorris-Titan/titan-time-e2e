#!/usr/bin/env bash
# TT-683 angle 3 — each PDF in the archive CONTAINS the consultant and project
# its filename claims.
#
# tt-timeout: 6m
#
# WHY THIS EXISTS, GIVEN a1 AND a2 ALREADY PASS. Between them they establish that
# the archive holds one entry per consultant/project pairing, that the names
# follow the agreed standard, that the bytes really are PDFs, and that no two
# entries share a CRC-32. Every one of those can hold while the documents are
# wrong. Filenames come from PDFMonthHelper/FileName, set per helper by
# Main.SUB_BuildTimesheetFileName, so they are right whatever the render did --
# the pre-TT-683 defect was precisely correct names wrapped around the wrong
# body, because Main.ACT_PDF_GoTo ignored its context object and fetched the
# newest helper.
#
# a1's CRC check catches that only in its most degenerate form. Identical
# renders are identical bytes, so an export that put the SAME consultant in
# every PDF for the SAME week is caught. Put that consultant in every PDF for
# DIFFERENT weeks -- which is what a helper-lookup bug returning the wrong
# consultant but the right date range produces -- and the bytes differ, the CRCs
# differ, and a1 goes green on an export where nobody's hours are in their own
# file. Nothing in this suite opens a PDF, so nothing sees it. That is the gap
# this closes, and it is the swap check a checksum cannot make.
#
# WHAT IS ASSERTED, per entry:
#   1. the PDF yields text at all (a render that produced a blank page is not a
#      pass, and is reported as its own distinct failure rather than as a
#      missing name);
#   2. the consultant named in the FILENAME appears in the BODY;
#   3. the project named in the filename appears in the body;
#   4. an hours figure is present, so the document is a timesheet and not a
#      header with an empty grid.
#
# And across entries, the assertion that actually matters:
#   5. no PDF contains what DISTINGUISHES a different entry from it. This is
#      the swap check, and if it cannot be performed this step FAILS rather
#      than passing. run-tests.sh prints a step's output only when it fails, so
#      a note saying "this did not run" would be a message nobody ever sees --
#      in a suite whose central finding was assertions that quietly assert
#      nothing. Having not run the check, this file has no verdict to give.
#
# THE DISCRIMINATOR IS NOT ALWAYS THE CONSULTANT, and assuming it was would have
# turned a correct nightly red. An entry is a consultant+project PAIRING, and
# verify-tt683-a0 guarantees two distinct pairings reach export -- but its own
# remedy is "assign the consultant to at least two projects", so the ordinary
# seeded case is ONE consultant holding TWO projects. There, the other entry's
# consultant appears in this PDF entirely legitimately, and testing for it would
# report a swap on a perfectly good export. So each ordered pair uses whichever
# half actually differs: the consultant when the consultants differ, otherwise
# the project. A pair whose only differing half nests inside this one is not
# usable in that direction and is counted as skipped.
#
# THE NAME TRANSFORM, AND WHY IT IS NOT A LOOSE MATCH. The filename carries the
# consultant as "Last First" (Main.SUB_BuildTimesheetFileName swaps them); the
# body prints the account's FullName as stored. So "Consultant E2E" in the name
# is "E2E Consultant" in the body, and "Two E2E Consultant" is "E2E Consultant
# Two". The transform is exact -- move the first token to the end -- and both
# forms are accepted, because which one a future change settles on is not this
# test's business. What is NOT accepted is a partial match on one token: every
# e2e consultant shares the token "E2E", and "Consultant" appears in the page
# furniture ("Consultant:"), so a substring check on a single word would pass on
# any PDF whatsoever. Whole-name matching is what makes step 5 real.
#
# PARSING THE FILENAME. {yyyy}-{MMdd}-{Last First}-{Project}.pdf. The consultant
# is the third dash-separated field and the project is EVERYTHING after the
# third dash, because a project name may legitimately contain a dash. A
# consultant name containing one would break this, and would break
# verify-tt683-a2 the same way; no account in the fixtures has one.
#
# WHERE THE ARCHIVE COMES FROM. The one verify-tt683-a1 already downloaded, whose
# path it parks in TT683_ZIP_STATE -- the same reuse verify-tt683-a2 does, and
# for the same reason: Export All is destructive and consumes the AwaitingExport
# batch, so driving a second export here would find nothing left and report it as
# a product failure. Unlike a2 this does NOT fall back to its own export. If the
# archive is not there the honest answer is that this step could not run, not a
# fresh export whose data a1 has already eaten.
#
# REQUIRES pdftotext (poppler-utils). If it is missing this step FAILS rather
# than skipping: a silently-skipped security-adjacent check is indistinguishable
# from a passing one in the summary, and this suite has already been bitten by
# assertions that could not fail. Add it to ci-skip.txt deliberately if an
# environment genuinely cannot have it.
#
# Reads only. Extracts into a temp directory it removes on exit. Drives no
# browser and needs no login -- it works on the archive a1 left on disk.
#
# Env: none of its own.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"

command -v pdftotext >/dev/null 2>&1 \
  || tt_fail "pdftotext is not installed, so the PDFs cannot be read. This step will not report a pass it did not earn - install poppler-utils, or put this basename in ci-skip.txt if the environment genuinely cannot have it."

ZIPPATH="$(_tt683_zip_path 2>/dev/null)" \
  || tt_fail "no export archive is on disk. verify-tt683-a1 captures it and parks the path in .tt683-zip.path; run the tt683 steps in order. This step deliberately does NOT drive its own export - a1 consumes the AwaitingExport batch, so a second one would find nothing and look like a product bug."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MAP="$(python "$TT683_ZIPREPORT" "$ZIPPATH" extract "$WORK" 2>"$WORK/.err")" || {
  tt_fail "could not extract $ZIPPATH: $(head -1 "$WORK/.err" 2>/dev/null)"
}
[ -n "$MAP" ] || tt_fail "extracting $ZIPPATH produced no entries"

echo "archive: $ZIPPATH"

# consultant_body_form <last-first> — the name as the PDF body prints it.
# "Consultant E2E" -> "E2E Consultant"; "Two E2E Consultant" -> "E2E Consultant Two".
consultant_body_form() {
  local first rest
  first="${1%% *}"
  rest="${1#* }"
  if [ "$rest" = "$1" ]; then printf '%s' "$1"; else printf '%s %s' "$rest" "$first"; fi
}

# Collect per entry: name, consultant (filename form), body form, project, text file.
names=(); consultants=(); bodyforms=(); projects=(); textfiles=()

while IFS= read -r line; do
  [ -n "$line" ] || continue
  entry="${line%%~~*}"
  file="${line#*~~}"

  base="${entry%.pdf}"
  rest="${base#*-}"        # drop yyyy
  rest="${rest#*-}"        # drop MMdd
  consultant="${rest%%-*}" # third field
  project="${rest#*-}"     # everything after it

  if [ "$consultant" = "$rest" ] || [ -z "$project" ] || [ "$project" = "$rest" ]; then
    echo "FAIL: '$entry' does not parse as {yyyy}-{MMdd}-{Last First}-{Project}.pdf,"
    echo "      so there is no claim in the filename to check the body against."
    echo "      verify-tt683-a2 owns the naming standard; fix that failure first."
    exit 1
  fi

  txt="$WORK/$(printf '%s' "$entry" | tr -c 'A-Za-z0-9' '_').txt"
  pdftotext -layout "$file" "$txt" 2>/dev/null || true
  if [ ! -s "$txt" ]; then
    echo "FAIL: '$entry' yielded no text at all."
    echo "      The entry is a readable PDF (verify-tt683-a1 checks that), so this is a"
    echo "      document that rendered blank rather than one with the wrong contents."
    echo "      Main.ACT_PDF_GoTo produced a page with no timesheet on it."
    exit 1
  fi

  names+=("$entry")
  consultants+=("$consultant")
  bodyforms+=("$(consultant_body_form "$consultant")")
  projects+=("$project")
  textfiles+=("$txt")
done <<< "$MAP"

n="${#names[@]}"
echo "$n PDF(s) extracted and read"

fails=0

# ------------------------------------------------- 1-4. each PDF says who it is for
for i in $(seq 0 $((n - 1))); do
  entry="${names[$i]}"
  body="$(cat "${textfiles[$i]}")"
  ok=1

  if ! printf '%s' "$body" | grep -qF "${bodyforms[$i]}" \
     && ! printf '%s' "$body" | grep -qF "${consultants[$i]}"; then
    echo "FAIL: '$entry' does not name its own consultant."
    echo "      The filename claims '${consultants[$i]}' (body form '${bodyforms[$i]}'),"
    echo "      and neither spelling appears anywhere in the document text."
    ok=0
  fi

  if ! printf '%s' "$body" | grep -qF "${projects[$i]}"; then
    echo "FAIL: '$entry' does not name its own project '${projects[$i]}'."
    ok=0
  fi

  if ! printf '%s' "$body" | grep -qE '[0-9]+\.[0-9][0-9]'; then
    echo "FAIL: '$entry' carries no hours figure, so it is a header with no timesheet under it."
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    echo "  OK  $entry -> names '${bodyforms[$i]}' and '${projects[$i]}'"
  else
    fails=$((fails + 1))
  fi
done

# ------------------------------------------------------------ 5. the swap check
# Only meaningful between entries whose consultants actually differ, AND whose
# names do not nest.
#
# THE NESTING TRAP, which this check walked straight into on its first run.
# "E2E Consultant Two" CONTAINS "E2E Consultant". So asking whether Two's PDF
# mentions "E2E Consultant" is answered yes by Two's own name being printed on
# it, and that ordered pair can never pass however correct the export is. The
# first version of this reported a swap on a perfectly good archive.
#
# The pair is skipped in that direction only. The opposite direction -- does the
# shorter name's PDF contain the longer name -- carries no such guarantee and is
# still conclusive, so a nested pair still gets checked one way rather than
# being dropped. Skipped directions are counted and reported, because "checked
# nothing" and "checked and found nothing" must not look alike.
pairs=0
nested=0
swap_fails=0
for i in $(seq 0 $((n - 1))); do
  for j in $(seq 0 $((n - 1))); do
    [ "$i" = "$j" ] && continue

    # What distinguishes entry j from entry i? An entry IS a consultant+project
    # pairing, so either half can be the discriminator, and only a half that
    # actually DIFFERS may be used: when one consultant holds two projects, j's
    # consultant appears in i's PDF entirely legitimately, and testing for it
    # would report a swap on a correct export.
    #
    # A discriminator is also unusable when j's value nests inside i's, because
    # then i's own header contains it whatever the render did -- see the note
    # above about "E2E Consultant Two" containing "E2E Consultant".
    disc=""
    if [ "${bodyforms[$i]}" != "${bodyforms[$j]}" ]; then
      case "${bodyforms[$i]}" in
        *"${bodyforms[$j]}"*) : ;;
        *) disc="${bodyforms[$j]}" ;;
      esac
    fi
    if [ -z "$disc" ] && [ "${projects[$i]}" != "${projects[$j]}" ]; then
      case "${projects[$i]}" in
        *"${projects[$j]}"*) : ;;
        *) disc="${projects[$j]}" ;;
      esac
    fi

    if [ -z "$disc" ]; then
      nested=$((nested + 1))
      continue
    fi

    pairs=$((pairs + 1))
    if grep -qF "$disc" "${textfiles[$i]}"; then
      echo "FAIL: '${names[$i]}' also contains '$disc', which belongs to '${names[$j]}'."
      echo "      One assignment's document is rendering another's. The filenames are"
      echo "      built per helper and would be correct either way, and the two files differ"
      echo "      in bytes, so neither verify-tt683-a1's CRC check nor verify-tt683-a2's"
      echo "      naming check can see this. Main.ACT_PDF_GoTo is resolving the wrong"
      echo "      Main.PDFMonthHelper for its context object."
      fails=$((fails + 1))
      swap_fails=$((swap_fails + 1))
    fi
  done
done

if [ "$pairs" -eq 0 ]; then
  # A SKIPPED SWAP CHECK IS A FAILURE HERE, not a note.
  #
  # run-tests.sh prints a step's output only when it fails, so on a pass this
  # would have been a message nobody ever sees, in a suite whose central finding
  # was assertions that quietly assert nothing. The cross-contamination check is
  # the reason this file exists -- the per-entry checks above are worth having but
  # they cannot tell one consultant's document from another's. Having not run it,
  # this step has no verdict to report, and says so in the only way CI can hear.
  echo "FAIL: the cross-contamination check had no conclusive pair and did NOT run"
  echo "      ($n entr(y/ies) in the archive, $nested direction(s) skipped as nested names)."
  echo "      It needs two entries whose consultants differ and do not nest. This is"
  echo "      almost certainly an upstream problem rather than a bug in the export:"
  echo "      verify-tt683-a0 is what guarantees two distinct consultant/project"
  echo "      pairings reach AwaitingExport, and verify-tt683-a1 asserts the archive"
  echo "      keeps them apart. Fix those first - passing here without this check"
  echo "      would be reporting a swap test that never compared anything."
  fails=$((fails + 1))
elif [ "$swap_fails" -eq 0 ]; then
  echo "  OK  no PDF contains another entry's consultant ($pairs ordered pair(s) checked, $nested skipped as nested)"
fi

[ "$fails" -eq 0 ] || exit 1
echo "PASS: verify-tt683-a3-pdf-body-matches-filename - all $n PDF(s) contain the consultant, project and hours their filename claims"

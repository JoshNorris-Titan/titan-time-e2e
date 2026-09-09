#!/usr/bin/env bash
# tt-timeout: 12m
# verify-tt706-sent-print.test.sh
#
# TT-706 - "Option to be able to print previously Sent timesheets". HR selects a
# week on the SENT tab, presses Print, and gets a real PDF for it.
#
# WHY THIS EXISTS. TT-706 closed on 2026-08-17 with no coverage of any kind. It
# is the only route to a document for work that has ALREADY been exported: the
# monthly export (TT-683) reads AwaitingExport entries and will never see these
# again, so if btnSentPrint broke, the answer to "send me that timesheet again"
# would quietly become "we cannot". Nothing else in the suite touches the Sent
# tab except verify-hr-sent-consultant-sorted, which only checks a dropdown's
# order.
#
# WHAT PRINT ACTUALLY DOES, read from the model rather than guessed:
#   Main.ACT_PrintWeekSent_HRDash guards twice ("Week selected?", "Entries
#   found?"), builds one Main.PDFMonthHelper per entry through the same
#   SUB_BuildMonthHelpers / SUB_BuildTimesheetFileName pair the monthly export
#   uses, and then SHOWS Main.ExportAll_Waiting - the identical download page.
#   So the artefact arrives the same way the TT-683 archive does, which is why
#   this reuses lib/_tt683.sh's capture wholesale instead of inventing a second
#   download path.
#
# WHAT IT ASSERTS
#   A. A Sent week can be selected and Print is offered on it.
#   B. Pressing Print reaches the download page rather than one of the two
#      "nothing to print" messages.
#   C. The download is a REAL PDF - opened and read, not just named .pdf - and
#      D. its text names the consultant whose week was printed.
#
# C AND D MATTER MORE THAN THEY LOOK. A DocGen failure returns an HTML error page
# with a PDF's filename and a plausible size, and Main.ACT_PDF_GoTo has shipped a
# bug before where it ignored its context object and rendered SOMEBODY ELSE's
# hours under the right name (see verify-tt683-a3, which exists for that reason).
# Asserting the filename alone would pass on both.
#
# REQUIRES pdftotext (poppler-utils), like verify-tt683-a3. If it is missing this
# FAILS rather than skipping: a pass this step did not earn is worse than a red.
#
# WHERE THE DATA COMES FROM. The Sent tab holds Exported entries, which is what
# suites/70-tickets/tt683/ produces by exporting - and tt683 sorts before tt706,
# so by the time this runs the tab is populated. It prints an EXISTING week and
# changes nothing, so it consumes nothing and can run twice.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"

TAB="SENT"
CNAME="${TT_TT706_CONSULTANT:-E2E Consultant}"
WORK="${TMPDIR:-/tmp}/tt706-$$"

command -v pdftotext >/dev/null 2>&1 \
  || tt_fail "pdftotext is not installed, so the printed document cannot be read. This step will not report a pass it did not earn - install poppler-utils, or put this basename in ci-skip.txt if the environment genuinely cannot have it."

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK"

# ---------------------------------------------------------------- 1. the tab
tt_login "e2e_hr" "WEEKLY TO PROCESS"
tt_click_text "$TAB" "HR '$TAB' tab"
tt_wait_for "$TT_HR_GAL_WEEKS" "'$TAB' available-weeks list"

WEEKS="$(tt683_toprocess_weeks)"   # reads TT_HR_GAL_WEEKS, whichever tab is open
[ -n "$WEEKS" ] && [ "$WEEKS" != "null" ] \
  || tt_fail "the $TAB tab offers no weeks at all. It lists Exported entries, which suites/70-tickets/tt683/ produces by exporting - if that folder failed, this has nothing to print and the failure to fix is there, not here."

# Find a week that actually holds a card for our consultant. Printing a week that
# belongs to somebody else would still produce a PDF, and assertion D would then
# fail while blaming the wrong thing.
FOUND=""
IFS_SAVE="$IFS"
IFS='|'
for wk in $WEEKS; do
  [ -n "$wk" ] || continue
  IFS="$IFS_SAVE"
  playwright-cli eval "() => { const g=document.querySelector('$TT_HR_GAL_WEEKS'); if(!g) return 'nf'; const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$wk')===0); if(el){ el.click(); return 'ok'; } return 'nf'; }" >/dev/null 2>&1
  sleep 3
  if playwright-cli eval "() => String((((document.querySelector('.mx-name-galSentEntries')||{}).innerText)||'').indexOf('$CNAME') >= 0)" 2>/dev/null | grep -qiw true; then
    FOUND="$wk"; break
  fi
  IFS='|'
done
IFS="$IFS_SAVE"

[ -n "$FOUND" ] \
  || tt_fail "no $TAB week holds a card for '$CNAME'. Weeks offered: $WEEKS. The Sent tab only ever shows Exported entries, so this means nothing of this consultant's has been exported yet in this run."
echo "  printing $TAB week '$FOUND' (holds a '$CNAME' card)"

# ------------------------------------------------- 2. Print reaches the page
playwright-cli eval "() => { const b=document.querySelector('.mx-name-btnSentPrint'); if(!b) return 'missing'; if(b.disabled) return 'disabled'; b.click(); return 'clicked'; }" 2>/dev/null | _tt_eval_str | grep -qiw clicked \
  || tt_fail "btnSentPrint was not clickable on the $TAB tab. It is the only control TT-706 added, so if it is absent the feature is gone rather than broken."
sleep 4

# Main.ACT_PrintWeekSent_HRDash ends at Main.ExportAll_Waiting when it has
# something to print, and at a Show message when it does not. Distinguish the two
# rather than timing out on the download button: "no week selected" and "no
# entries found" are different diagnoses from "the export page never painted".
reached=""
for _ in $(seq 1 25); do
  state="$(playwright-cli eval "() => { const b=[...document.querySelectorAll('button')].filter(e=>e.offsetParent!==null).find(e=>/zip|download|print/i.test(e.innerText||'')); if(b) return 'page'; const d=document.querySelector('.mx-dialog,.mx-window,[role=dialog]'); if(d) return 'dialog:' + ((d.innerText||'').replace(/\s+/g,' ').trim().slice(0,120)); return 'waiting'; }" 2>/dev/null | _tt_eval_str)"
  case "$state" in
    page) reached=1; break ;;
    dialog:*) tt_fail "Print stopped at a message instead of the download page: ${state#dialog:}. Main.ACT_PrintWeekSent_HRDash shows one when no week is selected or no entries are found - but a week WAS selected above and it holds a '$CNAME' card, so this is the guard firing when it should not." ;;
  esac
  sleep 2
done
[ -n "$reached" ] || tt_fail "Print neither opened the download page nor raised a message within 50s"
echo "  Print reached the download page"

# ------------------------------------------------------ 3. capture the file
# tt683_download_zip_entries clicks the download control and reads back what the
# browser saved. On this route the artefact may be a single PDF rather than an
# archive, so its ZIP parse is allowed to fail and the saved file is inspected
# directly - _tt683_downloaded_path reports whatever was last written either way.
tt683_download_zip_entries >"$WORK/entries.txt" 2>"$WORK/dl.err" || true
FILE="$(_tt683_downloaded_path)" \
  || tt_fail "the download control was pressed but the browser saved no file. Network log tail: $(playwright-cli requests --static 2>/dev/null | tail -4 | tr '\n' ' ')"
BYTES="$(wc -c < "$FILE" | tr -d ' ')"
echo "  downloaded: $FILE ($BYTES bytes)"
[ "$BYTES" -gt 1000 ] || tt_fail "the downloaded file is only $BYTES bytes, which is too small to be a rendered timesheet - that size is what a DocGen error page weighs"

# ------------------------------------------- 4. it is a PDF, and it is OURS
PDFS=""
case "$(head -c 4 "$FILE")" in
  "%PDF")
    cp "$FILE" "$WORK/printed.pdf"; PDFS="$WORK/printed.pdf" ;;
  "PK"*)
    python "$TT683_ZIPREPORT" "$FILE" extract "$WORK/zip" >/dev/null 2>&1 \
      || tt_fail "the download is a ZIP that could not be extracted: $(head -1 "$WORK/dl.err" 2>/dev/null)"
    PDFS="$(find "$WORK/zip" -type f -name '*.pdf' | tr '\n' ' ')"
    [ -n "$PDFS" ] || tt_fail "the download is a ZIP containing no PDF at all: $(find "$WORK/zip" -type f | tr '\n' ' ')" ;;
  *)
    tt_fail "the downloaded file is neither a PDF nor a ZIP - it begins [$(head -c 8 "$FILE" | tr -d '\0')]. An HTML error page with a PDF's filename is exactly what a failed render produces." ;;
esac

hit=""
for pdf in $PDFS; do
  txt="$pdf.txt"
  pdftotext -layout "$pdf" "$txt" 2>/dev/null || true
  [ -s "$txt" ] || { echo "  (no text in $(basename "$pdf") - a blank render)"; continue; }
  if grep -qiF "$CNAME" "$txt"; then hit="$pdf"; break; fi
  # The filename form is "Last First"; the body may carry either order.
  last="${CNAME##* }"; first="${CNAME%% *}"
  if grep -qiF "$last" "$txt" && grep -qiF "$first" "$txt"; then hit="$pdf"; break; fi
done

if [ -z "$hit" ]; then
  echo "FAIL: the printed document does not name '$CNAME' anywhere in its text."
  echo "      Files read: $PDFS"
  echo "      A PDF that renders somebody else's hours under the right filename is a"
  echo "      real, shipped failure mode on this route - Main.ACT_PDF_GoTo ignored its"
  echo "      context object once before, which is why verify-tt683-a3 exists. Printing"
  echo "      the wrong consultant's week from the Sent tab would send one client"
  echo "      another client's hours."
  for pdf in $PDFS; do
    echo "      --- $(basename "$pdf") first lines ---"
    head -5 "$pdf.txt" 2>/dev/null | sed 's/^/      /'
  done
  exit 1
fi

echo "PASS: verify-tt706-sent-print - HR printed $TAB week '$FOUND', the download is a real PDF ($BYTES bytes) and its text names '$CNAME'"

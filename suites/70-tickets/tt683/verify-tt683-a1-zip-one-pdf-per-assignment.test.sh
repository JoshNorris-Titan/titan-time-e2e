#!/usr/bin/env bash
# TT-683 angle 1 — the export delivers ONE PDF per consultant/project inside a
# single ZIP.
#
# This is the core promise. Before the change, Main.ACT_ExportAll_HRDash created
# a single Main.PDFMonthHelper for the whole batch and overwrote ConsultantName /
# ProjectName on every loop iteration, so a multi-consultant month produced ONE
# PDF headed by whichever pairing was processed last. After the change,
# Main.SUB_BuildMonthHelpers buckets by Main.AssignmentEntry_Assignment and
# Main.ACT_PDF_ExportZip zips one PDF per bucket.
#
# Asserts on the downloaded archive itself (see lib/_tt683.sh for how):
#   * the response really is a ZIP
#   * it holds at least one entry, and every entry name is distinct
#   * with >1 entry, the consultant/project groups genuinely differ — which is
#     precisely what the old single-aggregate flow could not do
#   * the PDFs differ in CONTENT, not just in name (CRC-32 + size per entry)
#
# That last one is the assertion that actually pins Main.ACT_PDF_GoTo. Filenames
# come from PDFMonthHelper/FileName, set correctly per helper by
# Main.SUB_BuildMonthHelpers — so they would all be right even while every PDF
# rendered the SAME consultant, which is the pre-TT-683 defect (ACT_PDF_GoTo
# ignored its context object and retrieved the newest helper). Identical renders
# are identical bytes, so identical CRC-32s are the signature of that bug.
#
# Runs unchanged on localhost, dev and acceptance: no admin port, no OQL.
#
# DESTRUCTIVE. Export All runs Main.SUB_ExportAll, which flips every
# AwaitingExport entry to Exported. Point it at an environment whose data you
# are willing to consume.
#
# PRECONDITION: >= 2 distinct consultant/project pairings must be awaiting
# export. One consultant on two projects is enough — an Assignment IS the
# consultant+project pairing. verify-tt683-a0-seed-awaiting-export.test.sh
# establishes this (it sorts ahead of this file); nothing else in the suite
# does, so do not remove it.
#
# Env: TT_BASE_URL, TT_ROLE_PASS
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"

TT683_ZIP_ERR=""

TAB="$(tt683_open_export_tab)" || exit 1
echo "export lives on tab: $TAB"
tt683_click_export_all

CAPTION="$(tt683_zip_button_caption)"
[ -n "$CAPTION" ] \
  || tt_fail "no download button appeared in the popup within 30s — Main.DS_PDF_CheckLoad never saw a committed helper, so the button stayed behind the 1-1-1970 sentinel"
echo "download button: '$CAPTION'"

# Regression guard on the re-pointed button: before TT-683 this read
# "View Exported Timesheet" and called Main.ACT_PDF_ViewAndClean.
case "$CAPTION" in
  *ZIP*|*Zip*|*zip*) : ;;
  *"View Exported Timesheet"*)
    tt_fail "the popup still shows the pre-TT-683 caption 'View Exported Timesheet' — Main.ExportAll_Waiting's actionButton2 was not re-pointed to Main.ACT_PDF_ExportZip" ;;
  *) tt_fail "unexpected download button caption '$CAPTION' (wanted something naming the ZIP)" ;;
esac

ENTRIES="$(tt683_download_zip_entries)" \
  || tt_fail "could not read the downloaded archive: ${TT683_ZIP_ERR:-unknown error}"

[ -n "$ENTRIES" ] || tt_fail "the archive parsed but contains no entries — ZipHandling.ZipDocuments silently skips files with no name or no content, so this usually means PDF generation produced nothing"

COUNT="$(printf '%s\n' "$ENTRIES" | grep -c .)"
echo "archive contains $COUNT entr(y/ies):"
printf '%s\n' "$ENTRIES" | sed 's/^/  /'

# Are they actually PDFs? Everything above and below reads the central directory
# only, which sees names, sizes and CRCs without opening a single entry. An export
# that produced error pages, empty stubs or an HTML login redirect would still give
# correctly-named entries with distinct CRCs and satisfy every one of those checks.
# This opens them: first five bytes "%PDF-", and big enough to be a real document.
PDFREPORT="$(tt683_zip_pdf_report)"
case "$PDFREPORT" in
  ERR*) tt_fail "could not re-open the archive to check its contents: ${PDFREPORT#ERR }" ;;
  "")   tt_fail "the archive content check returned nothing, so no entry was actually opened" ;;
esac

BADPDF="$(printf '%s
' "$PDFREPORT" | grep '~~BAD' || true)"
if [ -n "$BADPDF" ]; then
  echo "$(printf '%s
' "$BADPDF" | grep -c .) archive entr(y/ies) are not usable PDFs:"
  printf '%s
' "$BADPDF" | sed 's/^/  /'
  tt_fail "the export produced files that are not PDFs. Correct names and distinct CRCs are not enough - something generated content that will not open."
fi
echo "all $COUNT entr(y/ies) are PDFs:"
printf '%s
' "$PDFREPORT" | sed 's/^/  /'

# Distinct names. ZipDocuments de-duplicates by prefixing the object ID, so a
# collision shows up as a leading numeric id rather than a lost file.
UNIQ="$(printf '%s\n' "$ENTRIES" | sort -u | grep -c .)"
[ "$UNIQ" -eq "$COUNT" ] \
  || tt_fail "archive entry names are not distinct ($UNIQ unique of $COUNT)"

case "$(printf '%s\n' "$ENTRIES" | grep -c '^[0-9]\{10,\} ')" in
  0) : ;;
  *) tt_fail "at least one entry is prefixed with an object id, which ZipHandling.ZipDocuments only does when two files share a Name — two helpers produced the same filename" ;;
esac

if [ "$COUNT" -ge 2 ]; then
  # Every entry is {yyyy}-{MMdd}-{Last First}-{Project}.pdf; the pairing is
  # everything after the date, so distinct pairings == distinct tails.
  TAILS="$(printf '%s\n' "$ENTRIES" | sed -E 's/^[0-9]{4}-[0-9]{4}-//' | sort -u | grep -c .)"
  [ "$TAILS" -eq "$COUNT" ] \
    || tt_fail "the archive has $COUNT PDFs but only $TAILS distinct consultant/project pairings — the split is not producing one PDF per assignment"
  echo "split proven: $COUNT PDFs across $TAILS distinct consultant/project pairings"

  # ---- content identity: distinct NAMES are not distinct DOCUMENTS ----------
  # If Main.ACT_PDF_GoTo rendered the same PDFMonthHelper for every generation,
  # each PDF would be a byte-for-byte copy of the others while still carrying
  # its own correct filename. Every assertion above would pass. The CRC-32 in
  # the central directory settles it without inflating anything.
  RECS="$(tt683_zip_records)"
  [ -n "$RECS" ] \
    || tt_fail "the archive parsed but no per-entry CRC/size records were captured — lib/_tt683.sh could not read the central directory, so PDF content identity went unchecked"

  RECCOUNT="$(printf '%s\n' "$RECS" | grep -c .)"
  [ "$RECCOUNT" -eq "$COUNT" ] \
    || tt_fail "captured $RECCOUNT content record(s) for $COUNT archive entries — cannot check content identity against a partial read"

  echo "per-PDF content fingerprints (name / crc32 / bytes):"
  printf '%s\n' "$RECS" | awk -F'~~' '{printf "  %-52s crc=%-12s %s bytes\n", $1, $2, $3}'

  FPRINTS="$(printf '%s\n' "$RECS" | awk -F'~~' '{print $2"/"$3}' | sort -u | grep -c .)"
  [ "$FPRINTS" -eq "$COUNT" ] \
    || tt_fail "the archive holds $COUNT correctly-named PDFs but only $FPRINTS distinct document(s) — two or more PDFs are byte-identical. That is the Main.ACT_PDF_GoTo defect: it is rendering one PDFMonthHelper repeatedly instead of the context object it is passed, so every consultant's file contains the same consultant's hours."
  echo "content proven: $FPRINTS distinct documents for $COUNT PDFs — each helper rendered its own"
else
  tt_fail "only one consultant/project pairing was in the archive, so the multi-consultant SPLIT — the core of TT-683 — was not exercised. verify-tt683-a0 is supposed to guarantee at least two; if it passed and this still fired, entries reached AwaitingExport in different MONTHS and only one month was exported."
fi

# Taking the download runs ACT_PDF_ExportZip's cleanup and Close page.
for _ in $(seq 1 30); do tt683_popup_open || break; sleep 1; done
tt683_popup_open \
  && tt_fail "the 'Exporting Timesheets' popup did not close after the download — ACT_PDF_ExportZip's Close page never ran (did PDF generation throw?)"

echo "PASS: verify-tt683-a1-zip-one-pdf-per-assignment — valid ZIP, $COUNT distinct PDF(s), popup closed"

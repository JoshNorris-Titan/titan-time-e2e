#!/usr/bin/env bash
# tt-timeout: 10m
# verify-tt805-relogin-print.test.sh
#
# TT-805 - "Monthly time report fails when HR is signed in more than once". HR
# leaves one session behind, signs in again, prints a Sent week, and must get a
# real PDF back - not, two minutes later, "An error occurred".
#
# WHAT WENT WRONG. The monthly PDF was generated AS THE USER WHO CLICKED. The
# DocumentGeneration module renders in an existing session of that user
# (SessionManager.getSession -> Core.getActiveSession(name)), and when the user has
# more than one it can pick a stale one: the cloud service then cannot open the
# page, its error lands ~0.2 s after the module stopped polling, and the log only
# says "Timeout while waiting for document result". Reproduced on dev 2026-10-26
# with DocumentGeneration at TRACE: three prints after a sign-out/sign-in all
# failed, each rendered in the same old session while the clicker was on a new one.
#
# THE FIX renders every PDF as docgen_renderer, an account created at startup that
# nobody signs in to (Core.SUB_DocumentRenderUser_Ensure, Main.SUB_GetDocumentRenderUser).
#
# HOW THIS PROVOKES IT. tt_login signs in (possibly reusing a saved session from an
# earlier step), then the cookies are cleared and the account signs in AGAIN through
# the form. The first session is abandoned, not ended - it stays live on the server,
# which is exactly the "signed in more than once" state. Before TT-805 the print
# below rendered in whichever session the runtime handed back; after it, the
# clicker's sessions are irrelevant to rendering.
#
# WHAT IT ASSERTS
#   A. A Sent week can be printed and the download page is reached.
#   B. The download is a real PDF, or a ZIP of real PDFs - each begins %PDF and is
#      big enough to be a render, not a DocGen error page.
#
# DATA. Like verify-tt706-sent-print, it prints an EXISTING Sent week (tt683 exports
# populate the tab and sort before tt805) and changes nothing.
set -uo pipefail
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"
source "$TT_ROOT/lib/_login.sh"
source "$TT_ROOT/lib/_tt683.sh"

TAB="Sent"
WORK="${TMPDIR:-/tmp}/tt805-$$"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK"

# ------------------------------------------- 1. two live sessions for e2e_hr
tt_login "e2e_hr" "$TT_HR_READY"
playwright-cli cookie-clear >/dev/null 2>&1
_tt_login_interactive "e2e_hr" "$TT_HR_READY"
echo "  e2e_hr signed in twice; the first session was abandoned, not ended"

# ------------------------------------------------- 2. print the newest week
tt_hr_click_tab "$TAB" "HR '$TAB' tab"
tt_hr_wait_pane "'$TAB' week groups"
WEEKS="$(tt_hr_week_labels)"
WEEK="${WEEKS%%|*}"
[ -n "$WEEK" ] && [ "$WEEK" != "null" ] \
  || tt_fail "the $TAB tab offers no weeks. It lists Exported entries, which suites/70-tickets/tt683/ produces - if that folder failed, fix it there."
echo "  printing $TAB week '$WEEK'"

r="$(tt_hr_print_week "$WEEK")"
[ "$r" = "ok" ] || tt_fail "week '$WEEK''s Print (.mx-name-btnSentPrintWeek) could not be pressed: $r"
sleep 4

reached=""
for _ in $(seq 1 25); do
  state="$(playwright-cli eval "() => { const b=[...document.querySelectorAll('button')].filter(e=>e.offsetParent!==null).find(e=>/zip|download/i.test(e.innerText||'') && !e.closest('.mx-name-lstSentWeeks')); if(b) return 'page'; const d=document.querySelector('.mx-dialog,.mx-window,[role=dialog]'); if(d) return 'dialog:' + ((d.innerText||'').replace(/\s+/g,' ').trim().slice(0,120)); return 'waiting'; }" 2>/dev/null | _tt_eval_str)"
  case "$state" in
    page) reached=1; break ;;
    dialog:*) tt_fail "Print stopped at a message instead of the download page: ${state#dialog:}" ;;
  esac
  sleep 2
done
[ -n "$reached" ] || tt_fail "Print neither opened the download page nor raised a message within 50s"

# ----------------------------------------------- 3. the render must succeed
# This is the step TT-805 broke: the PDFs are generated when the download control is
# pressed, and with a stale session the app answered "An error occurred, please
# contact your system administrator" after ~2 minutes instead of a file.
tt683_download_zip_entries >"$WORK/entries.txt" 2>"$WORK/dl.err" || true
err="$(playwright-cli eval "() => { const d=[...document.querySelectorAll('.modal-dialog,.mx-dialog,[role=dialog]')].find(x=>/error occurred/i.test(x.innerText||'')); return d ? 'error' : 'none'; }" 2>/dev/null | _tt_eval_str)"
[ "$err" != "error" ] \
  || tt_fail "the app showed 'An error occurred' while generating the PDFs for week '$WEEK' with e2e_hr signed in twice. That is TT-805: the PDF was rendered in a stale session of a person instead of the docgen_renderer account. Check the startup log for a Critical Titan.Migration line from DocumentRenderUser_Ensure, and that Main.SUB_PDFGenReturn passes \$RenderUser."
FILE="$(_tt683_downloaded_path)" \
  || tt_fail "the download control was pressed but no file was saved: $(tr -s ' \n' ' ' < "$WORK/dl.err" 2>/dev/null | cut -c1-800)"

PDFS=""
case "$(head -c 4 "$FILE")" in
  "%PDF") PDFS="$FILE" ;;
  "PK"*)
    python "$TT683_ZIPREPORT" "$FILE" extract "$WORK/zip" >/dev/null 2>&1 \
      || tt_fail "the download is a ZIP that could not be extracted"
    PDFS="$(find "$WORK/zip" -type f -name '*.pdf')"
    [ -n "$PDFS" ] || tt_fail "the download is a ZIP with no PDF in it: $(find "$WORK/zip" -type f | tr '\n' ' ')" ;;
  *) tt_fail "the download is neither a PDF nor a ZIP - it begins [$(head -c 8 "$FILE" | tr -d '\0')]" ;;
esac

n=0
while IFS= read -r pdf; do
  [ -n "$pdf" ] || continue
  [ "$(head -c 4 "$pdf")" = "%PDF" ] || tt_fail "$(basename "$pdf") is not a PDF - it begins [$(head -c 8 "$pdf" | tr -d '\0')]"
  bytes="$(wc -c < "$pdf" | tr -d ' ')"
  [ "$bytes" -gt 1000 ] || tt_fail "$(basename "$pdf") is only $bytes bytes - too small to be a rendered timesheet"
  n=$((n + 1))
done <<< "$PDFS"

echo "PASS: verify-tt805-relogin-print - with e2e_hr signed in twice, printing $TAB week '$WEEK' produced $n real PDF(s)"

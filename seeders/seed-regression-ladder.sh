#!/usr/bin/env bash
# Seed a manual-regression data set: AssignmentEntries in every reachable status, across
# a deliberately wide spread of hour scenarios, for each e2e consultant.
#
# NOT named *.test.sh on purpose: this is a destructive data seeder, not a test, and must
# never be picked up by a `mxcli playwright verify tests/` sweep. Its narrow ancestor,
# seed-toprocess-entries.sh, is left in place and untouched.
#
# RUN tests/seed-shakedown.sh FIRST. It is the gate: it proves the logins work on this
# environment and — critically — reports which weeks can hold data at all. Seeding
# without it is how a whole ladder once got built on weeks that render zero rows.
#
# ---------------------------------------------------------------------- the ladder
#
# A whole week submits at ONCE, and each row's destination depends on ITS OWN project's
# approval flags, so "one week = one status" is impossible. Instead each week is pushed
# to a STAGE and the row mix produces the spread:
#
#   stage         drives to                       appears on
#   ------------  ------------------------------  --------------------------
#   export        Exported                        SENT
#   process       AwaitingExport                  MONTHLY TO BE INVOICED
#   approve_all   ToProcess                       WEEKLY TO PROCESS
#   approve_mgr   AwaitingCustomerApproval        CLIENT APPROVAL
#   submit        AwaitingManagerApproval + mix   MANAGER APPROVAL
#   reject        Rejected                        (back to the consultant)
#   draft         Draft                           PENDING
#   empty         nothing — week left at zero     (transient, see below)
#
# DATES ARE RESOLVED AT RUNTIME, NOT HARDCODED. The previous version pinned week labels
# and they went stale the moment the environment moved. Now the seeder asks the app which
# weeks its history gallery offers with "Projects: N" > 0 and assigns stages to the most
# recent ones, oldest stage first. Nothing to edit when the calendar moves.
#
# --------------------------------------------------------------- scenario coverage
#
# Day values must be >= 0, <= 24 and exact multiples of 0.25 (Main.SUB_Timesheet_Validate),
# and the cross-project total for any single day must stay <= 24. Inside that:
#   full40   8h Mon-Fri per row  — exactly the assignment's weekly budget
#   part     4h Mon-Fri per row  — under 40, raises the "Submit Anyway" confirm
#   weekend  2h every day        — exercises Sat/Sun, which most weeks leave empty
#   onezero  first row 8h, rest ZERO — a zero-hour entry skips approval entirely
#            ("if TotalHours = 0 then ToProcess") and renders "No approval required"
#   lines    line-item tasks on the locked rows + 4h on the open ones
#
# OVER-40 IS DELIBERATELY ABSENT. Main.Consultant_OverWeeklyHours is a blocking dialog
# whose only button is Close, and Close CANCELS the action — it blocks SAVE, not just
# Submit. An over-40 week therefore cannot be persisted at all, by design. Testers can
# still see it by typing 9h/day by hand; it is not a seedable state, and pretending
# otherwise just produced empty weeks in the previous run.
#
# THE EMPTY WEEK IS TRANSIENT. Core.SCE_Timesheet_CleanupEmptyDrafts deletes any Draft
# timesheet with no non-zero hours and no SubmittedDT, with NO age threshold, so the
# empty week vanishes on that event's next run. Seeded anyway because it is worth seeing.
#
# ------------------------------------------------------------------------- env
#   TT_BASE_URL      REQUIRED. No default — this submits and approves real timesheets.
#   TT_ROLE_PASS     e2e account password
#   SEED_CONSULTANTS pipe-separated usernames
#   SEED_PROVE=1     prove-one mode: ONE consultant, ONE week, one stage, then stop.
#                    Run this before every full run; it is two minutes and it is what
#                    catches a selector typo that would otherwise waste 40 minutes.
#   SEED_SKIP_SUBMIT / SEED_SKIP_HR   run only one half
set -uo pipefail
cd "$(dirname "$0")/../.."   # seeders/ -> tests/ -> project root
source tests/lib/_login.sh
source tests/lib/_seed.sh

if [ -z "${TT_BASE_URL:-}" ]; then
  echo "FAIL: TT_BASE_URL must be set explicitly. This seeder submits, approves and" >&2
  echo "      exports real timesheets — it will not guess an environment." >&2
  exit 1
fi

CONSULTANTS="${SEED_CONSULTANTS:-e2e_consultant|e2e_consultant2|e2e_consultant3}"
PROVE="${SEED_PROVE:-0}"

# Stage ladder, OLDEST week first. Each entry is "<stage>|<hour-pattern>".
STAGES="${SEED_STAGES:-export|full40_lines
process|weekend
approve_all|onezero
approve_mgr|lines
submit|part
reject|full40
draft|part
empty|none}"

# Card ownership. FULL NAMES, verified against the live dashboard — the cards' first
# line is the consultant's FullName ("E2E Consultant Two"), not the username.
NAMES="${SEED_NAMES:-E2E Consultant Three|E2E Consultant Two|E2E Consultant}"

log() { seed_log "$@"; }

# ============================================================ consultant side

# fill_row <ordinal> <sun> <mon> <tue> <wed> <thu> <fri> <sat>
# Mendix decimal inputs commit only on a real focus change, hence the trailing clicks.
# :nth-match is required, not cosmetic: a bare .mx-name-txtDayX matches every row and
# Playwright refuses the write outright ("strict mode violation"), silently writing
# nothing while the caller happily asserts a value it never entered.
fill_row() {
  local ord="$1"; shift
  local days="Sun Mon Tues Wed Thurs Fri Sat" d v i=0
  for d in $days; do
    i=$((i + 1)); v="$(eval echo \${$i})"; [ -n "$v" ] || v=0
    tt_fill_cell ":nth-match(.mx-name-galAssignmentRows .mx-name-txtDay${d} input, ${ord})" "$v"
  done
  tt_commit_focused
  sleep 1
}

# expand_line_items — open the line-item panel and wait until Add Task is actually usable.
#
# Testing for the mere EXISTENCE of .mx-name-galLineItems is not enough: the gallery stays
# in the DOM while collapsed, so an existence check returns early with the panel shut and
# btnAddTask unclickable — which is exactly why "Add Task produced no line-item row".
# Gate on the button being VISIBLE (offsetParent), not on the gallery existing.
expand_line_items() {
  local i
  for i in 1 2 3; do
    [ "$(pw "() => { const b=document.querySelector('.mx-name-btnAddTask'); return String(!!b && b.offsetParent!==null); }")" = "true" ] && return 0
    pw "() => { const b=document.querySelector('.mx-name-btnLineItemsCollapse')||document.querySelector('.mx-name-btnLineItemsExpand'); if(b){b.click(); return 'Y';} return 'N'; }" >/dev/null
    sleep 4
  done
  [ "$(pw "() => { const b=document.querySelector('.mx-name-btnAddTask'); return String(!!b && b.offsetParent!==null); }")" = "true" ]
}

# drop_blank_line_items — delete any line item whose Name is empty.
#
# NOT hygiene. Main.SUB_LineItem_Calc raises validation feedback on any line item failing
# trim(Name) != '', and that blocks the SAVE for the WHOLE timesheet. One stray blank row
# — trivially left behind by an "Add Task" click that was never filled — silently poisons
# every later submit on that week.
drop_blank_line_items() {
  local i r
  for i in $(seq 1 10); do
    r="$(pw "() => { const g=document.querySelector('.mx-name-galLineItems'); if(!g) return 'CLEAN'; const names=[...g.querySelectorAll('.mx-name-txtLineItemName input')]; for(let k=0;k<names.length;k++){ if(!(names[k].value||'').trim()){ const row=names[k].closest('.widget-gallery-item'); const del=row?row.querySelector('.mx-name-btnLineItemDelete'):null; if(del){ del.click(); return 'DELETED'; } return 'NOBTN'; } } return 'CLEAN'; }")"
    case "$r" in
      CLEAN) return 0 ;;
      DELETED) sleep 2; seed_force_clear >/dev/null 2>&1 || true ;;
      *) log "    !! a blank line item has no delete control — save may be blocked"; return 1 ;;
    esac
  done
  return 0
}

# add_line_item <name> <sun..sat>
add_line_item() {
  local name="$1"; shift
  local j n before
  expand_line_items
  drop_blank_line_items || true
  before="$(pw "() => String(document.querySelectorAll('.mx-name-galLineItems .mx-name-txtLineItemName').length)")"
  pw "() => { const b=document.querySelector('.mx-name-btnAddTask'); if(b){b.click(); return 'Y';} return 'N'; }" >/dev/null
  for j in $(seq 1 6); do
    sleep 2
    n="$(pw "() => String(document.querySelectorAll('.mx-name-galLineItems .mx-name-txtLineItemName').length)")"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt "${before:-0}" ] && break
  done
  case "${n:-0}" in ''|*[!0-9]*|0) log "    !! Add Task produced no line-item row"; return 1 ;; esac

  playwright-cli fill ":nth-match(.mx-name-galLineItems .mx-name-txtLineItemName input, ${n})" "$name" >/dev/null 2>&1
  local days="Sun Mon Tues Wed Thurs Fri Sat" d v k=0
  for d in $days; do
    k=$((k + 1)); v="$(eval echo \${$k})"; [ -n "$v" ] || v=0
    playwright-cli fill ":nth-match(.mx-name-galLineItems .mx-name-txtLine${d} input, ${n})" "$v" >/dev/null 2>&1
  done
  playwright-cli click ":nth-match(.mx-name-galLineItems .mx-name-txtLineItemName input, ${n})" >/dev/null 2>&1
  sleep 1
  return 0
}

# apply_pattern <pattern> <rows-csv>
# editIdx counts only the OPEN rows, so "leave the second one at zero" means what it says
# regardless of where the locked line-item row sits in the order.
apply_pattern() {
  local pat="$1" rows="$2" entry ord kind editIdx=0 lineIdx=0
  local OLD="$IFS"; IFS=','
  for entry in $rows; do
    IFS="$OLD"
    ord="${entry%%:*}"; kind="${entry##*:}"
    if [ "$kind" = "LINE" ]; then
      lineIdx=$((lineIdx + 1))
      case "$pat" in
        # multitask puts SEVERAL named tasks on one line-item row, which is the case the
        # single-task patterns never exercise: SUB_LineItem_Calc has to sum them and
        # rewrite the parent row's day values from the total.
        multitask)
          add_line_item "Design review $lineIdx" 0 1 1 1 0 0 0 || true
          add_line_item "Build $lineIdx"         0 2 2 2 2 2 0 || true
          add_line_item "Handover $lineIdx"      0 0 0 0 1 1 0 || true ;;
        *lines*) add_line_item "Demo task $lineIdx" 0 2 2 2 2 2 0 || true ;;
      esac
    else
      editIdx=$((editIdx + 1))
      # THREE LIMITS BIND EVERY PATTERN BELOW, and breaking any of them costs a whole week:
      #   * each value must be a multiple of 0.25 (Main.SUB_Timesheet_Validate)
      #   * the CROSS-PROJECT total for one day must stay <= 24. A pattern is applied to
      #     EVERY open row, and one consultant has FOUR assignments, so per-row-per-day
      #     above 5h can breach 24 for that consultant while looking fine for the others.
      #   * per-row weekly total must stay <= the assignment's 40h budget, or
      #     Main.Consultant_OverWeeklyHours raises a Close-only dialog that CANCELS the
      #     submit outright — losing the week rather than trimming it.
      case "$pat" in
        onezero) if [ "$editIdx" -ge 2 ]; then fill_row "$ord" 0 0 0 0 0 0 0; else fill_row "$ord" 0 8 8 8 8 8 0; fi ;;
        full40*) fill_row "$ord" 0 8 8 8 8 8 0 ;;   # exactly the 40h weekly budget
        weekend) fill_row "$ord" 2 2 2 2 2 2 2 ;;
        part|lines) fill_row "$ord" 0 4 4 4 4 4 0 ;;

        # --- submit-only variety set ---
        quarter)     fill_row "$ord" 0 4.25 4.25 4.25 4.25 4.25 0 ;;  # quarter-hour precision
        oneday)      fill_row "$ord" 0 0 0 5 0 0 0 ;;                 # a single mid-week day
        weekendonly) fill_row "$ord" 4 0 0 0 0 0 4 ;;                 # Sat+Sun only, no weekdays
        uneven)      fill_row "$ord" 0 3.5 4.75 5 2.25 4 0 ;;         # a different value every day
        tiny)        fill_row "$ord" 0 0.25 0 0 0 0 0 ;;              # the smallest legal entry
        fullspread)  fill_row "$ord" 3 3 3 3 3 3 3 ;;                 # all seven days populated
        halfdays)    fill_row "$ord" 0 4 4 4 4 4 0 ;;                 # steady part-time week
        # multitask is fundamentally a LINE-ITEM scenario, but only consultants assigned to
        # a NeedsLineItems project have a locked row to put tasks on. Without this fallback
        # a consultant whose rows are all open gets NOTHING filled, and the week is then
        # correctly refused as an empty submit — which is exactly what happened to
        # e2e_consultant2 and e2e_consultant3 while consultant 1 (who has the Line Items
        # project) sailed through, making it look like a flake rather than a coverage gap.
        multitask)   fill_row "$ord" 0 3 3 3 3 3 0 ;;
        # zerohours is NOT a no-op: Main routes TotalHours = 0 straight to ToProcess with
        # no approval step, so the card reads "No approval required". Explicitly zero every
        # cell rather than leaving them blank, so the state is deliberate and visible.
        zerohours)   fill_row "$ord" 0 0 0 0 0 0 0 ;;

        none) : ;;
      esac
    fi
    IFS=','
  done
  IFS="$OLD"
}

save_week() {
  [ "$(pw "() => String(!!document.querySelector('.mx-name-btnSaveDraft'))")" = "true" ] || return 0
  playwright-cli click ".mx-name-btnSaveDraft" >/dev/null 2>&1
  sleep 3
  if ! seed_force_clear; then
    log "    save blocked by a dialog that offers no way forward"
    return 1
  fi
  return 0
}

# submit_week <rows> [pattern] — rc 0 submitted, 1 blocked, 2 hours never persisted.
submit_week() {
  local rows="$1" pat="${2:-}" entry ord kind v any=0
  save_week || return 1

  # A deliberately zero-hour week must SKIP the non-zero check, or it can never be
  # submitted — and a zero-hour entry is a real scenario in its own right (Main routes
  # TotalHours = 0 straight to ToProcess, rendering "No approval required").
  case "$pat" in
    zerohours|none)
      playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
      sleep 2
      if ! tt_clear_dialogs 8; then
        log "    submit blocked: $TT_DIALOG_BLOCKED"
        seed_force_clear >/dev/null 2>&1 || true
        return 1
      fi
      seed_force_clear >/dev/null 2>&1 || true
      return 0 ;;
  esac

  # Verify at least one open row really holds non-zero hours. Without this an entry
  # submits with TotalHours = 0, routes straight to ToProcess, and its card reads
  # "No approval required" — indistinguishable from a product bug.
  #
  # RETRIED, because the read right after Save can catch the grid mid-rerender and report
  # every cell blank. That produced a false "hours did not persist" on a week whose hours
  # had in fact landed (the history gallery showed 80.00 for it).
  #
  # READS ALL SEVEN DAY COLUMNS, not just Monday. Checking Monday alone silently assumed
  # every pattern populates Monday — true for the status-ladder patterns, false the moment
  # a scenario puts its hours anywhere else. The "oneday" pattern (hours on Wednesday) and
  # "weekendonly" (Sat/Sun) both read back as 0.00 and were wrongly reported as never
  # having saved, so the week was skipped despite being filled correctly.
  local i
  for i in 1 2 3 4 5; do
    v="$(pw "() => ['Sun','Mon','Tues','Wed','Thurs','Fri','Sat'].flatMap(d=>[...document.querySelectorAll('.mx-name-galAssignmentRows .mx-name-txtDay'+d+' input')].map(e=>e.value||'0')).join(',')")"
    case "$v" in
      *[1-9]*) any=1; break ;;
    esac
    sleep 3
  done
  [ "$any" = "1" ] || { log "    no non-zero hours in any day column after save: '$v'"; return 2; }

  playwright-cli click ".mx-name-btnSubmit" >/dev/null 2>&1
  sleep 2
  if ! tt_clear_dialogs 8; then
    log "    submit blocked: $TT_DIALOG_BLOCKED"
    seed_force_clear >/dev/null 2>&1 || true
    return 1
  fi
  seed_force_clear >/dev/null 2>&1 || true
  return 0
}

# resolve_weeks — map stages onto the real weeks this consultant can hold data in.
#
# Prints "<label>|<stage>|<pattern>" oldest-first. Takes the N most recent weeks whose
# "Projects: N" is non-zero, where N is the number of stages needing a week, and assigns
# the ladder to them oldest stage first. If there are fewer seedable weeks than stages,
# the SHALLOWEST stages are dropped and named — never silently truncated.
resolve_weeks() {
  local list want got labels i short
  want=$(printf '%s\n' "$STAGES" | grep -c . || true)

  # Materialise first. On a freshly cleared database the history gallery lists exactly ONE
  # week, because it only shows weeks that already have a Timesheet row. Visiting a week
  # is what creates it (DS_Timesheet_Get -> SUB_Timesheet_Create), so step back far enough
  # to bring the whole ladder into existence before trying to resolve it.
  list="$(seed_week_list | awk -F'|' '$2 != "0" && $2 != "?"' | cut -d'|' -f1)"
  got=$(printf '%s\n' "$list" | grep -c . || true)
  if [ "$got" -lt "$want" ]; then
    short=$((want - got))
    log "  only $got week(s) exist; stepping back $short to materialise the rest"
    log "  materialised $(seed_materialise_weeks "$short") week(s)"
  fi

  list="$(seed_week_list | awk -F'|' '$2 != "0" && $2 != "?"' | cut -d'|' -f1)"
  got=$(printf '%s\n' "$list" | grep -c . || true)

  if [ "$got" -lt 1 ]; then
    log "  !! this consultant has NO week with assignment rows — nothing can be seeded"
    return 1
  fi
  if [ "$got" -lt "$want" ]; then
    log "  !! only $got seedable week(s) for $want stages — dropping the shallowest $((want - got))"
    STAGES_USED="$(printf '%s\n' "$STAGES" | head -n "$got")"
  else
    STAGES_USED="$(printf '%s\n' "$STAGES" | head -n "$want")"
  fi

  # newest-first from the gallery -> reverse to oldest-first so the deepest stage
  # (export) lands on the oldest week, which is what a real backlog looks like.
  labels="$(printf '%s\n' "$list" | head -n "$(printf '%s\n' "$STAGES_USED" | grep -c .)" | sed '1!G;h;$!d')"

  i=0
  printf '%s\n' "$STAGES_USED" | while IFS='|' read -r stage pat; do
    i=$((i + 1))
    printf '%s|%s|%s\n' "$(printf '%s\n' "$labels" | sed -n "${i}p")" "$stage" "$pat"
  done
}

# seed_forward — walk FORWARD from the current week, applying the stage list in order.
#
# WHY A SEPARATE MODE. resolve_weeks picks its labels out of the timesheet history
# gallery, and that gallery only lists the CURRENT and PAST weeks. Once the past weeks are
# consumed (every one already submitted), there is nothing left for it to choose, so
# additional timesheets have to go forward — and future week labels cannot be read from
# the gallery at all. This mode never needs to predict a label: it steps to the next week,
# reads the caption it landed on, and seeds whatever is there.
#
# Used for the submit-only variety pass, where the point is breadth of hour scenarios
# rather than a status ladder.
seed_forward() {
  local user="$1" stage pat rows rc cap i

  # Step clear of the current week before seeding anything.
  #
  # NOT arbitrary. The current week can legitimately hold data that must not be
  # overwritten — after the status ladder ran, it held the REJECTED entries, and a
  # rejected entry is editable again (CAL_AssignmentEntry_IsEditable allows Draft OR
  # Rejected). Forward mode would therefore have refilled and resubmitted them, silently
  # destroying the only Rejected coverage in the data set.
  for i in $(seq 1 "${SEED_FORWARD_START:-1}"); do
    seed_step_next || { log "  cannot step forward off '$(seed_week_caption)'"; return 1; }
  done
  log "  seeding forward from '$(seed_week_caption)'"

  printf '%s\n' "$STAGES" | while IFS='|' read -r stage pat; do
    [ -n "$stage" ] || continue

    cap="$(seed_week_caption)"
    rows="$(seed_open_rows)"
    if [ -z "$rows" ]; then
      log "  $cap: no assignment rows (outside every assignment's date window) — stopping"
      break
    fi
    case "$rows" in
      *EDIT*) : ;;
      *)
        if [ "$(pw "() => String(!!document.querySelector('.mx-name-btnSubmit'))")" != "true" ]; then
          log "  $cap [$pat]: already submitted / not editable — skipped"
          seed_step_next || break
          continue
        fi ;;
    esac

    apply_pattern "$pat" "$rows"
    submit_week "$rows" "$pat"; rc=$?
    case "$rc" in
      0) log "  $cap [$pat]: submitted (rows: $rows)" ;;
      1) log "  $cap [$pat]: SUBMIT BLOCKED by a dialog" ;;
      2) log "  $cap [$pat]: hours did not persist — NOT submitted" ;;
    esac

    seed_step_next || { log "  cannot advance past '$cap' — stopping"; break; }
  done
}

# seed_step_next — one verified step forward.
seed_step_next() {
  local before after j
  before="$(seed_week_caption)"
  playwright-cli click ".mx-name-btnWeekNext" >/dev/null 2>&1
  after="$before"
  for j in $(seq 1 8); do
    sleep 2
    after="$(seed_week_caption)"
    [ -n "$after" ] && [ "$after" != "$before" ] && return 0
  done
  return 1
}

seed_consultant() {
  local user="$1" plan label stage pat rows rc
  log "=== consultant $user ==="
  if ! seed_login_role "$user" "My Timesheets"; then
    log "  !! cannot sign in as $user — skipped"
    return 1
  fi
  sleep 2

  if [ "${SEED_FORWARD:-0}" = "1" ]; then
    log "  forward mode — walking ahead from '$(seed_week_caption)'"
    seed_forward "$user"
    return 0
  fi

  plan="$(resolve_weeks)" || return 1
  [ -n "$plan" ] || { log "  !! no week plan resolved"; return 1; }
  log "  plan:"
  printf '%s\n' "$plan" | while IFS='|' read -r l s p; do [ -n "$l" ] && log "    $l -> $s ($p)"; done

  # Persist it for the HR phase. Consultants can legitimately resolve to DIFFERENT weeks
  # (their assignments have their own date windows), so the HR phase drives the UNION of
  # every label/stage pair actually seeded — not one consultant's guess at the ladder.
  printf '%s\n' "$plan" >> "$PLAN_FILE"

  [ "$PROVE" = "1" ] && plan="$(printf '%s\n' "$plan" | head -1)" && log "  PROVE mode: first week only"

  printf '%s\n' "$plan" | while IFS='|' read -r label stage pat; do
    [ -n "$label" ] || continue
    if ! seed_goto_week "$label"; then
      log "  $label: could not navigate to it — skipped"
      continue
    fi
    rows="$(seed_open_rows)"
    if [ -z "$rows" ]; then
      log "  $label: no assignment rows rendered — skipped"
      continue
    fi

    # Already-submitted weeks are IDEMPOTENTLY SKIPPED. Once an entry leaves Draft its day
    # boxes lock (CAL_AssignmentEntry_IsEditable allows only Draft/Rejected/empty), so a
    # re-run would fill nothing, find no Submit button, and log a confusing failure for a
    # week that is in fact already correct. Detect it and say so plainly, so re-running the
    # seeder after a partial run is safe.
    case "$rows" in
      *EDIT*) : ;;
      *)
        if [ "$(pw "() => String(!!document.querySelector('.mx-name-btnSubmit'))")" != "true" ]; then
          log "  $label [$stage]: already submitted / not editable — skipped"
          continue
        fi ;;
    esac

    if [ "$stage" = "empty" ]; then
      log "  $label [$stage]: left empty on purpose (rows: $rows)"
      continue
    fi

    apply_pattern "$pat" "$rows"

    if [ "$stage" = "draft" ]; then
      if save_week; then log "  $label [$stage/$pat]: saved as draft (rows: $rows)"
      else log "  $label [$stage/$pat]: SAVE BLOCKED"; fi
      continue
    fi

    submit_week "$rows" "$pat"; rc=$?
    case "$rc" in
      0) log "  $label [$stage/$pat]: submitted (rows: $rows)" ;;
      1) log "  $label [$stage/$pat]: SUBMIT BLOCKED by a dialog" ;;
      2) log "  $label [$stage/$pat]: hours did not persist — NOT submitted" ;;
    esac
  done
}

# ================================================================== HR side

owned_js() {
  local n out="" OLD="$IFS"; IFS='|'
  for n in $NAMES; do [ -n "$n" ] || continue; out="$out || f==='$n'"; done
  IFS="$OLD"; echo "(false${out})"
}

# _card_js — climb from a control to the CARD, identified by its FIRST LINE being one of
# our consultants. Exact equality: "E2E Consultant" is a prefix of "E2E Consultant Two",
# and these tabs carry other people's live dev data that must never be approved by
# accident.
_card_js() {
  local owned; owned="$(owned_js)"
  printf "%s" "(b => { let p=b; for(let i=0;i<12;i++){ if(!p.parentElement) break; p=p.parentElement; const t=(p.innerText||'').trim(); if(!t) continue; const f=t.split('\n')[0].trim(); if($owned) return p; } return null; })"
}

wait_entries() {
  local i
  for i in $(seq 1 12); do
    [ "$(pw "() => { const g=document.querySelector('.mx-name-galTabEntries'); return String(!!g && (g.innerText||'').trim().length > 10); }")" = "true" ] && return 0
    sleep 2
  done
  return 1
}

select_week() {
  local i
  for i in 1 2 3; do
    [ "$(pw "() => { const g=document.querySelector('.mx-name-galTabAvailableWeeks'); if(!g) return 'N'; const el=[...g.querySelectorAll('*')].find(e=>e.childElementCount===0 && (e.innerText||'').trim().indexOf('$1')===0); if(el){el.click(); return 'Y';} return 'N'; }")" = "Y" ] && { sleep 3; wait_entries || true; return 0; }
    sleep 2
  done
  return 1
}

# owned_with <btn-name> — owned cards still exposing the control. <btn-name> is the BARE
# widget name; the "mx-name-" prefix is added HERE.
#
# THE PREFIX IS NOT COSMETIC. Passing it through unprefixed makes every selector
# '.btnApprove', which matches nothing, so every count is 0 and every stage cheerfully
# reports "approved 0" while the tab is visibly full of approvable cards. That is exactly
# how an entire HR pass silently did nothing.
owned_with() {
  local c try
  for try in 1 2 3; do
    c="$(pw "() => { const card=$(_card_js); const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return 'NOGAL'; let n=0; for(const b of [...g.querySelectorAll('.mx-name-$1')]){ if(card(b)) n++; } return String(n); }")"
    case "$c" in NOGAL|''|*[!0-9]*) wait_entries || true ;; *) echo "$c"; return 0 ;; esac
  done
  echo 0
}

# confirm_dialog <regex> — click a named affirmative in the LIVE dialog.
#
# tt_clear_dialogs only recognises yes|submit anyway|confirm|continue|proceed|ok, so the
# inline Approve dialog ("...do you wish to approve anyway?" [x|Approve|Cancel]) is not
# handled by it. Clicking the x or Cancel ABANDONS the action, so match exactly.
confirm_dialog() {
  local re="$1" i
  for i in $(seq 1 6); do
    case "$(pw "() => { const vis=[...document.querySelectorAll('.mx-window-content,.mx-dialog-content,.modal-content,[role=dialog]')].filter(d=>d.offsetParent!==null); if(!vis.length) return 'NONE'; const outer=vis.filter(d=>!vis.some(o=>o!==d && o.contains(d))); const d=outer[outer.length-1]; const b=[...d.querySelectorAll('button')].filter(x=>x.offsetParent!==null).find(x=>/$re/i.test((x.innerText||'').trim())); if(b){ b.click(); return 'OKD'; } return 'OTHER:'+(d.innerText||'').replace(/\s+/g,' ').slice(0,80); }")" in
      NONE) return 0 ;;
      OKD)  sleep 2 ;;
      OTHER:*) tt_clear_dialogs 4 >/dev/null 2>&1 || true; return 0 ;;
    esac
  done
  return 0
}

# act_on_week <btn-name> <confirm-regex> — click the control on every owned card, one at
# a time, requiring the owned count to DROP before continuing. A decreasing count cannot
# be faked by a click that did nothing, which a text match can.
act_on_week() {
  local btn="$1" re="$2" n=0 before after i
  while [ "$n" -lt 30 ]; do
    before="$(owned_with "$btn")"
    [ "$before" = "0" ] && break
    [ "$(pw "() => { const card=$(_card_js); const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return 'N'; for(const b of [...g.querySelectorAll('.mx-name-$btn')]){ if(card(b)){ b.click(); return 'Y'; } } return 'N'; }")" = "Y" ] || break
    sleep 2
    confirm_dialog "$re"
    sleep 2
    seed_force_clear >/dev/null 2>&1 || true
    after="$before"
    for i in $(seq 1 10); do
      after="$(owned_with "$btn")"
      [ "$after" -lt "$before" ] 2>/dev/null && break
      seed_force_clear >/dev/null 2>&1 || true
      sleep 2
    done
    if [ "$after" -lt "$before" ] 2>/dev/null; then
      n=$((n + 1))
    else
      log "      !! a card did not leave after .mx-name-$btn ($before still owned) — moving on"
      break
    fi
  done
  echo "$n"
}

# reject_owned — reject every owned card on the current view.
# Main.ACT_Page_Reject hard-blocks on an empty comment, so one is typed first.
reject_owned() {
  local n=0 before after i
  while [ "$n" -lt 30 ]; do
    before="$(owned_with btnReject)"
    [ "$before" = "0" ] && break
    [ "$(pw "() => { const card=$(_card_js); const g=document.querySelector('.mx-name-galTabEntries'); if(!g) return 'N'; for(const b of [...g.querySelectorAll('.mx-name-btnReject')]){ if(card(b)){ b.click(); return 'Y'; } } return 'N'; }")" = "Y" ] || break
    sleep 3
    pw "() => { const vis=[...document.querySelectorAll('.mx-window-content,.mx-dialog-content,.modal-content,[role=dialog]')].filter(d=>d.offsetParent!==null); const scope=vis.length? vis[vis.length-1] : document; const f=[...scope.querySelectorAll('textarea,input[type=text]')].filter(e=>e.offsetParent!==null && !e.disabled && !e.readOnly)[0]; if(!f) return 'NOFIELD'; const set=Object.getOwnPropertyDescriptor(f.constructor.prototype,'value').set; set.call(f,'Seeded rejection for regression testing'); f.dispatchEvent(new Event('input',{bubbles:true})); f.dispatchEvent(new Event('change',{bubbles:true})); f.blur(); return 'TYPED'; }" >/dev/null
    sleep 2
    confirm_dialog '^(reject|yes|confirm|ok)$'
    sleep 2
    seed_force_clear >/dev/null 2>&1 || true
    after="$before"
    for i in $(seq 1 10); do
      after="$(owned_with btnReject)"
      [ "$after" -lt "$before" ] 2>/dev/null && break
      sleep 2
    done
    if [ "$after" -lt "$before" ] 2>/dev/null; then n=$((n + 1)); else
      log "      !! a card did not leave after Reject ($before still owned) — moving on"; break
    fi
  done
  echo "$n"
}

# hr_drive_week <label> <stage> — push one week as far as its stage says. Cumulative: an
# entry cannot be Processed before it has cleared both approval tabs.
hr_drive_week() {
  local label="$1" stage="$2" got
  case "$stage" in
    export|process|approve_all|approve_mgr|reject)
      if seed_click_tab "MANAGER APPROVAL" && select_week "$label"; then
        got="$(act_on_week btnApprove '^approve$')"; log "    MANAGER APPROVAL: approved $got"
      else log "    MANAGER APPROVAL: '$label' not offered"; fi ;;
  esac
  case "$stage" in
    export|process|approve_all|reject)
      if seed_click_tab "CLIENT APPROVAL" && select_week "$label"; then
        got="$(act_on_week btnApprove '^approve$')"; log "    CLIENT APPROVAL: approved $got"
      else log "    CLIENT APPROVAL: '$label' not offered"; fi ;;
  esac
  case "$stage" in
    reject)
      if seed_click_tab "WEEKLY TO PROCESS" && select_week "$label"; then
        got="$(reject_owned)"; log "    WEEKLY TO PROCESS: rejected $got"
      else log "    WEEKLY TO PROCESS: '$label' not offered"; fi ;;
    process|export)
      if seed_click_tab "WEEKLY TO PROCESS" && select_week "$label"; then
        got="$(act_on_week btnProcess '^(process|view & process|yes|confirm|ok|approve)$')"
        log "    WEEKLY TO PROCESS: processed $got"
      else log "    WEEKLY TO PROCESS: '$label' not offered"; fi ;;
  esac
  case "$stage" in
    export) hr_export_all ;;
  esac
}

# hr_export_all — drive AwaitingExport -> Exported on MONTHLY TO BE INVOICED.
#
# THIS TAB IS DIFFERENT FROM THE OTHERS. It uses .mx-name-galInvoiceEntries and
# .mx-name-galAvailableMonths rather than the galTab* widgets every other tab uses, which
# is why the generic helpers read it as empty. It also has no per-card action: export is a
# single page-level .mx-name-btnExportAll ("Export") that exports EVERYTHING on the tab in
# one go (Main.ACT_ExportAll_HRDash), and it is month-scoped, not week-scoped.
#
# BULK MEANS IT CANNOT BE OWNERSHIP-FILTERED. Every other stage clicks a control on one
# card at a time and only ever touches cards belonging to the e2e consultants. Export
# cannot do that — so this REFUSES to run when the tab holds any entry that is not one of
# ours, rather than exporting a colleague's timesheets as a side effect of seeding.
hr_export_all() {
  seed_click_tab "MONTHLY TO BE INVOICED" || { log "    MONTHLY TO BE INVOICED: tab not clickable"; return 1; }
  sleep 4

  local counts total owned
  counts="$(pw "() => { const card=$(_card_js); const g=document.querySelector('.mx-name-galInvoiceEntries'); if(!g) return 'NOGAL'; const items=[...g.querySelectorAll('.widget-gallery-item')]; let own=0; for(const it of items){ const f=(it.innerText||'').trim().split('\n')[0].trim(); if(card(it)||$(owned_js)) own++; } return items.length+'/'+own; }")"
  case "$counts" in
    NOGAL|'') log "    MONTHLY TO BE INVOICED: entry gallery not rendered"; return 1 ;;
  esac
  total="${counts%%/*}"; owned="${counts##*/}"
  log "    MONTHLY TO BE INVOICED: $total entr(ies) on the tab, $owned owned by the e2e consultants"

  if [ "$total" = "0" ]; then
    log "    nothing to export"
    return 0
  fi
  if [ "$total" != "$owned" ]; then
    log "    !! REFUSING to Export: $((total - owned)) entr(ies) on this tab belong to someone else."
    log "       Export is a single bulk action with no per-card selection, so running it"
    log "       would export their timesheets too. Clear the tab or export by hand."
    return 1
  fi

  playwright-cli click ".mx-name-btnExportAll" >/dev/null 2>&1
  sleep 3
  confirm_dialog '^(export|yes|confirm|ok|continue)$'
  sleep 3
  seed_force_clear >/dev/null 2>&1 || true

  # Verify against the dashboard, not the click: the invoice counter must fall.
  local i after
  for i in $(seq 1 10); do
    after="$(pw "() => { const c=document.querySelector('.mx-name-cardKpiInvoice'); if(!c) return '?'; const m=(c.innerText||'').trim().match(/(\d+)\s*$/); return m?m[1]:'?'; }")"
    case "$after" in ''|'?') : ;; *) [ "$after" -lt "$total" ] 2>/dev/null && { log "    exported — invoice count $total -> $after"; return 0; } ;;
    esac
    sleep 3
  done
  log "    !! Export clicked but the invoice count did not fall (still ${after:-?})"
  return 1
}

# ===================================================================== main

log "target: $TT_BASE"
[ "$PROVE" = "1" ] && log "PROVE MODE — one consultant, one week, then stop"

# Where the consultant phase records what it actually seeded, so the HR phase drives the
# real weeks rather than a hardcoded guess. Kept if SEED_KEEP_PLAN=1 so a failed HR pass
# can be retried with SEED_SKIP_SUBMIT=1 without redoing the submits.
PLAN_FILE="${SEED_PLAN_FILE:-/tmp/tt-seed-plan.txt}"
if [ "${SEED_SKIP_SUBMIT:-0}" != "1" ]; then
  : > "$PLAN_FILE"
fi

if [ "${SEED_SKIP_SUBMIT:-0}" != "1" ]; then
  OLD="$IFS"; IFS='|'
  for U in $CONSULTANTS; do
    IFS="$OLD"
    [ -n "$U" ] || continue
    seed_consultant "$U"
    [ "$PROVE" = "1" ] && break
    IFS='|'
  done
  IFS="$OLD"
fi

if [ "${SEED_SKIP_HR:-0}" != "1" ] && [ "$PROVE" != "1" ]; then
  log "=== HR stages ==="
  if seed_login_role "e2e_hr" "WEEKLY TO PROCESS"; then
    log "  KPIs before (pending manager client process invoice sent): $(seed_kpis)"
    # Depth order, and approve_mgr LAST: its output sits on CLIENT APPROVAL, the tab
    # entries were observed drifting off within ~10 minutes, so it is left as fresh as
    # possible at handoff.
    if [ ! -s "$PLAN_FILE" ]; then
      log "  !! no seeded plan at $PLAN_FILE — run the consultant phase first, or point"
      log "     SEED_PLAN_FILE at the plan from that run"
    else
      for WANT in export process approve_all reject approve_mgr; do
        sort -u "$PLAN_FILE" | while IFS='|' read -r label stage pat; do
          [ -n "$label" ] || continue
          [ "$stage" = "$WANT" ] || continue
          log "  --- $label [$stage] ---"
          hr_drive_week "$label" "$stage"
        done
      done
    fi
    log "  KPIs after: $(seed_kpis)"
  else
    log "  !! cannot sign in as e2e_hr — no HR stage applied"
  fi
fi

log "done"

#!/usr/bin/env bash
# verify-scheduled-event-config.test.sh
#
# Pins the scheduled-event timing fix of 2026-08-19 so it cannot be quietly undone.
#
# WHY THIS EXISTS. Scheduled events are unreachable from every other angle: no
# browser can see them, the runtime does not expose them, and no unit test can
# reach them. A regression in when they fire would surface only as "the reminders
# went out at the wrong time", weeks later, to customers. The only thing that can
# see the setting is a static read of the model.
#
# WHAT WAS FIXED, AND WHY IT IS FRAGILE. The three weekly reminders were moved to
# 14:00 because Mendix Cloud runs the scheduler in UTC. Assignment_VerifyHours was
# deliberately LEFT at 00:00 monthly — it is a data job, not a message to a human,
# and moving it would shift which month's hours it verifies. The two look like the
# same setting and are not, which is exactly how a well-meaning "consistency" edit
# would break one of them. Two documents still describe the pre-fix 09:00 state,
# so the wrong value is written down in the repo and will be believed by somebody.
#
# WHAT IT ASSERTS
#   * the three weekly reminders fire at 14:00;
#   * Assignment_VerifyHours is still monthly at 00:00 on day 1;
#   * all five first-party events run through their _Guarded wrapper, which is what
#     keeps them from sending real mail on a test environment.
#
# WHAT IT CANNOT ASSERT. The TimeZone property is not readable with the vendored
# format reader — the member sits past a tag it does not decode. The hour is the
# visible half of the fix and is pinned here; the timezone half is not, and this
# says so rather than implying coverage it does not have.
#
# NO APP NEEDED. This reads the model on disk, so it is the one step in the suite
# that can run with nothing deployed. It also means it reads the LAST SAVED state:
# an unsaved change in Studio Pro is invisible to it.
#
# CI: skipped, because the suite is its own repository and the Mendix model is not
# checked out beside it there. See ci-skip.txt.
set -uo pipefail
# Resolve the suite root by walking up to the directory that holds lib/, so a test
# works at any nesting depth and still runs directly, not only via run-tests.sh.
TT_ROOT="$(cd "$(dirname "$0")" && while [ ! -d lib ] && [ "$PWD" != "/" ]; do cd ..; done; pwd)"

MODEL="${TT_MODEL_DIR:-$(cd "$TT_ROOT/.." && pwd)}"
[ -d "$MODEL/mprcontents" ] \
  || { echo "FAIL: verify-scheduled-event-config - no Mendix model at $MODEL/mprcontents."; \
       echo "      This step reads the model on disk. Set TT_MODEL_DIR, or skip it where the"; \
       echo "      model is not checked out (it is listed in ci-skip.txt for that reason)."; \
       exit 1; }

command -v python >/dev/null 2>&1 || { echo "FAIL: python not found - required to read the model"; exit 1; }

python - "$MODEL/mprcontents" "$TT_ROOT/tools" <<'PY'
import glob, os, sys
root, toolsdir = sys.argv[1], sys.argv[2]
sys.path.insert(0, toolsdir)
try:
    import mxunit
except Exception as e:
    print("FAIL: could not load the .mxunit reader (%s)" % e); sys.exit(1)

def kv(items): return {k: v for k, v in items}

events = {}
for f in glob.glob(os.path.join(root, "**", "*.mxunit"), recursive=True):
    try:
        m = kv(mxunit.load(f))
    except Exception:
        continue
    if m.get("$Type") != "ScheduledEvents$ScheduledEvent":
        continue
    sch = m.get("Schedule") or {}
    si = kv(sch.get("__items", [])) if isinstance(sch, dict) else {}
    events[m.get("Name")] = {
        "schedule": (si.get("$Type") or "").split("$")[-1],
        "hour": si.get("HourOfDay"),
        "minute": si.get("MinuteOfHour"),
        "day": si.get("DayOfMonth"),
        "microflow": m.get("Microflow") or "",
    }

# A reader that silently stopped understanding the format would report a clean
# scan over nothing at all. Refuse to pass on an implausible result.
if len(events) < 5:
    print("FAIL: only %d scheduled events parsed from the model." % len(events))
    print("      That is too few to be real - the .mxunit reader in tools/mxunit.py has")
    print("      probably stopped matching the format. Refusing to report a pass.")
    sys.exit(1)

print("  %-36s %-18s %5s %5s  %s" % ("NAME", "SCHEDULE", "HOUR", "MIN", "MICROFLOW"))
for n in sorted(events):
    e = events[n]
    print("  %-36s %-18s %5s %5s  %s" % (
        n, e["schedule"],
        "" if e["hour"] is None else e["hour"],
        "" if e["minute"] is None else e["minute"], e["microflow"]))
print("")

fails = []

WEEKLY_AT_14 = ["ToConsultant_SubmissionReminder", "ToCustomer_ApprovalRequest", "ToManager_ApprovalRequest"]
for n in WEEKLY_AT_14:
    e = events.get(n)
    if not e:
        fails.append("%s is missing from the model entirely" % n); continue
    if e["schedule"] != "WeekSchedule":
        fails.append("%s is a %s, expected WeekSchedule" % (n, e["schedule"]))
    if (e["hour"], e["minute"]) != (14, 0):
        fails.append("%s fires at %s:%02d, expected 14:00 - the 2026-08-19 UTC fix has been undone"
                     % (n, e["hour"], e["minute"] or 0))

v = events.get("Assignment_VerifyHours")
if not v:
    fails.append("Assignment_VerifyHours is missing from the model entirely")
else:
    if v["schedule"] != "MonthDateSchedule":
        fails.append("Assignment_VerifyHours is a %s, expected MonthDateSchedule" % v["schedule"])
    if (v["hour"], v["minute"], v["day"]) != (0, 0, 1):
        fails.append("Assignment_VerifyHours runs at %s:%02d on day %s, expected 00:00 on day 1. "
                     "It is a data job and was deliberately NOT moved to 14:00 with the reminders - "
                     "shifting it changes which month's hours get verified"
                     % (v["hour"], v["minute"] or 0, v["day"]))

GUARDED = {
    "ToConsultant_SubmissionReminder": "Main.SCE_ToConsultant_SubmissionReminder_Guarded",
    "ToCustomer_ApprovalRequest":      "Main.SCE_ToCustomer_ApprovalRequest_Guarded",
    "ToManager_ApprovalRequest":       "Main.SCE_ToManager_ApprovalRequest_Guarded",
    "Assignment_VerifyHours":          "Main.SCE_Assignment_VerifyHours_Guarded",
    "Timesheet_CleanupEmptyDrafts":    "Core.SCE_Timesheet_CleanupEmptyDrafts_Guarded",
}
for n, want in GUARDED.items():
    e = events.get(n)
    if e and e["microflow"] != want:
        fails.append("%s calls %s, expected the guarded wrapper %s - without it the event can act "
                     "for real on a test environment" % (n, e["microflow"] or "(nothing)", want))

if fails:
    print("FAIL: verify-scheduled-event-config - %d setting(s) not as pinned:" % len(fails))
    for f in fails:
        print("  * %s" % f)
    sys.exit(1)

print("PASS: verify-scheduled-event-config - 3 weekly reminders at 14:00, "
      "Assignment_VerifyHours still 00:00 monthly, all 5 first-party events guarded "
      "(%d events read; TimeZone not machine-readable, see header)" % len(events))
PY

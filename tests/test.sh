#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR_SCRIPT="${REPO_ROOT}/gemini-chrome-doctor.sh"
TEST_ROOT="$(mktemp -d)"
FAKE_BIN="${TEST_ROOT}/bin"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"

cat >"${FAKE_BIN}/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *www.cloudflare.com/cdn-cgi/trace*)
    printf 'loc=%s\n' "${FAKE_COUNTRY:-US}"
    ;;
  *)
    printf 'Unexpected fake curl request: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH

cat >"${FAKE_BIN}/osascript" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *'application "Google Chrome" is running'*)
    if [ -n "${FAKE_CHROME_RUNNING_FILE:-}" ] && [ -e "$FAKE_CHROME_RUNNING_FILE" ]; then
      printf '%s\n' 'true'
    else
      printf '%s\n' 'false'
    fi
    ;;
  *'tell application "Google Chrome" to quit'*)
    [ -n "${FAKE_CHROME_RUNNING_FILE:-}" ] && rm -f -- "$FAKE_CHROME_RUNNING_FILE"
    ;;
  *) printf '%s\n' '1 windows, 1 tabs' ;;
esac
SH

cat >"${FAKE_BIN}/open" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_CHROME_DATA_DIR:?}"
: "${FAKE_CHROME_RUNNING_FILE:?}"
python3 - "$FAKE_CHROME_DATA_DIR/Local State" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["variations_country"] = "us"
data["variations_permanent_consistency_country"] = ["155.0.0.0", "us"]
data["variations_safe_seed_session_consistency_country"] = "us"
path.write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")
PY
touch "$FAKE_CHROME_RUNNING_FILE"
SH

cat >"${FAKE_BIN}/ps" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat >"${FAKE_BIN}/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Darwin'
SH

chmod +x \
  "${FAKE_BIN}/curl" \
  "${FAKE_BIN}/open" \
  "${FAKE_BIN}/osascript" \
  "${FAKE_BIN}/ps" \
  "${FAKE_BIN}/uname"

make_fixture() {
  local fixture_dir="$1"
  mkdir -p "${fixture_dir}/Profile 5"

  cat >"${fixture_dir}/Local State" <<'JSON'
{
  "profile": {"last_used": "Profile 5"},
  "unrelated": {"keep": true},
  "variations_country": "cn",
  "variations_permanent_consistency_country": ["155.0.0.0", "cn"],
  "variations_safe_seed_permanent_consistency_country": "kr",
  "variations_safe_seed_session_consistency_country": "cn",
  "variations_geo_level1": "",
  "variations_google_groups": {"example": "reset-me"},
  "variations_last_fetch_time": "123",
  "variations_safe_seed_date": "123",
  "variations_safe_seed_signature": "signature",
  "variations_seed_date": "123",
  "variations_seed_signature": "signature",
  "variations_sticky_studies": "studies",
  "variations_crash_streak": 0,
  "variations_failed_to_fetch_seed_streak": 0
}
JSON

  cat >"${fixture_dir}/Profile 5/Preferences" <<'JSON'
{
  "account_info": [{}],
  "account_values": {"sync": {"glic_rollout_eligibility": true}},
  "glic": {
    "onboarding_status": 5,
    "profile_enablement": {"last_ready_state": 5}
  },
  "profile": {}
}
JSON

  printf '%s\n' 'legacy seed' >"${fixture_dir}/Variations"
  printf '%s\n' 'seed v2' >"${fixture_dir}/VariationsSeedV2"
  printf '%s\n' 'safe seed v2' >"${fixture_dir}/VariationsSafeSeedV2"
}

run_doctor() {
  PATH="${FAKE_BIN}:${PATH}" \
    FAKE_COUNTRY="${FAKE_COUNTRY:-US}" \
    FAKE_CHROME_DATA_DIR="${FAKE_CHROME_DATA_DIR:-}" \
    FAKE_CHROME_RUNNING_FILE="${FAKE_CHROME_RUNNING_FILE:-}" \
    "$DOCTOR_SCRIPT" "$@"
}

bash -n "$DOCTOR_SCRIPT"
bash -n "$0"
"$DOCTOR_SCRIPT" --help | grep -q -- '--reset-seeds'

diagnose_dir="${TEST_ROOT}/diagnose"
make_fixture "$diagnose_dir"
diagnose_output="$(run_doctor diagnose \
  --chrome-data-dir "$diagnose_dir" \
  --skip-network-tests)"

printf '%s\n' "$diagnose_output" | grep -q 'Ready state: 5 (LocationMismatch)'
printf '%s\n' "$diagnose_output" | grep -q 'Current country: cn'
printf '%s\n' "$diagnose_output" | grep -q 'Distinct cached countries: cn,kr'
printf '%s\n' "$diagnose_output" | grep -q 'Seed country conflict: true'
printf '%s\n' "$diagnose_output" | grep -q 'Variations=present'
printf '%s\n' "$diagnose_output" | grep -q 'Network checks: skipped'

standard_dir="${TEST_ROOT}/standard"
make_fixture "$standard_dir"
standard_output="$(run_doctor repair-location \
  --country us \
  --apply \
  --chrome-data-dir "$standard_dir")"

printf '%s\n' "$standard_output" | grep -q 'Repair mode: update three country fields'
jq -e '
  .variations_country == "us" and
  .variations_permanent_consistency_country[1] == "us" and
  .variations_safe_seed_session_consistency_country == "us" and
  .variations_safe_seed_permanent_consistency_country == "kr" and
  .unrelated.keep == true
' "${standard_dir}/Local State" >/dev/null
test -f "${standard_dir}/Variations"
test -f "${standard_dir}/VariationsSeedV2"
test -f "${standard_dir}/VariationsSafeSeedV2"
find "$standard_dir" -maxdepth 1 -name 'Local State.gemini-chrome-doctor-backup-*' \
  | grep -q .

reset_dir="${TEST_ROOT}/reset"
make_fixture "$reset_dir"
reset_output="$(run_doctor repair-location \
  --country us \
  --apply \
  --reset-seeds \
  --chrome-data-dir "$reset_dir")"

printf '%s\n' "$reset_output" | grep -q 'Repair mode: reset global Variations seeds'
printf '%s\n' "$reset_output" | grep -q 'Seed backups: 3'
jq -e '
  (.unrelated.keep == true) and
  (.variations_crash_streak == 0) and
  (.variations_failed_to_fetch_seed_streak == 0) and
  (has("variations_country") | not) and
  (has("variations_permanent_consistency_country") | not) and
  (has("variations_safe_seed_permanent_consistency_country") | not) and
  (has("variations_safe_seed_session_consistency_country") | not) and
  (has("variations_google_groups") | not) and
  (has("variations_seed_signature") | not)
' "${reset_dir}/Local State" >/dev/null
test ! -e "${reset_dir}/Variations"
test ! -e "${reset_dir}/VariationsSeedV2"
test ! -e "${reset_dir}/VariationsSafeSeedV2"
test "$(find "$reset_dir" -maxdepth 1 -name '*.gemini-chrome-doctor-backup-*' | wc -l | tr -d ' ')" = "4"

restart_dir="${TEST_ROOT}/restart"
restart_running_file="${TEST_ROOT}/chrome-running"
make_fixture "$restart_dir"
restart_output="$(
  FAKE_CHROME_DATA_DIR="$restart_dir" \
  FAKE_CHROME_RUNNING_FILE="$restart_running_file" \
  run_doctor repair-location \
    --country us \
    --apply \
    --reset-seeds \
    --restart \
    --chrome-data-dir "$restart_dir"
)"
printf '%s\n' "$restart_output" | grep -q 'Fresh Variations country: us'
printf '%s\n' "$restart_output" | grep -q 'No runtime country override was used'
test -e "$restart_running_file"
jq -e '
  .variations_country == "us" and
  .variations_permanent_consistency_country[1] == "us" and
  .variations_safe_seed_session_consistency_country == "us"
' "${restart_dir}/Local State" >/dev/null

guard_dir="${TEST_ROOT}/country-guard"
make_fixture "$guard_dir"
guard_hash_before="$(shasum -a 256 "${guard_dir}/Local State" | awk '{print $1}')"
if FAKE_COUNTRY=CA run_doctor repair-location \
  --country us \
  --apply \
  --reset-seeds \
  --chrome-data-dir "$guard_dir" >/dev/null 2>&1; then
  printf '%s\n' 'Country mismatch guard unexpectedly succeeded' >&2
  exit 1
fi
guard_hash_after="$(shasum -a 256 "${guard_dir}/Local State" | awk '{print $1}')"
test "$guard_hash_before" = "$guard_hash_after"

no_seed_dir="${TEST_ROOT}/no-seed"
make_fixture "$no_seed_dir"
rm -f "${no_seed_dir}/Variations" "${no_seed_dir}/VariationsSeedV2" "${no_seed_dir}/VariationsSafeSeedV2"
if run_doctor repair-location \
  --country us \
  --apply \
  --reset-seeds \
  --chrome-data-dir "$no_seed_dir" >/dev/null 2>&1; then
  printf '%s\n' 'Seed reset without seed files unexpectedly succeeded' >&2
  exit 1
fi

if run_doctor repair-location \
  --country us \
  --reset-seeds \
  --chrome-data-dir "$reset_dir" >/dev/null 2>&1; then
  printf '%s\n' 'Seed reset without --apply unexpectedly succeeded' >&2
  exit 1
fi

if run_doctor diagnose --reset-seeds \
  --chrome-data-dir "$diagnose_dir" >/dev/null 2>&1; then
  printf '%s\n' '--reset-seeds with diagnose unexpectedly succeeded' >&2
  exit 1
fi

echo 'All tests passed.'

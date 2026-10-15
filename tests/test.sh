#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR_SCRIPT="${REPO_ROOT}/gemini-chrome-doctor.sh"
FIXTURE_DIR="$(mktemp -d)"

cleanup() {
  rm -rf -- "$FIXTURE_DIR"
}
trap cleanup EXIT

bash -n "$DOCTOR_SCRIPT"
"$DOCTOR_SCRIPT" --help | grep -q 'repair-location'

mkdir -p "$FIXTURE_DIR/Profile 5"

cat > "$FIXTURE_DIR/Local State" <<'JSON'
{
  "profile": {"last_used": "Profile 5"},
  "variations_country": "cn",
  "variations_permanent_consistency_country": ["155.0.0.0", "cn"],
  "variations_safe_seed_permanent_consistency_country": "kr",
  "variations_safe_seed_session_consistency_country": "cn",
  "variations_crash_streak": 0,
  "variations_failed_to_fetch_seed_streak": 0
}
JSON

cat > "$FIXTURE_DIR/Profile 5/Preferences" <<'JSON'
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

diagnose_output="$($DOCTOR_SCRIPT diagnose \
  --chrome-data-dir "$FIXTURE_DIR" \
  --skip-network-tests)"

printf '%s\n' "$diagnose_output" | grep -q 'Ready state: 5 (LocationMismatch)'
printf '%s\n' "$diagnose_output" | grep -q 'Current country: cn'
printf '%s\n' "$diagnose_output" | grep -q 'Network checks: skipped'

echo 'All tests passed.'

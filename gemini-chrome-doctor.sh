#!/usr/bin/env bash

set -euo pipefail

PROGRAM_NAME="gemini-chrome-doctor"
CHROME_APP_NAME="Google Chrome"
CHROME_EXECUTABLE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DEFAULT_CHROME_DATA_DIR="${HOME}/Library/Application Support/Google/Chrome"

COMMAND="diagnose"
CHROME_DATA_DIR="$DEFAULT_CHROME_DATA_DIR"
TARGET_COUNTRY=""
APPLY_CHANGES=false
RESTART_CHROME=false
SKIP_NETWORK_TESTS=false
NETWORK_TRIALS=5

usage() {
  cat <<'EOF'
Gemini in Chrome Doctor (macOS)

Usage:
  gemini-chrome-doctor.sh [diagnose] [options]
  gemini-chrome-doctor.sh repair-location --country CC --apply [--restart]

Commands:
  diagnose          Read-only local and network diagnosis (default).
  repair-location   Repair stale Variations country cache.

Options:
  --country CC             Two-letter country code for repair-location.
  --apply                  Required before any configuration write.
  --restart                Gracefully restart Chrome and restore the session.
  --trials N               Network attempts per endpoint (default: 5).
  --skip-network-tests     Skip external checks during diagnose.
  --chrome-data-dir PATH   Override the Chrome user-data directory.
  -h, --help               Show this help.

Safety:
  repair-location refuses to run unless the detected public network country
  matches --country. It creates a timestamped Local State backup and changes
  only three Variations country fields.
EOF
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ready_state_name() {
  case "$1" in
    0) printf 'UnknownError' ;;
    1) printf 'SignInRequired' ;;
    2) printf 'Ready' ;;
    3) printf 'Ineligible' ;;
    4) printf 'DisabledByAdmin' ;;
    5) printf 'LocationMismatch' ;;
    6) printf 'IneligibleAccount' ;;
    *) printf 'Unknown(%s)' "$1" ;;
  esac
}

chrome_is_running() {
  [ "$(osascript -e 'application "Google Chrome" is running' 2>/dev/null)" = "true" ]
}

chrome_main_process_count() {
  local count
  count="$(ps -ww -axo command= | grep -E -c '^/Applications/Google Chrome\.app/Contents/MacOS/Google Chrome($| )' || true)"
  printf '%s' "${count:-0}"
}

chrome_session_counts() {
  osascript <<'APPLESCRIPT'
tell application "Google Chrome"
  set windowCount to count of windows
  set tabCount to 0
  repeat with chromeWindow in windows
    set tabCount to tabCount + (count of tabs of chromeWindow)
  end repeat
  return (windowCount as text) & " windows, " & (tabCount as text) & " tabs"
end tell
APPLESCRIPT
}

detect_public_country() {
  curl -fsSL --max-time 15 'https://www.cloudflare.com/cdn-cgi/trace' \
    | awk -F= '$1 == "loc" {print toupper($2); exit}'
}

wait_for_chrome_stop() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! chrome_is_running && [ "$(chrome_main_process_count)" = "0" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_chrome_start() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if chrome_is_running; then
      return 0
    fi
    sleep 1
  done
  return 1
}

network_trials() {
  local label="$1"
  local url="$2"
  local success=0
  local failure=0
  local codes=""
  local trial
  local code

  for trial in $(seq 1 "$NETWORK_TRIALS"); do
    code="$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    [ -n "$code" ] || code="000"
    if [ "$code" != "000" ]; then
      success=$((success + 1))
    else
      failure=$((failure + 1))
    fi
    if [ -n "$codes" ]; then
      codes="${codes},${code}"
    else
      codes="$code"
    fi
  done

  printf '%-20s success=%s failure=%s http_codes=%s\n' \
    "$label" "$success" "$failure" "$codes"
}

parse_args() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      diagnose|repair-location)
        COMMAND="$1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
    esac
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --country)
        [ "$#" -ge 2 ] || die "--country requires a value"
        TARGET_COUNTRY="$2"
        shift 2
        ;;
      --apply)
        APPLY_CHANGES=true
        shift
        ;;
      --restart)
        RESTART_CHROME=true
        shift
        ;;
      --trials)
        [ "$#" -ge 2 ] || die "--trials requires a value"
        NETWORK_TRIALS="$2"
        shift 2
        ;;
      --skip-network-tests)
        SKIP_NETWORK_TESTS=true
        shift
        ;;
      --chrome-data-dir)
        [ "$#" -ge 2 ] || die "--chrome-data-dir requires a path"
        CHROME_DATA_DIR="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  case "$NETWORK_TRIALS" in
    ''|*[!0-9]*) die "--trials must be a positive integer" ;;
  esac
  [ "$NETWORK_TRIALS" -gt 0 ] || die "--trials must be greater than zero"
}

load_paths() {
  LOCAL_STATE="${CHROME_DATA_DIR}/Local State"
  [ -f "$LOCAL_STATE" ] || die "Chrome Local State not found: $LOCAL_STATE"

  PROFILE_DIRECTORY="$(jq -r '.profile.last_used // "Default"' "$LOCAL_STATE")"
  case "$PROFILE_DIRECTORY" in
    ''|*/*|..)
      die "Unexpected Chrome profile directory value"
      ;;
  esac

  PROFILE_PREFERENCES="${CHROME_DATA_DIR}/${PROFILE_DIRECTORY}/Preferences"
  [ -f "$PROFILE_PREFERENCES" ] \
    || die "Chrome profile Preferences not found: $PROFILE_PREFERENCES"
}

diagnose() {
  local ready_state
  local ready_name
  local exit_country
  local override_count

  log "== Chrome =="
  if [ -x "$CHROME_EXECUTABLE" ]; then
    "$CHROME_EXECUTABLE" --version
  else
    warn "Google Chrome executable was not found at the standard path"
  fi
  printf 'Profile directory: %s\n' "$PROFILE_DIRECTORY"

  if chrome_is_running; then
    printf 'Session: %s\n' "$(chrome_session_counts)"
  else
    log 'Session: Chrome is not running'
  fi

  override_count="$(ps -ww -axo command= \
    | grep -E -c '^/Applications/Google Chrome\.app/Contents/MacOS/Google Chrome.*--variations-override-country=' \
    || true)"
  if [ "${override_count:-0}" -gt 0 ]; then
    log 'Runtime country override: present'
  else
    log 'Runtime country override: absent'
  fi

  log ''
  log '== Gemini in Chrome / Glic =='
  ready_state="$(jq -r '.glic.profile_enablement.last_ready_state // -1' "$PROFILE_PREFERENCES")"
  ready_name="$(ready_state_name "$ready_state")"
  printf 'Rollout eligible: %s\n' \
    "$(jq -r '.account_values.sync.glic_rollout_eligibility // "unset"' "$PROFILE_PREFERENCES")"
  printf 'Ready state: %s (%s)\n' "$ready_state" "$ready_name"
  printf 'Onboarding status: %s\n' \
    "$(jq -r '.glic.onboarding_status // "unset"' "$PROFILE_PREFERENCES")"
  printf 'Signed-in account present: %s\n' \
    "$(jq -r '((.account_info // []) | length) > 0' "$PROFILE_PREFERENCES")"
  printf 'Workspace account: %s\n' \
    "$(jq -r 'any(.account_info[]?; ((.hosted_domain // "") != "" and (.hosted_domain // "") != "NO_HOSTED_DOMAIN_FOUND"))' "$PROFILE_PREFERENCES")"
  printf 'Child/supervised account: %s\n' \
    "$(jq -r '(any(.account_info[]?; (.is_child_account // false)) or (.profile.is_child_account // false) or (((.profile.managed_user_id // "") | length) > 0))' "$PROFILE_PREFERENCES")"

  log ''
  log '== Variations country cache =='
  jq -r '
    "Current country: \(.variations_country // "unset")",
    "Permanent country: \(.variations_permanent_consistency_country[1] // "unset")",
    "Safe-seed permanent country: \(.variations_safe_seed_permanent_consistency_country // "unset")",
    "Safe-seed session country: \(.variations_safe_seed_session_consistency_country // "unset")",
    "Crash streak: \(.variations_crash_streak // "unset")",
    "Failed seed fetch streak: \(.variations_failed_to_fetch_seed_streak // "unset")"
  ' "$LOCAL_STATE"

  if [ "$SKIP_NETWORK_TESTS" = true ]; then
    log ''
    log 'Network checks: skipped'
    return
  fi

  log ''
  log '== Network =='
  exit_country="$(detect_public_country || true)"
  printf 'Public network country: %s\n' "${exit_country:-unavailable}"
  network_trials 'Glic status API' 'https://geminiweb-pa.googleapis.com/v1/glicStatus'
  network_trials 'Gemini web' 'https://gemini.google.com/'
  network_trials 'Google accounts' 'https://accounts.google.com/'
}

repair_location() {
  local target_lower
  local target_upper
  local exit_country
  local chrome_was_running=false
  local pre_restart_counts=""
  local timestamp
  local backup_path
  local temp_path=""
  local original_hash
  local backup_hash
  local original_mode
  local original_remainder_hash
  local new_remainder_hash

  [ "$APPLY_CHANGES" = true ] \
    || die "repair-location requires --apply"
  [ -n "$TARGET_COUNTRY" ] \
    || die "repair-location requires --country CC"

  target_lower="$(printf '%s' "$TARGET_COUNTRY" | tr '[:upper:]' '[:lower:]')"
  target_upper="$(printf '%s' "$TARGET_COUNTRY" | tr '[:lower:]' '[:upper:]')"
  case "$target_lower" in
    [a-z][a-z]) ;;
    *) die "--country must be a two-letter country code" ;;
  esac

  exit_country="$(detect_public_country || true)"
  [ -n "$exit_country" ] || die "Could not detect the public network country"
  [ "$exit_country" = "$target_upper" ] || die \
    "Public network country is $exit_country, not $target_upper; refusing to modify Chrome"

  jq -e '
    (.variations_country | type) == "string" and
    (.variations_permanent_consistency_country | type) == "array" and
    (.variations_permanent_consistency_country | length) > 1 and
    (.variations_safe_seed_session_consistency_country | type) == "string"
  ' "$LOCAL_STATE" >/dev/null || die "Unexpected Variations country structure"

  log "Detected public country: $exit_country"
  log 'Current cache:'
  jq '{
    current_country: .variations_country,
    permanent_country: .variations_permanent_consistency_country[1],
    safe_seed_session_country: .variations_safe_seed_session_consistency_country
  }' "$LOCAL_STATE"

  if chrome_is_running; then
    chrome_was_running=true
    [ "$RESTART_CHROME" = true ] || die \
      "Chrome is running. Close it first or rerun with --restart."
    pre_restart_counts="$(chrome_session_counts)"
    log "Chrome session before restart: $pre_restart_counts"
    osascript -e 'tell application "Google Chrome" to quit'
    wait_for_chrome_stop || die \
      "Chrome did not completely exit; no force quit was attempted"
    log 'Chrome graceful quit: complete'
  elif [ "$(chrome_main_process_count)" != "0" ]; then
    die "A Chrome main process is still running"
  fi

  jq -e '
    (.variations_country | type) == "string" and
    (.variations_permanent_consistency_country | type) == "array" and
    (.variations_permanent_consistency_country | length) > 1 and
    (.variations_safe_seed_session_consistency_country | type) == "string"
  ' "$LOCAL_STATE" >/dev/null || die "Variations structure changed during shutdown"

  timestamp="$(date '+%Y%m%d-%H%M%S')"
  backup_path="${LOCAL_STATE}.${PROGRAM_NAME}-backup-${timestamp}"
  cp -p "$LOCAL_STATE" "$backup_path"

  original_hash="$(shasum -a 256 "$LOCAL_STATE" | awk '{print $1}')"
  backup_hash="$(shasum -a 256 "$backup_path" | awk '{print $1}')"
  [ "$original_hash" = "$backup_hash" ] || die "Backup hash mismatch"

  temp_path="$(mktemp "${LOCAL_STATE}.${PROGRAM_NAME}-tmp.XXXXXX")"
  trap 'if [ -n "${temp_path:-}" ] && [ -e "$temp_path" ]; then rm -f -- "$temp_path"; fi' EXIT

  jq -c --arg country "$target_lower" '
    .variations_country = $country
    | .variations_permanent_consistency_country[1] = $country
    | .variations_safe_seed_session_consistency_country = $country
  ' "$LOCAL_STATE" > "$temp_path"

  original_mode="$(stat -f '%Lp' "$LOCAL_STATE")"
  chmod "$original_mode" "$temp_path"
  jq empty "$temp_path"

  original_remainder_hash="$(jq -S '
    del(
      .variations_country,
      .variations_permanent_consistency_country[1],
      .variations_safe_seed_session_consistency_country
    )
  ' "$LOCAL_STATE" | shasum -a 256 | awk '{print $1}')"
  new_remainder_hash="$(jq -S '
    del(
      .variations_country,
      .variations_permanent_consistency_country[1],
      .variations_safe_seed_session_consistency_country
    )
  ' "$temp_path" | shasum -a 256 | awk '{print $1}')"
  [ "$original_remainder_hash" = "$new_remainder_hash" ] \
    || die "Non-target configuration differs; refusing to write"

  mv "$temp_path" "$LOCAL_STATE"
  temp_path=""
  trap - EXIT

  log "Backup: $backup_path"
  log 'Updated cache:'
  jq '{
    current_country: .variations_country,
    permanent_country: .variations_permanent_consistency_country[1],
    safe_seed_session_country: .variations_safe_seed_session_consistency_country
  }' "$LOCAL_STATE"

  if [ "$RESTART_CHROME" = true ]; then
    open -a "$CHROME_APP_NAME" --args \
      "--profile-directory=${PROFILE_DIRECTORY}" \
      '--restore-last-session' \
      "--variations-override-country=${target_lower}"
    wait_for_chrome_start || die "Chrome did not start within 20 seconds"
    sleep 8
    log "Chrome session after restart: $(chrome_session_counts)"
    log 'Runtime country override: enabled for this Chrome session only'
    log 'Click Ask Gemini once, then rerun diagnose to read the updated state.'
  elif [ "$chrome_was_running" = true ]; then
    warn 'Chrome was previously running but was not restarted'
  else
    log 'Chrome remains closed. Start it normally or rerun with --restart.'
  fi
}

main() {
  parse_args "$@"

  require_command jq
  require_command curl
  require_command osascript
  require_command shasum
  require_command ps

  [ "$(uname -s)" = "Darwin" ] || die "This tool currently supports macOS only"
  load_paths

  case "$COMMAND" in
    diagnose) diagnose ;;
    repair-location) repair_location ;;
    *) die "Unsupported command: $COMMAND" ;;
  esac
}

main "$@"

# Gemini in Chrome Doctor

**English** | [简体中文](README.zh-CN.md)

A read-only-first diagnostic tool for macOS that separates and helps resolve
two easily confused Gemini in Chrome / Ask Gemini failure classes:

1. eligibility or location filtering in Chrome's native Glic host;
2. network or loading failures in the embedded Gemini web client after the
   native eligibility checks pass.

> [!IMPORTANT]
> This is not an official Google tool, and it is not intended to bypass
> regional restrictions. The location repair command runs only when the
> current public network country exactly matches the requested country. Its
> purpose is to repair stale or incorrect Chrome Variations country cache.

## Why Ask Gemini can fail even when the regular Gemini website works

Gemini in Chrome is not a regular extension or merely a
`gemini.google.com` tab. It has two layers: a native Chrome host and an
embedded web client.

- Chromium calls the native host **Glic**.
- Chrome evaluates account, policy, country, locale, system, and rollout
  eligibility.
- After those checks pass, the host loads Google's embedded Gemini client.
- A location error and a generic “Something went wrong” message therefore
  usually come from different layers.

### Common ready states

Chromium currently defines `ProfileReadyState` as follows:

| Value | State | Meaning |
|---:|---|---|
| 0 | `UnknownError` | An unknown native-host error |
| 1 | `SignInRequired` | Chrome requires sign-in |
| 2 | `Ready` | Native-host eligibility checks passed |
| 3 | `Ineligible` | General eligibility checks failed |
| 4 | `DisabledByAdmin` | Disabled by administrator policy |
| 5 | `LocationMismatch` | Country filtering failed |
| 6 | `IneligibleAccount` | The account is not eligible |

Source references:

- [ProfileReadyState generated enum](https://source.chromium.org/chromium/chromium/src/+/main:out/mac-Debug/gen/chrome/browser/glic/host/glic_webui.mojom-data-view.h)
- [Glic country filtering](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/glic/public/glic_enabling.cc)
- [Default enabled countries](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/glic/public/glic_enabling.h)
- [Temporary country override switch](https://source.chromium.org/chromium/chromium/src/+/main:components/variations/variations_switches.cc)
- [Google availability documentation](https://support.google.com/chrome/answer/17140089?co=GENIE.Platform%3DDesktop)

## A real-world troubleshooting path

The sequence below is based on an actual investigation. All personal details,
account identifiers, local paths, and IP addresses have been removed.

### Stage 1: location restriction

The UI displayed:

```text
Gemini in Chrome isn't available everywhere
Gemini in Chrome is expanding to different locations ...
```

The local state showed:

```text
glic_rollout_eligibility = true
last_ready_state = 5
```

Chromium source confirmed that `5 = LocationMismatch`. Further investigation
found that:

- the current public network exited through a supported country;
- Chrome Variations still stored a different, unsupported current/permanent
  country;
- after repairing the cache and using Chromium's official temporary runtime
  country override, the state became `2 = Ready`.

### Stage 2: embedded-client loading failure

After the location page disappeared, the UI changed to:

```text
Something went wrong
Gemini isn't available right now. Try again later.
```

At that point `ready_state = 2`, proving that the native Chrome host had
passed its eligibility checks. Repeated network tests found that:

- the Glic status API was stable;
- Google sign-in was stable;
- TLS connections to `gemini.google.com` failed intermittently;
- forcing HTTP/1.1, HTTP/2, a fixed IP, or different DNS resolvers did not
  eliminate the failures.

The embedded client started working after switching to a stable network path.

## Requirements

- macOS;
- Google Chrome;
- Bash 3.2 or later;
- `jq`;
- `curl`, `osascript`, `shasum`, and `dig` (included with macOS).

If `jq` is missing, install it using a package-management method you trust.
The script never installs dependencies automatically.

## Usage

```bash
chmod +x gemini-chrome-doctor.sh
./gemini-chrome-doctor.sh diagnose
```

Diagnosis is the default command, so this is equivalent:

```bash
./gemini-chrome-doctor.sh
```

Change the number of network trials:

```bash
./gemini-chrome-doctor.sh diagnose --trials 8
```

Skip external network checks and inspect only non-sensitive local state:

```bash
./gemini-chrome-doctor.sh diagnose --skip-network-tests
```

### Repair stale location cache

> [!WARNING]
> `repair-location` closes and restarts Chrome. Save unsubmitted forms,
> editor content, and uploads first.

For example, if the current public network genuinely exits through the United
States but Chrome still stores another country:

```bash
./gemini-chrome-doctor.sh repair-location \
  --country us \
  --apply \
  --restart
```

Safety controls:

- refuses to write without `--apply`;
- refuses to write when the public network country differs from `--country`;
- refuses to write when Chrome cannot exit gracefully;
- creates a timestamped `Local State` backup before writing;
- changes only three Variations country fields;
- refuses to write if any non-target JSON structure changes;
- validates a temporary file before an atomic replacement;
- restores the previous session with `--restore-last-session`;
- applies `--variations-override-country` only to the new Chrome process; the
  override does not persist across sessions.

The script changes these fields:

```text
variations_country
variations_permanent_consistency_country[1]
variations_safe_seed_session_consistency_country
```

It does not modify cookies, Google accounts, passwords, bookmarks, history,
extensions, Chrome Sync, or Gemini conversations.

## Interpreting the results

### `ready_state = 5` and Chrome displays a location message

1. Check the public network country printed by the script.
2. Compare it with Chrome's current and permanent Variations countries.
3. Consider `repair-location` only when the values differ and the real public
   network is in a region officially supported by Google.
4. Do not modify the cache when the public network itself is unsupported. Use
   the service only from a genuinely supported network and region.

### `ready_state = 2`, but Chrome displays “Something went wrong”

This is usually no longer an eligibility or location error. Inspect the
network success rates:

- `Glic status API` is stable while `Gemini web` fails: investigate the path
  to `gemini.google.com`.
- Several Google endpoints fail: inspect the local network, transparent proxy,
  filtering software, or upstream route.
- Different DNS resolvers return the same address and failures continue: DNS
  is probably not the root cause.
- Switch to another stable network and click **Try again** without clearing
  the entire Chrome profile.

### `ready_state = 1` or `6`

- `1`: complete Google sign-in again in the same Chrome profile.
- `6`: check account age, supervision, Workspace administration, and Gemini
  account eligibility.

## Rollback

The repair command prints the full backup path. To roll back:

1. exit Chrome gracefully;
2. confirm that the Chrome main process has stopped;
3. copy the backup over `Local State`;
4. start Chrome again.

Replace the example backup path below with the exact path printed by the
script:

```bash
cp -p \
  "$HOME/Library/Application Support/Google/Chrome/Local State.gemini-chrome-doctor-backup-YYYYMMDD-HHMMSS" \
  "$HOME/Library/Application Support/Google/Chrome/Local State"
```

## Privacy and security

- Diagnosis prints only booleans, enums, country codes, versions,
  window/tab counts, and network success rates.
- It does not print email addresses, account IDs, tab URLs, browsing history,
  cookies, or tokens.
- Public-country detection uses Cloudflare trace and reads only the two-letter
  country code; it does not print the public IP address.
- Network stability tests do not send Chrome cookies or OAuth tokens.
- Never commit `Local State`, Chrome Preferences, or generated backups.

## Limitations

- Chromium internals and preference names may change. The script stops safely
  when the structure is not what it expects.
- `ready_state` records the last observed state and may not update until Ask
  Gemini is invoked again.
- The runtime country override is a diagnostic aid, not a permanent regional
  workaround.
- Server outages, account restrictions, and enterprise policy cannot be fixed
  by editing local cache.

## Tests

```bash
./tests/test.sh
```

## License

[MIT](LICENSE)

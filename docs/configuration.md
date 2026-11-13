# Configuration and defaults

benSync uses normal macOS `UserDefaults` for preferences specific to this app
on this Mac. SwiftUI Settings controls use `@AppStorage`, and defaults are
registered at launch. Restore App Defaults resets these presentation and
new-destination defaults; it does not remove destinations or touch SSH keys.

| App preference | Built-in default |
| --- | --- |
| Cached item counts | Shown |
| Upload/download progress | Shown |
| Refresh after network reconnects | Enabled |
| New destination refresh interval | 5 minutes |
| New destination remote folder | `.` (remote account home) |
| New destination excluded directories | `node_modules`, `.git` |

Launch at login is managed by macOS's `SMAppService`, rather than a preference
that pretends to reflect OS registration. It is not enabled automatically.
Settings displays when Login Items approval is needed and can open the
appropriate System Settings pane.

## Shared destination settings

The app and sandboxed Finder extension need the same destination definitions.
They live in a private, atomically written `destinations.json` inside the
registered App Group:

```text
~/Library/Group Containers/<app-group>/Library/Application Support/benSync/
  destinations.json
  Catalogues/<destination-id>.sqlite
  Diagnostics.sqlite
  Transfers/<temporary-token>
```

Settings → Reveal Configuration opens this location in Finder. The JSON records
destination identity, display name, typed backend settings, remote root,
exclusions, refresh interval, and pause state. It contains no SSH passwords or
private keys. Older destination files without a pause field load as unpaused;
unreadable or invalid configuration produces an error rather than being
silently replaced with an empty list.

Destination settings take effect independently of the defaults for new
destinations. Changing defaults does not rewrite existing destinations. Updating
a destination cancels its previous app-driven refresh and starts a fresh one
using the saved configuration. The backend checks shared configuration before
remote operations so an old extension instance cannot ignore a saved pause,
changed exclusion policy, or destination removal.

Pause preserves cached metadata and materialized file contents. It prevents
new remote operations once the saved pause state is observed; an operation
already in flight may safely finish. Local-only metadata edits remain possible.
Pending content edits stay with File Provider and can upload after resume.

## Authentication

OpenSSH reads the user's SSH config, identity settings, agent, Keychain options,
and known hosts. benSync does not duplicate or modify that configuration.
Explicit Add/Authenticate actions may open the native askpass helper. OpenSSH
writes an accepted host key to its normal known-hosts store, and an unlocked
key may enter the existing agent. Background refresh cannot prompt.

## Logs and local analytics

Structured system logs use the `app.benSync` subsystem and record operation
names, error categories, service connection transitions, and counts. Request
bodies, profiles, hostnames, filenames, paths, and arbitrary error descriptions
are not sent to the logger. Detailed connection errors appear only in the
private application UI when needed.

Local diagnostic metrics are enabled by default and retain the most recent
200 operation summaries with cumulative counters. Summaries contain only:

- An independently generated operation ID and timestamp.
- The typed operation and optional error category.
- Elapsed milliseconds, transferred bytes, and an optional item count.

Settings can disable collection and clear saved metrics. Exports are generated
from this typed schema, never by scraping raw logs or configuration. Nothing
uploads automatically, and there is no remote analytics endpoint.

Diagnostic recording failures do not change the outcome of remote file
operations. This prevents a successful write from being retried just because
local metric storage failed.

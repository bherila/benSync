# benSync

A native Swift menu bar app that connects SSH folders to Finder as File
Provider locations. Browse a persistent offline catalogue, fetch file contents
on demand, keep selected files or folders offline, and sync local edits back
to the server.

**Development status:** core tests and unsigned builds are automated. Signed
Finder activation, authentication dialogs, and offline editing still require
end-to-end acceptance testing before relying on the app for important files.

## Features

- Native menu bar popover with destination status, cached item count, Finder
  shortcuts, refresh, authentication, pause/resume, cancellation, settings,
  removal, and Quit. Long destination lists scroll inside a bounded popover.
- Native Settings for launch at login, reconnect behavior, display options,
  and defaults for new destinations. Existing destinations have editable
  names, exclusions, refresh intervals, and pause state.
- Add dialog discovers named `Host` aliases from `~/.ssh/config`, included
  configs, and the system SSH config. OpenSSH resolves the actual connection.
- Uses existing SSH keys, SSH agent, `IdentityAgent`, jump hosts, and known
  hosts. Interactive connection actions support native password, key passphrase,
  and server fingerprint confirmation dialogs. Background sync never prompts.
- SQLite WAL catalogue preserves the complete successfully scanned namespace
  across app restarts and network loss. Metadata scans do not download content.
- Finder's native File Provider status and progress UI. Context actions:
  **Make Available Offline**, **Use On Demand**, and **Free Up Space**.
- Read/write support: create files and folders, upload edits, move, rename,
  and delete. macOS retains pending local edits while offline and retries them
  after the destination reconnects.
- Per-destination directory exclusions. `node_modules` matches at any depth;
  `projects/*/build` matches root-relative directories. Exclusions do not delete
  remote data. The initial visible defaults are `node_modules` and `.git`.
- Automatic reconnect after the network returns, exponential retry backoff,
  and recovery from a restarted background service. Ambiguous remote mutations
  are never automatically replayed by the transport client.
- Local structured logging and bounded diagnostic metrics, with an enable/clear
  switch and redacted JSON export. No remote analytics service is configured.

## Build

Requires macOS 26+, Xcode 26+ with the macOS 27 SDK, Swift, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). There are no downloaded
runtime dependencies, FUSE drivers, rclone dependency, or remote server helper.
The server must offer SFTP v3; replacing existing files requires OpenSSH's
atomic rename extension.

```sh
./scripts/check.sh
```

This runs the isolated Core tests, generates the Xcode project from
`project.yml`, and builds all four targets without signing. The app is at
`build/Build/Products/Debug/benSync.app`.

### Run with Finder integration

An unsigned build validates compilation; it does not validate File Provider
activation. The host app, sandboxed extension, private XPC service, and askpass
helper need valid signatures, and the app/extension/service need the same
registered App Group. This project does not include signing credentials.

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill in
   your team and registered bundle/App Group identifiers.
2. Run `xcodegen generate`, open `benSync.xcodeproj`, and select the
   **benSync** scheme. Resolve signing/provisioning in Xcode for all targets.
3. Build and install the signed app in `/Applications`, then open it. Enable
   its File Provider extension in System Settings if macOS asks.
4. Click the menu bar icon, choose **Add Destination…**, select an SSH profile,
   set the remote folder and exclusions, and add it. `.` selects the account's
   home directory; choose a narrower folder to reduce catalogue scanning.
5. Verify any new host fingerprint in the native connection dialog. After the
   first catalogue scan, open the destination in Finder.

Only explicit **Add** and **Connect / Authenticate…** actions may prompt.
An encrypted key unlocked this way can enter the user's SSH agent. Passwords
are passed directly to OpenSSH through its askpass pipe and are not stored by
the app. Password-only connections may need explicit reauthentication after
their reusable SSH connection expires.

Removing a destination uses macOS's preserve-downloaded-data mode. It does
not delete remote files; macOS returns the preserved local folder when one
exists, and the app reveals it in Finder.

## Architecture and extension points

See [architecture](docs/architecture.md) for the storage and process boundaries,
performance policy, backend contract, and future object-store/snapshot adapters.
See [validation](docs/validation.md) for verified automated coverage and the
remaining signed runtime checks.
See [configuration](docs/configuration.md) for built-in defaults, storage
locations, pause behavior, and diagnostic privacy.

## Continuous integration

[GitHub CI](https://github.com/bherila/benSync/actions/workflows/ci.yml) runs
the synthetic Core tests, source disclosure checks, and unsigned Debug and
Release app/extension builds. Signing credentials and real SSH destinations
are not required. A green CI run does not establish signed Finder behavior.

## Current limits

- SSH is the only implemented backend. S3 and backup snapshots are future
  adapters, not selectable placeholder features.
- SFTP v3 versions use file size and second-resolution modification time.
  Same-size edits within one server timestamp tick can evade conflict detection.
  The check immediately before atomic replacement is not a server-side
  compare-and-swap: an independent remote writer can race it. For strong
  concurrent-writer guarantees, a backend needs conditional writes or locking
  respected by every writer.
- Completed creation receipts are durable and avoid retransfers on replay.
  If the remote operation succeeds but the local completion receipt cannot be
  committed, a retry can surface a name collision. Interrupted uploads can
  leave hidden `.bensync-upload-*` staging files on the remote server.
  They are excluded from enumeration and are not automatically deleted based
  solely on their filename.
- Combined content-and-name changes publish the new file before removing the
  old name. Failure can leave both remote names; it preserves the old bytes
  and pending local edits instead of overwriting a conflicting source.
- Symlinks and special files are not synced. Tags and last-used metadata are
  local to this Mac. External remote renames appear as delete/create because
  SFTP v3 has no portable persistent file identity.
- A partial scan preserves unreadable branches and reports incomplete status.
  Unvisited branches become browsable offline only after successful enumeration.

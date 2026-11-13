# Architecture

## Ownership

| Component | Owns |
| --- | --- |
| SwiftUI menu bar app | Profile picker, destination settings, status, periodic refresh, explicit authentication |
| Sandboxed replicated File Provider extension | Finder items/enumeration, native progress/errors, pin policy, eviction, forwarding edits |
| Private unsandboxed XPC broker | OpenSSH processes, remote operations, catalogue refresh, version checks |
| Core Swift package | Backend protocol, transport, catalogue, exclusion rules, connection configuration |
| Native askpass helper | One user-visible authentication or host-trust prompt; response only to OpenSSH's private pipe |
| macOS File Provider | Materialized file bytes, placeholders, pending local edits, offline storage, Finder status |

App presentation/default preferences use macOS UserDefaults. Destination
definitions and pause state are shared atomically through the App Group, and
typed local metrics use a separate bounded SQLite database.

The broker is embedded privately in both app and extension bundles. It requires
same-team, allowlisted client bundle identities. This lets the sandboxed File
Provider use existing SSH configuration, arbitrarily located identity files,
agents, and jump hosts through the system OpenSSH client, without copying keys
or granting broad filesystem exceptions to the extension. The app and broker
are intended for direct signed distribution rather than an App Store sandbox.

RPC accepts structured operations, opaque item IDs, and UUID transfer tokens.
It never accepts an arbitrary shell command or client-supplied local file path.
Staged transfer files live in the private App Group container. Upload inputs
are cloned on APFS, and downloaded files are handed to File Provider for system
ownership. There is no second permanent byte cache.

## Catalogue and offline operation

Each destination has one SQLite database in the App Group container. Nodes use
opaque UUIDs, a unique root-relative path, an indexed parent, remote attributes,
local user metadata, and an explicit inherited/keep/on-demand offline policy.
Finder item identifiers never contain remote paths or credentials.

A scan crawls directories breadth-first. Each successful directory listing is
reconciled transactionally with the persistent catalogue; an unreadable listing
never becomes an empty directory. Only changed nodes produce journal entries.
Removed subtrees produce persistent tombstones. Local moves preserve item IDs,
including all descendant IDs.

The working set includes the whole catalogue, so materialized items continue to
receive remote changes. Enumeration is served exclusively from SQLite in
250-item pages. Change enumeration delivers bounded journal pages and retains
unacknowledged changes. Only the working-set consumer's next request can
acknowledge a previously delivered anchor. Compaction retains a replay tail and
keeps the anchor monotonic through SQLite's durable sequence.

The system owns offline content and pending edits. Pinning a folder sets an
eager download/keep policy inherited by its descendants. An explicit on-demand
override can opt a child out. Free Up Space changes the policy and asks macOS
to evict content; macOS refuses to discard unsynced edits or explicitly pinned
descendants. On macOS 27, the root also requests eager namespace materialization,
independently of content download policy.

## Performance policy

- Metadata scanning does not open file contents. Directory exclusions prune
  traversal before entering excluded subtrees.
- Background refresh defaults to five minutes, can be adjusted per destination,
  and backs off exponentially after failures, up to 30 minutes.
- Network recovery triggers a refresh when enabled. Paused destinations keep
  their cached namespace and do not start remote operations. Configuration is
  rechecked at remote boundaries, including by long-lived extension instances.
- Recent refresh results are shared between processes to suppress duplicate
  scans. Persisted partial-scan status cannot be mistaken for a complete scan.
- A separate scanner queue and short per-directory locks let writes proceed
  during a large crawl. Interprocess locks prevent two scanners from racing.
- Browsing and item lookup use the offline catalogue immediately. A background
  network refresh does not block enumeration.
- OpenSSH connections are reused through private multiplexing sockets and
  reusable SFTP sessions. Individual transfers use a bounded pipeline of
  sixteen 32 KiB requests; whole file contents never accumulate in memory.
- File Provider limits downloads to four and uploads to two per domain.
  Progress updates to Finder are throttled to four per second.
- Background Spotlight worker processes are prevented from hydrating the entire
  working set merely to index it. User-initiated reads and Quick Look still work.
- SFTP offers no portable recursive change feed. Periodic directory listings
  are intentional; parent directory mtimes cannot detect edits inside files or
  nested descendants. A backend with a change feed can replace this strategy.

## Service recovery

Each client connection has a generation-scoped request registry. Replies,
cancellation, proxy failures, interruptions, and invalidation compete to complete
a request exactly once. Old connection events cannot fail requests on a newer
connection. A subsequent operation establishes a fresh connection, but the
client never blindly replays an ambiguous remote mutation.

The service tracks early cancellation and queued work, cleans staged inputs on
cancel/validation failure, and retires cached engines without closing a scanner
that still owns one. Completed operation metrics are recorded separately from
the operation result; metric failures cannot cause successful mutations to be
reported as failed. Logs and exported metrics have no free-text request fields.

## Write behavior

Uploads stream to exclusive hidden staging files, optionally fsync the remote
file, recheck the destination version, then atomically rename into place.
Creation and movement do not overwrite an existing remote name. Conflict
errors retain pending edits in File Provider. The limitations of SFTP's version
heuristic and non-conditional rename are explicit in the README.

For content plus rename, new-format bytes are published under the final name
first; the original version is verified again before removing the old name.
This prioritizes preserving bytes if the two namespace changes cannot complete.

Recursive deletion first compares each directory's full remote name set with
the cached children and verifies every cached version before deleting anything.
It deletes bottom-up, rechecks file versions, and uses RMDIR so a newly added
remote child cannot be silently removed. Excluded/special/unseen children also
prevent deletion when the server refuses the non-empty directory.

## Additional backends

`RemoteBackend` is deliberately independent of File Provider and any vendor
SDK. It exposes capabilities, directory listing, canonical root, opaque remote
versions, streamed download/upload, move, directory creation, and deletion.
`BackendConfiguration` is a typed Codable enum. New cases add a configuration
form and one broker factory registration; Finder consumes the same catalogue.
Capabilities flow through to the Finder item actions, including read-only
sources.

An S3 adapter should use bucket/prefix configuration and Keychain credential
references; flatten paginated object listings into synthetic directories; retain
ETags/version IDs as opaque versions; and use conditional requests/multipart
uploads. Prefix moves and empty-directory behavior require explicit capability
choices because object storage has different semantics from a filesystem.

A snapshot adapter should be read-only and address a pinned immutable snapshot
ID, never a moving “latest” alias. A backup companion can offer a destination
descriptor through a versioned, authenticated local API. This app would enumerate
snapshot metadata and stream requested files through that API. The companion
should retain ownership of repository credentials, locks, snapshot retention,
and restore authorization; raw encrypted repository pack files are not a
user-facing file hierarchy.

When backing up File Provider locations, the backup app must explicitly decide
whether to skip dataless placeholders or hydrate them. Walking a cloud folder
must not accidentally download an entire remote destination. Copy-on-write
snapshot/export integration should operate through the backend boundary rather
than a second filesystem watcher on the materialized Finder folder.

Rclone is not required. An optional future adapter can use it for selected
transports while retaining this application's native configuration, catalogue,
offline policies, and authentication ownership. It must not introduce another
VFS cache or invoke broad sync/delete commands alongside File Provider.

## Apple references

- [Replicated File Provider extension](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension)
- [Synchronizing the extension](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension)
- [Content policies](https://developer.apple.com/documentation/fileprovider/nsfileprovidercontentpolicy)
- [Custom Finder actions](https://developer.apple.com/documentation/fileprovider/nsfileprovidercustomaction)

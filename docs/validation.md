# Validation

Automated Core coverage uses Swift Testing and synthetic temporary fixtures.
The current suite contains 93 tests across seven suites, including real SFTP
integration, malformed-frame, pause/configuration, diagnostic privacy, and
service-lifecycle tests; all passed in the final development run.
The real SFTP integration tests launch `/usr/libexec/sftp-server` over local
pipes: no SSH account, credentials, network listener, or remote destination is
used. They test files larger than the transfer window, empty files, Unicode and
newline filenames, byte-for-byte round trips, file modes, cancellation, conflict
preservation, and symlink confinement.

Catalogue/engine tests cover persistence across reopening, offline enumeration,
metadata-only scans, exclusion pruning without content transfers, no-op journal
stability, local metadata changes without content-version churn, subtree moves
with multi-scalar Unicode paths, replay receipts, bounded journal compaction,
read-only capabilities, partial-refresh preservation, and refresh suppression.
Mutation tests combine filename and content changes, exercise failed source
removal, preflight recursive deletes against unseen/changed children, and ensure
a missing descendant cannot remove its surviving parent from the catalogue.

`scripts/check.sh` runs these tests and builds the menu bar app, extension, XPC
broker, and askpass helper with signing disabled. A passing build establishes
compilation and bundle composition, not runtime registration with Finder.

The following remain signed runtime acceptance checks, not claimed verified
behavior by the unsigned builds or synthetic automated tests:

1. Install a signed app with its registered App Group and enable its File
   Provider extension. Open the popover, Add dialog, and destination settings.
2. Connect to a disposable SSH folder using an existing profile. Verify the
   host-fingerprint, encrypted-key, password, and cancellation dialogs.
3. Verify cloud placeholders, progress, pinned status, and Finder context
   actions; browse directories not previously opened in Finder.
4. Keep a nested folder offline, disconnect the network, restart the app, browse
   its catalogue, open downloaded files, and save edits and new files.
5. Reconnect and confirm pending writes upload; make concurrent remote edits
   and confirm conflicts retain local changes. Verify background reconnects do
   not show authentication prompts.
6. Free space and confirm file contents are evicted while catalogue entries
   remain. Pending local edits must survive an eviction attempt.
7. Remove the destination and confirm preserved downloads are revealed and no
   remote files are deleted.
8. Verify pause/resume across app restarts, Settings defaults, login-item
   approval, and network recovery. A begun transfer may finish while pausing;
   no new remote operation may begin after observing the saved pause state.
9. Terminate the background service while reading and writing. Pending calls
   must return once, later calls reconnect, and ambiguous writes must retain
   local edits without blind replay.

No actual SSH destination has been added or modified during automated
development validation.

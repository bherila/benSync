# Testing and CI

The Core suite uses Swift Testing and isolated synthetic fixtures. Real SFTP
integration tests launch the system SFTP server over local pipes, without a
network listener, real destination, SSH credentials, or account configuration.

Quality coverage also exercises malformed SFTP frame negotiation, truncated
packets, shared-configuration migration and corruption, pause/resume against
already-open engines, configuration changes during scans, bounded retry policy,
and privacy-safe diagnostics. Diagnostics tests cover retention limits,
cross-connection disable behavior, concurrent writers, overflow, invalid
counters, and the exported schema's allowed fields. Service lifecycle tests
cover cancellation races, interrupted connections, duplicate callbacks, and
generation changes without automatically replaying mutations.

```sh
swift test --package-path Core
python3 scripts/privacy-check.py --self-test
python3 scripts/privacy-check.py --all
./scripts/check.sh
```

Before publication, stage the intended source and scan the actual staged blobs
with `python3 scripts/privacy-check.py --staged`. The default `--tracked` mode
checks tracked working-tree files and is used on a clean CI checkout. `--all`
is for initial local checks before git initialization and skips build products,
generated Xcode projects, package caches, and Python caches.

The privacy check reports filenames, line numbers, and rule names only. It
does not print matched values or send source to another service. Its synthetic
self-tests cover common credential patterns, personal paths, infrastructure
aliases, private addresses, generated configuration, and signing material.
This is an accidental-disclosure guard; it supplements manual review.

GitHub CI runs privacy checks on Linux and runs Core tests plus unsigned Debug
and Release builds on the hosted `xcode-27` image. The image is a public preview
with the macOS 27 SDK; its software inventory is maintained in the
[official runner images repository](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).
Build jobs use Xcode 27.2 explicitly. Workflows have read-only repository
permissions, cancel superseded runs, require no signing credentials, and do not
upload build products or logs as artifacts.

Passing unsigned builds do not establish File Provider activation or GUI
authentication correctness. Signed runtime checks are listed in
[validation](validation.md).

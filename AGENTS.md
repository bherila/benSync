# Contributor guidance

- `project.yml` is the source of the generated Xcode project. Regenerate with
  XcodeGen instead of editing `.xcodeproj` files.
- Core logic and synthetic tests live in `Core/`. Run `swift test --package-path
  Core` for core changes, and `scripts/check.sh` for the app/extension build.
- Unit tests use temporary fixtures. Do not connect to a real destination,
  modify a user's SSH configuration, enable login items, or activate Finder
  domains during automated tests.
- Keep local configuration, logs, exports, signing material, credentials,
  private paths, and infrastructure details out of source and GitHub messages.
  Use generic aliases and `*.example.test` hosts in fixtures and documentation.
- Run `python3 scripts/privacy-check.py --staged` before publishing a commit,
  and manually review the staged diff for private information.
- Distinguish passing core tests and unsigned builds from signed runtime
  verification. Native File Provider, XPC, authentication UI, and offline
  editing require signed end-to-end acceptance tests.
- A failed or interrupted service call may have mutated the remote server.
  Reconnect for later requests; never blindly replay a mutation.
- Preserve pending local edits. Exclusions, pause, eviction, and destination
  removal must not silently discard edits or delete unrelated remote data.
- Diagnostic events accept typed operation names, counters, timings, and error
  categories only. Do not log request bodies, credentials, paths, hostnames,
  profile names, filenames, or arbitrary error descriptions.

# TranscribeCpp provenance

Native artifact: [Handy transcribe.cpp v0.3.0](https://github.com/handy-computer/transcribe.cpp/releases/tag/v0.3.0).
Source commit: `077110eb00ca6880e13bef4ddebf766b3b76896c`.
Original `TranscribeCpp.xcframework.zip` SHA-256:
`b7410c3ff3cb0f58c6b1973e916b6a90873f473aeab7cd8f58794d8f643f1e9f`.
The checksum matches GitHub's release asset digest and the workspace's original archive.
The retained macOS files were compared byte-for-byte with that archive.

This package retains only the universal arm64/x86_64 macOS slice; iOS slices
were removed from the directory and xcframework manifest. License files remain.
The Swift wrapper comes from upstream `bindings/swift/Sources/TranscribeCpp`;
`Package.swift` is scoped to the library and links native platform dependencies.

Upstream build recipes at that commit:
- `scripts/ci/build_xcframework.sh`
- `scripts/ci/package_xcframework.sh`

Xcode embeds and signs the dynamic framework during app builds. The Debug
build with development signing and hardened runtime is covered by background
tests. Developer ID signing and notarization remain part of the release workflow;
this PR does not claim a fresh notarization check.

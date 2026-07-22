# Third-Party Swift Dependencies

## swift-markdown 0.8.0

- Source: <https://github.com/swiftlang/swift-markdown>
- Upstream `0.8.0` tag revision observed for provenance:
  `3c6f9523da3a1ec2fd829673e472d95b8097a3b8`
- License: Apache License 2.0 with Runtime Library Exception; upstream `LICENSE.txt` and
  `NOTICE.txt` are the authoritative distribution notices
- Transitive parser: <https://github.com/swiftlang/swift-cmark>, version 0.8.0 at the upstream tag
  revision observed for provenance:
  `924936d0427cb25a61169739a7660230bffa6ea6`
- Transitive parser license: BSD-style cmark license with separately retained notices for bundled
  source components; upstream `COPYING` is authoritative
- Use: CommonMark/GFM parsing and HTML formatting for Android-compatible My Documents rendering

`Package.swift` enforces the direct dependency with `exact: "0.8.0"`; swift-markdown's own `0.8.0`
manifest constrains its swift-cmark dependency. `Package.resolved` is intentionally untracked, so the
revision hashes above document inspected upstream provenance rather than serving as repository lock
files. A clean checkout resolves those exact semantic versions from upstream and therefore needs
network access on its first SwiftPM/Xcode resolution. Subsequent builds may use the local package
cache; CI must restore or populate that cache before any explicitly offline build step.

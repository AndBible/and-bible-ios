---
adr: ADR-0012
title: "Install Validation Follows Observed SWORD Packaging"
description: >-
  Module install validation accepts what Android/JSword demonstrably accepts,
  adding only path-safety and transactional-integrity guards; packaging
  assumptions JSword does not enforce are not valid rejection grounds.
date: 2026-08-08
status: accepted
supersedes: []
superseded-by: null
decision-owner: "iOS parity maintainers"
deciders: ["iOS parity maintainers"]
consulted:
  - "jsword IOUtil.unpackZip / AbstractSwordInstaller"
  - "jsword SwordBookDriver.delete"
  - "jsword SwordBookMetaData Version default"
  - "AndBible DownloadControl.getDocumentStatus"
  - "Real packages: FontPack, EpiphanyMaps, OpenHymnal, WebstersLinked, StrongsRealGreek, BDBT"
informed: ["AndBible iOS contributors"]
tags: [parity, install, validation, sword, android]
related-adrs: [ADR-0011]
related-work-items: ["PR #380", "Issue #373 follow-on reports"]
---

# 0012: Install Validation Follows Observed SWORD Packaging

Status: Accepted

Date: 2026-08-08

## Context

Android performs almost no structural validation at install: JSword extracts
every ZIP entry under `mods.d/` and `modules/` verbatim, deletes a module's
whole location directory on uninstall, and defaults a missing `Version` to
`1.0` at read time. iOS's validator initially encoded stricter assumptions
about how SWORD packages "should" look: stem-driver DataPaths always denote
filename prefixes, a module owns only direct stem-prefixed children of its
directory, the package config filename equals the lowercased initials, and
configs declare a version.

Real CrossWire and AndBible packages violate every one of those assumptions.
FontPack declares RawGenBook with a trailing-slash directory DataPath and
nested font payload; EpiphanyMaps ships `mods.d/epiphany-maps.conf` for
initials `EpiphanyMaps`; stem modules (EpiphanyMaps, OpenHymnal,
WebstersLinked, Webster1828, StrongsRealGreek/Hebrew, NaveLinked,
InvStrongsRealGreek, Easton, Berean modules, ACDCRef) ship `BuildModule`
scripts and `images/` directories beside their stem files; BDBT declares no
`Version` at all. Each assumption produced a user-facing install failure or a
phantom permanent update that Android does not have. The rejections protected
nothing real: Android has installed these exact packages for years.

## Decision

1. The parity baseline for install validation is what JSword demonstrably
   does, verified against its source and real packages — not inferred
   packaging conventions. A package Android installs must install on iOS
   unless rejecting it defends one of the guards in point 4.

2. Ownership and deletion are directory-scoped for every driver. A module
   owns every file below its data directory. Stem-style DataPaths (RawLD,
   RawLD4, zLD, RawGenBook, RawFiles) still name the data files, and a
   trailing slash — not the driver — marks a directory DataPath, but
   ownership and uninstall both cover the whole parent directory, matching
   JSword extraction and `SwordBookDriver.delete`.

3. Metadata semantics use JSword's read-time defaults. A missing or empty
   `Version` reads as `1.0` on both comparison sides, so versionless modules
   never report a phantom update; genuinely malformed versions keep Android's
   deliberate update-available fallback. A remote package's single config may
   use any direct `mods.d/*.conf` filename; identity is proven from parsed
   content against the catalog, and the staged config is written at the
   canonical path.

4. iOS-added guards are limited to what Android's absence of them makes
   exploitable or what ADR-0011's transaction requires: path traversal,
   symlink and canonical-containment escapes, percent-encoded and absolute
   paths, duplicate initials, multi-config packages, catalog identity
   mismatches, staged-plan revalidation, and archive-digest-bound overwrite
   consent. These reject malicious or self-inconsistent archives, never
   merely unconventional ones.

5. New rejection rules carry a burden of proof. Before adding a validation
   rule stricter than JSword's behavior, cite the JSword source path it
   mirrors or the concrete attack it blocks, and test it against real
   packages from the shipped repositories. "The packaging looks wrong" is not
   a rejection ground.

## Consequences

- The module population installable on iOS tracks Android's, so parity bugs
  in this area are regressions against a stated rule rather than judgment
  calls.
- Uninstalling a stem module removes its whole data directory, exactly as
  Android does. In the theoretical case of two modules sharing one directory,
  uninstalling one removes the other's files — Android-identical, and no real
  CrossWire package shares directories.
- Security review of the install path concentrates on the point-4 guard list;
  loosening any of those needs its own decision, not an appeal to this ADR.
- Known accepted gap: the local ZIP import path still requires the config
  filename to match the module initials, which Android does not. Closing it
  should follow this ADR's rule (canonicalize, don't reject).
- When a new package fails to install, the diagnostic procedure is: download
  the actual package, read the actual JSword code path, and align — the
  procedure that produced this ADR.

## Alternatives Considered

- **Keep strict conventional validation and fix packages upstream.** Rejected:
  iOS does not control CrossWire packaging, decades of published modules
  already violate the conventions, and users experience the mismatch as
  broken installs.
- **Drop validation entirely to match Android byte-for-byte.** Rejected:
  Android's absence of zip-slip and containment checks is a latent defect,
  and ADR-0011's transactional publish requires staged-plan validation to
  exist.
- **Treat malformed versions as equal instead of updateable.** Rejected:
  Android deliberately reports update-available when `Version(...)` throws,
  keeping a reinstall affordance for damaged metadata; iOS preserves that.

## Related

- SwordKit `ModuleStoreInstalledLayout` (payload shape, `ownsPayload`),
  `ModuleStoreTransactionPublisher+Uninstall.payloadTargets`,
  `ModuleRepository.installModulePackage` /
  `validatedRemotePackageLayout`, `SwordModuleConfig.parse`,
  `ModuleBrowserView.isRemoteVersionNewer`.
- JSword `IOUtil.unpackZip`, `SwordBookDriver.delete`,
  `SwordBookMetaData` defaults, `Version`; AndBible
  `DownloadControl.getDocumentStatus`.
- PR #380 carries the implementing changes and validation evidence.

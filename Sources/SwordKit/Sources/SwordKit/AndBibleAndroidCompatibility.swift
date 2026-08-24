// AndBibleAndroidCompatibility.swift — Pinned Android application compatibility authority

/**
 Owns the Android application version code whose behavior this iOS build implements.

 The value is pinned to And Bible current-stable commit `00b4ea24`. It is intentionally independent
 of iOS marketing and build metadata: local builds use small unrelated numbers and TestFlight uses
 dotted UTC stamps, neither of which carries Android compatibility meaning. Add-on admission and
 every Android-compatible backup producer consume this one authority.

 Advancing the code requires parity review of Android behavior introduced after the pinned commit.
 The type performs no I/O, has no mutable state, and cannot fail.
 */
public enum AndBibleAndroidCompatibility {
    /// Android current-stable version code implemented by this iOS build.
    public static let currentVersionCode = 1115
}

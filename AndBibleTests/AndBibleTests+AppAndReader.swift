import XCTest
@testable import BibleUI
#if os(iOS)
import UIKit
#endif

extension AndBibleTests {
    #if os(iOS)
    /**
     Keeps app-host coverage for the scene delegate bootstrap that package tests cannot exercise.

     `AndBibleApplicationDelegate.sceneConfiguration` is the remaining `+AppAndReader` test that
     depends on the app target rather than BibleUI package logic. A failure here means app launch
     would stop installing `AndBibleWindowSceneDelegate`, breaking the iPadOS windowing-control
     policy wiring even though the package-level policy tests still pass.
     */
    func testApplicationDelegateSceneConfigurationUsesWindowSceneDelegate() {
        let configuration = AndBibleApplicationDelegate.sceneConfiguration(
            sessionRole: UISceneSession.Role.windowApplication
        )

        XCTAssertEqual(
            ObjectIdentifier(configuration.delegateClass!),
            ObjectIdentifier(AndBibleWindowSceneDelegate.self)
        )
        XCTAssertNil(configuration.name)
    }
    #endif

}

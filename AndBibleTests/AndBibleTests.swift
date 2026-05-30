import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import struct SwiftUI.Binding
import enum SwiftUI.ColorScheme
import struct SwiftUI.EdgeInsets
import struct SwiftUI.EmptyView
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

final class AndBibleTests: XCTestCase {
    var temporarySwordModulePaths: [String] = []

    override func tearDown() {
        let fm = FileManager.default
        for path in temporarySwordModulePaths {
            try? fm.removeItem(atPath: path)
        }
        temporarySwordModulePaths.removeAll()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
}

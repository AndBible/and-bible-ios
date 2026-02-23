// ProgressView+AndBible.swift — Custom progress indicators

import SwiftUI

/// A progress view for module downloads showing percentage and module name.
public struct DownloadProgressView: View {
    let moduleName: String
    let progress: Double // 0.0 to 1.0

    public init(moduleName: String, progress: Double) {
        self.moduleName = moduleName
        self.progress = progress
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(moduleName)
                    .font(.subheadline)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
        }
    }
}

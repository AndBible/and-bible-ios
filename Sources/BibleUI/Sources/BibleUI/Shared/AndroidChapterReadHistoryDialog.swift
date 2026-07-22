import BibleCore
import SwiftUI

/**
 Renders Android's fixed-chapter Read History `AlertDialog` inside the owning reader window.

 The child view keeps deletions staged until this dialog disappears, matching Android's dismissal
 listener. The dialog receives a captured reader store and target, so changing focused panes behind
 it cannot retarget either its rows or their pending deletion commit.
 */
struct AndroidChapterReadHistoryDialog: View {
    let store: ReadingProgressStore?
    let target: ChapterReadHistoryTarget
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            NavigationStack {
                ChapterReadHistoryView(store: store, target: target)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "ok", defaultValue: "OK"), action: onDismiss)
                        }
                    }
            }
            .frame(maxWidth: 560, maxHeight: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 16)
            .padding(24)
        }
        .accessibilityIdentifier("androidChapterReadHistoryDialog")
    }
}

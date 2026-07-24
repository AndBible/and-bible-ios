// AndroidReadingPlanStartDateDialog.swift -- App-owned AppCompat calendar dialog

import SwiftUI

/**
 Presents Android's bounded start-date calendar without delegating controls to iOS `DatePicker`.

 The dialog uses the shared Android window and palette, owns month navigation and day selection, and
 keeps the caller's binding unchanged until OK. Android prevents future start dates; this projection
 applies the same local-day maximum.

 Inputs: draft date binding plus explicit Cancel and Apply closures

 Output: one app-owned month calendar dialog

 Side effects: selecting a day mutates the draft binding; actions invoke the supplied closure

 Failure modes: invalid calendar month arithmetic leaves the current month unchanged
 */
struct AndroidReadingPlanStartDateDialog: View {
    @Binding var selection: Date
    let onCancel: () -> Void
    let onApply: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    @State private var displayedMonth: Date

    private let calendar: Calendar

    /** Creates isolated month state from the caller's draft selection. */
    init(
        selection: Binding<Date>,
        onCancel: @escaping () -> Void,
        onApply: @escaping () -> Void
    ) {
        _selection = selection
        self.onCancel = onCancel
        self.onApply = onApply
        var calendar = Calendar.current
        calendar.locale = Locale.current
        self.calendar = calendar
        let components = calendar.dateComponents([.year, .month], from: selection.wrappedValue)
        _displayedMonth = State(initialValue: calendar.date(from: components) ?? selection.wrappedValue)
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidReadingPlanStartDateDialog",
            onOutsideTap: onCancel
        ) {
            VStack(spacing: 0) {
                selectionHeader
                calendarBody
            }
            .frame(maxWidth: 420)
        }
    }

    /// Material date header using the shared AppCompat accent resource.
    private var selectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(yearFormatter.string(from: selection))
                .font(.system(size: 16))
                .opacity(0.78)
            Text(selectedDateFormatter.string(from: selection))
                .font(.system(size: 30, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(AndroidDialogSurfacePalette.accent(for: colorScheme))
    }

    /// Month controls, locale-ordered weekday labels, day grid, and Android action row.
    private var calendarBody: some View {
        VStack(spacing: 12) {
            HStack {
                monthNavigationButton(
                    rotatesForward: false,
                    accessibilityLabel: String(localized: "previous", defaultValue: "Previous"),
                    isEnabled: true,
                    action: { moveMonth(by: -1) }
                )

                Spacer()
                Text(monthFormatter.string(from: displayedMonth))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                Spacer()

                monthNavigationButton(
                    rotatesForward: true,
                    accessibilityLabel: String(localized: "next", defaultValue: "Next"),
                    isEnabled: canMoveToNextMonth,
                    action: { moveMonth(by: 1) }
                )
            }

            LazyVGrid(columns: calendarColumns, spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
                        .frame(maxWidth: .infinity)
                }

                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayButton(date)
                    } else {
                        Color.clear.frame(height: 38)
                    }
                }
            }

            HStack(spacing: 22) {
                Spacer(minLength: 0)
                Button(String(localized: "cancel"), action: onCancel)
                    .accessibilityIdentifier("dailyReadingStartDateCancelButton")
                Button(String(localized: "okay", defaultValue: "OK"), action: onApply)
                    .accessibilityIdentifier("dailyReadingStartDateDoneButton")
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
            .padding(.top, 4)
        }
        .padding(20)
        .accessibilityIdentifier("dailyReadingStartDatePicker")
    }

    /// Seven equal calendar columns shared by weekday labels and selectable dates.
    private var calendarColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    }

    /// Locale weekday symbols reordered to the user's calendar first weekday.
    private var weekdaySymbols: [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? []
        guard symbols.count == 7 else { return symbols }
        let offset = max(0, min(6, calendar.firstWeekday - 1))
        return Array(symbols[offset...] + symbols[..<offset])
    }

    /// Leading blanks plus every local date in the displayed month.
    private var monthCells: [Date?] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = calendar.date(
                from: calendar.dateComponents([.year, .month], from: displayedMonth)
              ) else { return [] }
        let weekday = calendar.component(.weekday, from: firstDay)
        let leadingCount = (weekday - calendar.firstWeekday + 7) % 7
        let leading: [Date?] = Array(repeating: nil, count: leadingCount)
        let days: [Date?] = dayRange.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: firstDay)
        }
        return leading + days
    }

    /// Whether Android's forward control may enter another month before the today maximum.
    private var canMoveToNextMonth: Bool {
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) else {
            return false
        }
        return calendar.compare(nextMonth, to: Date(), toGranularity: .month) != .orderedDescending
    }

    /// One shared existing back drawable, rotated only for the forward month direction.
    private func monthNavigationButton(
        rotatesForward: Bool,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            AndBibleIconView(name: "ActivityBack", size: 20)
                .rotationEffect(.degrees(rotatesForward ? 180 : 0))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
        .opacity(isEnabled ? 1 : 0.32)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    /// One local-day control with AppCompat selected and future-disabled states.
    private func dayButton(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selection)
        let isEnabled = calendar.compare(date, to: Date(), toGranularity: .day) != .orderedDescending
        return Button {
            guard isEnabled else { return }
            selection = calendar.startOfDay(for: date)
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(
                    isSelected
                        ? Color.white
                        : AndroidDialogSurfacePalette.primaryText(for: colorScheme)
                )
                .frame(width: 38, height: 38)
                .background {
                    Circle().fill(
                        isSelected
                            ? AndroidDialogSurfacePalette.accent(for: colorScheme)
                            : Color.clear
                    )
                }
                .opacity(isEnabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(dayAccessibilityFormatter.string(from: date))
        .accessibilityValue(isSelected ? String(localized: "selected", defaultValue: "Selected") : "")
    }

    /// Moves the visible month without mutating the caller's draft date.
    private func moveMonth(by offset: Int) {
        guard let next = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else {
            return
        }
        displayedMonth = next
    }

    /// Locale formatter for the selected header year.
    private var yearFormatter: DateFormatter {
        formatter(template: "yyyy")
    }

    /// Locale formatter for the selected header weekday and month/day.
    private var selectedDateFormatter: DateFormatter {
        formatter(template: "EEEEMMMMd")
    }

    /// Locale formatter for the visible month heading.
    private var monthFormatter: DateFormatter {
        formatter(template: "MMMM yyyy")
    }

    /// Locale formatter used by VoiceOver for day controls.
    private var dayAccessibilityFormatter: DateFormatter {
        formatter(template: "yMMMMd")
    }

    /// Creates one locale-aware formatter from a Unicode date-field template.
    private func formatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}

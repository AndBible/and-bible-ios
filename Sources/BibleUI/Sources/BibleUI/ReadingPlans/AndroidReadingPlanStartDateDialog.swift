import SwiftUI

/**
 Android `DatePickerDialog`-equivalent owner for a Reading Plan start date.

 The dialog keeps the draft binding local to the calling screen until its explicit Apply action,
 matching Android's cancellation semantics and maximum-date boundary.
 */
struct AndroidReadingPlanStartDateDialog: View {
    @Binding var selection: Date
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "reading_plan_set_start_date", defaultValue: "Set Start Date"))
                    .font(.headline)

                DatePicker(
                    String(localized: "reading_plan_start_date", defaultValue: "Start Date"),
                    selection: $selection,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .accessibilityIdentifier("dailyReadingStartDatePicker")

                HStack {
                    Spacer()
                    Button(String(localized: "cancel"), action: onCancel)
                        .accessibilityIdentifier("dailyReadingStartDateCancelButton")
                    Button(String(localized: "done"), action: onApply)
                        .accessibilityIdentifier("dailyReadingStartDateDoneButton")
                }
            }
            .padding(24)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 16)
            .padding(24)
        }
        .accessibilityIdentifier("androidReadingPlanStartDateDialog")
    }
}

import SwiftUI

struct MeetingEditorSheet: View {
    let meeting: Meeting
    let onSave: (String, Date?, Date?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var scheduledStartDate: Date
    @State private var scheduledEndDate: Date

    init(meeting: Meeting, onSave: @escaping (String, Date?, Date?) -> Void) {
        self.meeting = meeting
        self.onSave = onSave
        _title = State(initialValue: meeting.title)
        _scheduledStartDate = State(initialValue: meeting.scheduledStartDate ?? Date())
        _scheduledEndDate = State(initialValue: meeting.scheduledEndDate ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("Edit Meeting")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)

                Spacer()

                Button("Save") {
                    onSave(title, scheduledStartDate, scheduledEndDate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)

            Divider()
                .foregroundStyle(Color.appSeparator)

            // MARK: - Form

            Form {
                Section("Title") {
                    TextField("Meeting title", text: $title)
                        .textFieldStyle(.plain)
                }

                Section("Schedule") {
                    DatePicker(
                        "Start Date",
                        selection: $scheduledStartDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    DatePicker(
                        "End Date",
                        selection: $scheduledEndDate,
                        in: scheduledStartDate...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color.appBackground)
    }
}

// MARK: - Preview

#Preview("Editor Sheet") {
    MeetingEditorSheet(
        meeting: Meeting(
            title: "Weekly Standup",
            scheduledStartDate: Date(),
            scheduledEndDate: Date().addingTimeInterval(3600),
            status: .scheduled
        ),
        onSave: { _, _, _ in }
    )
    .frame(width: 450, height: 350)
}

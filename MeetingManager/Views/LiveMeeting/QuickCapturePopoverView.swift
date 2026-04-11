import SwiftUI

/// A small popover for quickly capturing action items during a live meeting.
/// Triggered via Cmd+Shift+A or a toolbar button.
struct QuickCapturePopoverView: View {
    let meetingId: String
    var onSave: () -> Void
    var onCancel: () -> Void

    @State private var titleText: String = ""
    @State private var assigneeText: String = ""
    @State private var dueDateText: String = ""
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case title, assignee, dueDate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text("Quick Capture")
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
            }

            // Fields
            VStack(alignment: .leading, spacing: 10) {
                // Title (required)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Action item", systemImage: "checkmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                    TextField("e.g. Follow up with design team", text: $titleText)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundStyle(Color.appTextPrimary)
                        .focused($focusedField, equals: .title)
                        .padding(8)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(focusedField == .title ? Color.appAccent.opacity(0.6) : Color.appSeparator, lineWidth: 1)
                        )
                        .onSubmit { focusedField = .assignee }
                }

                // Assignee (optional)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Assignee", systemImage: "person")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                    TextField("Optional — e.g. Sarah", text: $assigneeText)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundStyle(Color.appTextPrimary)
                        .focused($focusedField, equals: .assignee)
                        .padding(8)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(focusedField == .assignee ? Color.appAccent.opacity(0.6) : Color.appSeparator, lineWidth: 1)
                        )
                        .onSubmit { focusedField = .dueDate }
                }

                // Due date (optional, natural language)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Due date", systemImage: "calendar")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                    TextField("Optional — e.g. Friday, next week, Apr 20", text: $dueDateText)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundStyle(Color.appTextPrimary)
                        .focused($focusedField, equals: .dueDate)
                        .padding(8)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(focusedField == .dueDate ? Color.appAccent.opacity(0.6) : Color.appSeparator, lineWidth: 1)
                        )
                        .onSubmit { saveIfValid() }
                }
            }

            // Buttons
            HStack(spacing: 10) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Spacer()

                Button {
                    saveIfValid()
                } label: {
                    HStack(spacing: 5) {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        }
                        Text("Save")
                    }
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(titleText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.appAccent.opacity(0.4) : Color.appAccent)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(titleText.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(Color.appBackground)
        .onAppear {
            focusedField = .title
        }
    }

    // MARK: - Save

    private func saveIfValid() {
        let trimmedTitle = titleText.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        isSaving = true
        let parsedDate = NaturalLanguageDateParser.parse(dueDateText)
        let trimmedAssignee = assigneeText.trimmingCharacters(in: .whitespaces)

        var item = ActionItem(
            meetingId: meetingId,
            title: trimmedTitle,
            assignee: trimmedAssignee.isEmpty ? nil : trimmedAssignee,
            dueDate: parsedDate
        )

        Task {
            do {
                try await ActionItemRepository().save(&item)
                await MainActor.run {
                    isSaving = false
                    onSave()
                }
            } catch {
                print("QuickCapture: failed to save action item: \(error)")
                await MainActor.run { isSaving = false }
            }
        }
    }
}

// MARK: - Natural Language Date Parser

enum NaturalLanguageDateParser {

    /// Parses a natural-language date string into a `Date`.
    /// Supports: "today", "tomorrow", "next week", weekday names,
    /// abbreviated month+day ("Apr 20"), ISO dates ("2026-04-20").
    /// Returns `nil` if the string is empty or cannot be parsed.
    static func parse(_ input: String) -> Date? {
        let raw = input.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }

        let lower = raw.lowercased()
        let calendar = Calendar.current
        let now = Date()

        // "today"
        if lower == "today" {
            return calendar.startOfDay(for: now)
        }

        // "tomorrow"
        if lower == "tomorrow" {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        }

        // "next week" — Monday of the following week
        if lower == "next week" {
            return calendar.nextDate(
                after: calendar.startOfDay(for: now),
                matching: DateComponents(weekday: 2), // 2 = Monday
                matchingPolicy: .nextTime
            )
        }

        // Weekday names (e.g. "friday", "next friday")
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (index, name) in weekdays.enumerated() {
            if lower.contains(name) {
                let targetWeekday = index + 1 // Calendar.weekday is 1-indexed
                let currentWeekday = calendar.component(.weekday, from: now)
                var daysAhead = targetWeekday - currentWeekday
                if daysAhead <= 0 { daysAhead += 7 }
                return calendar.date(byAdding: .day, value: daysAhead, to: calendar.startOfDay(for: now))
            }
        }

        // Try common date formatters
        let formatters: [DateFormatter] = [
            { let f = DateFormatter(); f.dateFormat = "MMM d"; f.locale = Locale(identifier: "en_US"); return f }(),
            { let f = DateFormatter(); f.dateFormat = "MMM dd"; f.locale = Locale(identifier: "en_US"); return f }(),
            { let f = DateFormatter(); f.dateFormat = "MMMM d"; f.locale = Locale(identifier: "en_US"); return f }(),
            { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US"); return f }(),
            { let f = DateFormatter(); f.dateFormat = "M/d"; f.locale = Locale(identifier: "en_US"); return f }(),
            { let f = DateFormatter(); f.dateFormat = "M/d/yyyy"; f.locale = Locale(identifier: "en_US"); return f }(),
        ]

        let currentYear = calendar.component(.year, from: now)
        for formatter in formatters {
            if let date = formatter.date(from: raw) {
                // For formats without a year, attach the current (or next) year
                var components = calendar.dateComponents([.month, .day], from: date)
                if formatter.dateFormat?.contains("yyyy") == false {
                    let nowComponents = calendar.dateComponents([.month, .day], from: now)
                    // If the date has already passed this year, assume next year
                    let isInFuture = (components.month ?? 0) > (nowComponents.month ?? 0)
                        || ((components.month ?? 0) == (nowComponents.month ?? 0) && (components.day ?? 0) >= (nowComponents.day ?? 0))
                    components.year = isInFuture ? currentYear : currentYear + 1
                } else {
                    components = calendar.dateComponents([.year, .month, .day], from: date)
                }
                return calendar.date(from: components)
            }
        }

        return nil
    }
}

import SwiftUI

/// launchd ジョブの StartCalendarInterval / StartInterval を編集するシート
struct ScheduleEditorView: View {
    let job: MonitoredItem.LaunchdJob
    /// XML コメントは書き出しで消えるので、保存前に知らせる
    let hasComments: Bool
    let isSaving: Bool
    /// 直前の保存に失敗した理由。シートは閉じずに入力を残すので、直して保存し直せる
    let failureMessage: String?
    let save: (Schedule) -> Void

    @State private var viewModel: ViewModel
    @Environment(\.dismiss) private var dismiss

    init(job: MonitoredItem.LaunchdJob, hasComments: Bool, isSaving: Bool, failureMessage: String? = nil, save: @escaping (Schedule) -> Void) {
        self.job = job
        self.hasComments = hasComments
        self.isSaving = isSaving
        self.failureMessage = failureMessage
        self.save = save
        _viewModel = State(initialValue: ViewModel(schedule: job.schedule))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Label") {
                        Text(job.label)
                            .font(.Mono.regular)
                    }

                    LabeledContent("Saves To") {
                        VStack(alignment: .trailing, spacing: Spacing.micro) {
                            Text((job.plistDestinationURL ?? job.plistURL).path(percentEncoded: false).abbreviatingHome)
                                .font(.Mono.regular)
                                .textSelection(.enabled)

                            if job.plistDestinationURL != nil {
                                Text("Updates the file that the symbolic link \(job.plistURL.lastPathComponent) points to")
                                    .font(.Small.regular)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.Status.warning)
                    }
                } footer: {
                    Text("Before saving, Breaker backs up the original file to ~/Library/Application Support/Breaker/backups.")
                        .font(.Small.regular)
                        .foregroundStyle(.secondary)
                }

                Section("Launch Trigger") {
                    Picker("Type", selection: $viewModel.mode) {
                        ForEach(ViewModel.Mode.allCases, id: \.self) { mode in
                            Text(mode.title)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch viewModel.mode {
                    case .none:
                        Text("Doesn't run at specific times or intervals")
                            .foregroundStyle(.secondary)

                    case .calendar:
                        ForEach($viewModel.rows) { $row in
                            EntryRow(row: $row, canRemove: viewModel.rows.count > 1) {
                                viewModel.removeRow(row.id)
                            }
                        }

                        Button("Add Time", systemImage: "plus") {
                            viewModel.addRow()
                        }

                    case .interval:
                        IntervalRow(value: $viewModel.intervalValue, unit: $viewModel.intervalUnit, problem: viewModel.intervalProblem)
                    }
                }

                Section("Schedule After Saving") {
                    if let schedule = viewModel.schedule {
                        LabeledContent("Schedule") {
                            Text(schedule.summaryLines.joined(separator: "\n"))
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledContent(
                            "Next Run",
                            value: schedule.nextRun(after: .now, lastRun: job.lastRun).map { MonitoredItem.format($0) } ?? "—"
                        )
                    } else {
                        Text("Fix the entries above to see the schedule here")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            if let failureMessage {
                Label {
                    ProblemText(problem: failureMessage)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Color.Status.failure)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], Spacing.comfortable)
            }

            HStack(spacing: Spacing.tight) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)

                    Text("Saving…")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    if let schedule = viewModel.schedule {
                        save(schedule)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.schedule == nil)
            }
            .disabled(isSaving)
            .padding(Spacing.comfortable)
        }
        .frame(width: Layout.sheetWidth)
        .frame(minHeight: Layout.sheetMinHeight)
    }

    private var warnings: [String] {
        (hasComments ? [String(localized: "This plist has XML comments. Saving removes them.")] : []) + viewModel.lossNotes
    }
}

#Preview("Weekdays 9:00") {
    ScheduleEditorView(
        job: .sample("com.example.backup", schedule: Schedule(calendarEntries: (1...5).map { .init(minute: 0, hour: 9, weekday: $0) })),
        hasComments: false,
        isSaving: false
    ) { _ in }
}

#Preview("Monthly on Day 1 11:00") {
    ScheduleEditorView(
        job: .sample("com.example.monthly-invoice", schedule: Schedule(calendarEntries: [.init(minute: 0, hour: 11, day: 1)])),
        hasComments: false,
        isSaving: false
    ) { _ in }
}

#Preview("Hourly 7:00–23:00 and Monthly Range") {
    ScheduleEditorView(
        job: .sample(
            "com.example.inbox-sync",
            schedule: Schedule(calendarEntries: (7...23).map { .init(minute: 0, hour: $0) } + (9...17).map { .init(minute: 30, hour: $0, day: 15) })
        ),
        hasComments: false,
        isSaving: false
    ) { _ in }
}

#Preview("Every Hour at :15") {
    ScheduleEditorView(
        job: .sample("com.example.feed-fetch", schedule: Schedule(calendarEntries: [.init(minute: 15)])),
        hasComments: false,
        isSaving: false
    ) { _ in }
}

#Preview("Every 30 Minutes with Comments") {
    ScheduleEditorView(
        job: .sample("com.example.calendar-sync", schedule: Schedule(interval: 1800, runAtLoad: true), lastRun: .now.addingTimeInterval(-600)),
        hasComments: true,
        isSaving: false
    ) { _ in }
}

#Preview("KeepAlive Only") {
    ScheduleEditorView(
        job: .sample("com.example.web-server", schedule: Schedule(runAtLoad: true, keepAlive: true)),
        hasComments: false,
        isSaving: false
    ) { _ in }
}

#Preview("Save Failed") {
    ScheduleEditorView(
        job: .sample("com.example.daily-sales-report", schedule: Schedule(calendarEntries: [.init(minute: 30, hour: 7)])),
        hasComments: false,
        isSaving: false,
        failureMessage: PlistEditorError.lintFailed("Unexpected character < at line 12").localizedDescription
    ) { _ in }
}

#Preview("Daily 8:00 (Saving)") {
    ScheduleEditorView(
        job: .sample("com.example.price-watch", schedule: Schedule(calendarEntries: [.init(minute: 0, hour: 8)])),
        hasComments: false,
        isSaving: true
    ) { _ in }
}

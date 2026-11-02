import OpenCleanAppModel
import SpaceKit
import SwiftUI

// MARK: Large & old files

struct LargeFilesTab: View {
    @Environment(SpaceLensModel.self) private var model

    var body: some View {
        switch model.largePhase {
        case .idle:
            SpaceLensHomeView(
                symbol: "doc.badge.clock.fill", headline: String(localized: "Find large and old files"),
                message:
                    String(
                        localized:
                            "Looks through your home folder for big files, like videos, disk images and installers. ~/Library and apps are left out."
                    ),
                scan: { model.startLargeScan() },
                options: {
                    LargeFileOptionsBar()
                })
        case .scanning:
            let progress = model.largeProgress
            SpaceLensScanningView(
                status: String(localized: "Looking for large files…"), bigNumber: progress.files.formatted(),
                detail: String(localized: "files looked at · \(formatBytes(progress.bytes))"),
                stop: { model.stopScan(.large) })
        case .results:
            LargeFilesResultsView()
        }
    }
}

/// Size threshold, age and Documents/Desktop opt-in.
struct LargeFileOptionsBar: View {
    @Environment(SpaceLensModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 14) {
            Picker("Larger than", selection: $model.largeFilter.minimumSize) {
                ForEach(LargeFileFilter.thresholds, id: \.self) { Text(formatThreshold($0)).tag($0) }
            }
            .fixedSize()
            Picker("Not opened for", selection: $model.largeFilter.notOpenedForDays) {
                ForEach(LargeFileFilter.ageChoices, id: \.self) { Text(ageLabel($0)).tag($0) }
            }
            .fixedSize()
            Toggle(
                "Include Documents and Desktop",
                isOn: Binding(get: { model.includeUserContent }, set: { model.setIncludeUserContent($0) })
            )
            .toggleStyle(.checkbox)
            .help("Files there can be moved to the Trash only one at a time, by ticking each file.")
        }
        .font(.system(size: 13))
        .tint(Theme.accent)
    }

    private func formatThreshold(_ bytes: Int64) -> String {
        formatBytes(bytes)
    }

    private func ageLabel(_ days: Int?) -> String {
        switch days {
        case nil: String(localized: "Any time")
        case 90: String(localized: "3 months")
        case 180: String(localized: "6 months")
        case 365: String(localized: "1 year")
        case let days?: String(localized: "\(days) days")
        }
    }
}

struct LargeFilesResultsView: View {
    @Environment(SpaceLensModel.self) private var model

    var body: some View {
        let files = model.visibleLargeFiles
        let groups = LargeFileFilter.grouped(files)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SpaceLensBackButton(title: "Start over") { model.startOver(.large) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(headline(files)).font(.system(size: 30, weight: .bold))
                        Text("Sorted by size. Tick the ones you no longer need; they go to the Trash.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    LargeFileOptionsBar()
                    if let result = model.largeResult, !result.isComplete {
                        Label(
                            "The scan was stopped early. Results are partial.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(Theme.gold)
                    }
                    if let report = model.lastReport { SpaceLensReportBanner(report: report) }
                    if groups.isEmpty {
                        SpaceLensEmptyState(
                            symbol: "checkmark.circle", title: String(localized: "No matching files"),
                            message: emptyMessage)
                    }
                    ForEach(groups, id: \.kind) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(group.kind.localizedName).font(.system(size: 18, weight: .bold))
                                Spacer()
                                Text(formatBytes(group.files.reduce(0) { $0 + $1.size }))
                                    .font(.system(size: 14))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            SpaceLensPanel {
                                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                                    if index > 0 { SpaceLensDivider() }
                                    row(file)
                                }
                            }
                        }
                    }
                    SpaceLensAccessNote(unreadable: model.largeResult?.unreadableCount ?? 0)
                }
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            SpaceLensTrashBar()
        }
    }

    private func row(_ file: LargeFile) -> some View {
        let candidate = model.candidate(for: file)
        var details = [spaceLensFolder(file.path, home: model.home)]
        if let opened = file.lastOpened { details.append(String(localized: "Last opened \(spaceLensDate(opened))")) }
        return SpaceLensItemRow(
            path: file.path, title: file.name, subtitle: details.joined(separator: " · "), size: file.size,
            isSelected: model.isSelected(file.path),
            disabledReason: model.protection(for: file.path, isDirectory: file.snapshot.isDirectory)
                .map { String(localized: "Can’t be moved to the Trash: \($0)") },
            onToggle: { model.toggle(candidate) },
            accessory: {
                if file.isUserContent { SpaceLensTag(text: userContentLabel(file.path, home: model.home)) }
            })
    }

    private func headline(_ files: [LargeFile]) -> String {
        guard !files.isEmpty else { return String(localized: "No large files found") }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        return "\(String(localized: "\(files.count) files")) · \(formatBytes(total))"
    }

    private var emptyMessage: String {
        let size = formatBytes(model.largeFilter.minimumSize)
        if let days = model.largeFilter.notOpenedForDays {
            return String(
                localized: "Nothing over \(size) that hasn’t been opened in \(days) days. Try a smaller size.")
        }
        return String(localized: "Nothing over \(size). Try a smaller size.")
    }
}

// MARK: Duplicates

struct DuplicatesTab: View {
    @Environment(SpaceLensModel.self) private var model

    var body: some View {
        switch model.duplicatePhase {
        case .idle:
            SpaceLensHomeView(
                symbol: "square.on.square.fill", headline: String(localized: "Find duplicate files"),
                message:
                    String(
                        localized:
                            "Compares files byte for byte in the folders below. Nothing is picked for you, and one copy of each file always stays."
                    ),
                scanDisabled: model.duplicateRoots.isEmpty,
                scan: { model.startDuplicateScan() },
                options: {
                    DuplicateRootsBar()
                })
        case .scanning:
            let progress = model.duplicateProgress
            if progress.phase == .comparing, progress.toCompare > 0 {
                let percent = Int(Double(progress.compared) / Double(max(1, progress.toCompare)) * 100)
                SpaceLensScanningView(
                    status: String(localized: "Comparing files…"), bigNumber: "\(min(100, percent))%",
                    detail: String(
                        localized: "\(progress.compared.formatted()) of \(progress.toCompare.formatted()) checks"),
                    stop: { model.stopScan(.duplicates) })
            } else {
                SpaceLensScanningView(
                    status: String(localized: "Listing files…"), bigNumber: progress.files.formatted(),
                    detail: String(localized: "files looked at · \(formatBytes(progress.bytes))"),
                    stop: { model.stopScan(.duplicates) })
            }
        case .results:
            DuplicatesResultsView()
        }
    }
}

/// The folders the duplicate finder looks in, as removable pills.
struct DuplicateRootsBar: View {
    @Environment(SpaceLensModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(model.duplicateRoots, id: \.self) { root in
                    HStack(spacing: 6) {
                        Text(spaceLensDisplayPath(root, home: model.home)).lineLimit(1)
                        Button {
                            model.removeDuplicateRoot(root)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("Remove \((root as NSString).lastPathComponent)")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.white.opacity(0.12), in: Capsule())
                }
            }
            HStack(spacing: 10) {
                Button("Add Folder") {
                    if let path = chooseFolder(startingAt: model.home, prompt: String(localized: "Add")) {
                        model.addDuplicateRoot(path)
                    }
                }
                .buttonStyle(CapsuleButtonStyle())
                Button("Reset") { model.resetDuplicateRoots() }
                    .buttonStyle(CapsuleButtonStyle())
            }
            Text("Files under 1 MB, apps and ~/Library are skipped.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

struct DuplicatesResultsView: View {
    @Environment(SpaceLensModel.self) private var model

    var body: some View {
        let groups = model.duplicateResult?.groups ?? []
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    SpaceLensBackButton(title: "Start over") { model.startOver(.duplicates) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(headline(groups)).font(.system(size: 30, weight: .bold))
                        Text(
                            "Tick the copies you don’t need; they go to the Trash. One copy of each file always stays, and nothing is picked for you."
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let result = model.duplicateResult, !result.isComplete {
                        Label(
                            "The scan was stopped early. Results are partial.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(Theme.gold)
                    }
                    if let report = model.lastReport { SpaceLensReportBanner(report: report) }
                    if groups.isEmpty {
                        SpaceLensEmptyState(
                            symbol: "checkmark.circle", title: String(localized: "No duplicates"),
                            message: String(localized: "No identical files over 1 MB in these folders."))
                    }
                    ForEach(groups) { group in
                        DuplicateGroupPanel(group: group)
                    }
                    SpaceLensAccessNote(unreadable: model.duplicateResult?.unreadableCount ?? 0)
                    if !groups.isEmpty {
                        Text("Copies made by APFS cloning share space on disk, so moving one may free less than shown.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            SpaceLensTrashBar()
        }
    }

    private func headline(_ groups: [DuplicateGroup]) -> String {
        guard !groups.isEmpty else { return String(localized: "No duplicates found") }
        let total = groups.reduce(Int64(0)) { $0 + $1.reclaimable }
        return "\(formatBytes(total)) · \(String(localized: "\(groups.count) duplicate groups"))"
    }
}

struct DuplicateGroupPanel: View {
    @Environment(SpaceLensModel.self) private var model
    let group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.files.first?.name ?? "")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    verbatim:
                        "\(String(localized: "\(group.files.count) copies")) · \(String(localized: "\(formatBytes(group.logicalSize)) each"))"
                )
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                Spacer()
                Text("\(formatBytes(group.reclaimable)) extra")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            SpaceLensPanel {
                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { SpaceLensDivider() }
                    row(file)
                }
            }
        }
    }

    private func row(_ file: DuplicateFile) -> some View {
        let selected = model.isSelected(file.path)
        let protection = model.protection(for: file.path, isDirectory: false)
        let reason: String? =
            if let protection {
                String(localized: "Can’t be moved to the Trash: \(protection)")
            } else if !model.canSelect(file, in: group) {
                String(localized: "Keep at least one copy")
            } else {
                nil
            }
        return SpaceLensItemRow(
            path: file.path, title: file.name,
            subtitle: String(
                localized: "\(spaceLensFolder(file.path, home: model.home)) · Modified \(spaceLensDate(file.modified))"),
            size: file.size, isSelected: selected, disabledReason: reason,
            onToggle: { model.toggle(file, in: group) },
            accessory: {
                if file.path == group.suggestedKeep {
                    SpaceLensTag(text: String(localized: "Suggested to keep"), color: Theme.accent)
                }
                if file.isUserContent { SpaceLensTag(text: userContentLabel(file.path, home: model.home)) }
            })
    }
}

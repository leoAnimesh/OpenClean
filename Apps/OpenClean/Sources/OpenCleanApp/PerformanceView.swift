import OpenCleanAppModel
import SwiftUI

enum PerformanceSection: String, CaseIterable, Identifiable {
    case overview, memoryGPU, consumers, loginItems, maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .memoryGPU: String(localized: "Memory & GPU")
        case .consumers: String(localized: "Heavy consumers")
        case .loginItems: String(localized: "Login items")
        case .maintenance: String(localized: "Maintenance")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: String(localized: "Live figures from your Mac, updated every 2 seconds while you watch.")
        case .memoryGPU: String(localized: "How your apps and the GPU share your Mac's memory.")
        case .consumers: String(localized: "Apps and processes using the most CPU, GPU and memory right now.")
        case .loginItems: String(localized: "What starts when you log in, and who installed it.")
        case .maintenance: String(localized: "One-click macOS housekeeping. Each task says exactly what it runs.")
        }
    }
}

struct PerformanceView: View {
    @Environment(PerformanceModel.self) private var model
    @State private var section: PerformanceSection = .overview

    var body: some View {
        if model.runningTask != nil || model.lastResult != nil {
            // Long tasks and their outcome get the whole screen; the outcome has Done to go back.
            MaintenanceProgressView()
                .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Performance").font(.system(size: 30, weight: .bold))
                    Text(section.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                .padding(.bottom, 16)
                Picker("Section", selection: $section) {
                    ForEach(PerformanceSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Size to the segments so the bar's leading edge lines up with the title and cards.
                .fixedSize()
                .padding(.bottom, 18)

                Group {
                    switch section {
                    case .overview: PerformanceOverview()
                    case .memoryGPU: MemoryGPUView()
                    case .consumers: HeavyConsumersView()
                    case .loginItems: LoginItemsView()
                    case .maintenance: MaintenanceListView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

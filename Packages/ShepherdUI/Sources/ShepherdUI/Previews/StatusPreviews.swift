import SwiftUI

#Preview("Agent state") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            ForEach(AgentState.allCases, id: \.self) { state in
                HStack(spacing: 14) {
                    NWStatusPill(state, label: state == .stuck ? "Stuck 14m" : nil)
                    HStack(spacing: NW.Space.m) {
                        NWStatusDot(state)
                        Text(state.label).font(.nwSans(12.5)).foregroundStyle(.nw.textSecondary)
                    }
                    NWStateGlyph(state)
                    NWBranchGlyph(state)
                }
            }
        }
    }
}

#Preview("Progress") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().progressViewStyle(.nwSpinner)
                Text("Tool or turn in progress").font(.nwSans(12.5)).foregroundStyle(.nw.textPrimary)
            }
            HStack(spacing: 10) {
                NWSparkline([2, 4, 3, 7, 5, 9, 4, 6, 5, 8])
                Text("Tool calls per minute").font(.nwSans(12.5)).foregroundStyle(.nw.textPrimary)
            }
            ProgressView(value: 0.62).progressViewStyle(.nwBar)
            ProgressView(value: 0.8).progressViewStyle(.nwBar(tint: .nw.lantern))
            ProgressView(value: 1).progressViewStyle(.nwBar(tint: .nw.done))
            NWStepStrip([.done, .done, .done, .running, .attention, nil])
        }
        .frame(width: 320)
    }
}

#Preview("Banners") {
    NWPreviewBoth {
        VStack(spacing: 10) {
            NWBanner(.attention, title: "ios asks: keep MobileTokens as an alias?",
                     message: "Migrating touches 31 call sites; an alias is 4 lines but leaves two token systems.") {
                Button("Migrate") {}.buttonStyle(.nw(.primary, size: .s))
                Button("Keep alias") {}.buttonStyle(.nw(.secondary, size: .s))
                Button("Reply…") {}.buttonStyle(.nw(.ghost, size: .s))
            }
            NWBanner(.failed, title: "tests failed 3 times", message: "3 snapshot tests fail at Dynamic Type XL. Retrying won’t help.") {
                Button("Open replay") {}.buttonStyle(.nw(.secondary, size: .s))
            }
            NWBanner(.running, title: "horizon reconnecting", message: "Last seen 3h ago. Remote agents resume when it’s back.",
                     systemImage: "desktopcomputer") {
                Button("Retry now") {}.buttonStyle(.nw(.secondary, size: .s))
            }
            NWBanner(.done, title: "Mission done", message: "Every “done when” check is verified.")
        }
        .frame(width: 560)
    }
}

#Preview("Toast, empty, shimmer") {
    @Previewable @State var toast: NWToast? = NWToast(.done, subject: "worker", message: "finished · 5 files", action: .init("Open") {})
    NWPreviewBoth {
        VStack(spacing: NW.Space.xl) {
            NWToastView(toast: NWToast(.done, subject: "worker", message: "finished · 5 files", action: .init("Open") {})) {}
            NWEmptyState(Text("No agents on watch"), message: "Start one here, or pick a repo and let a mission plan the work.") {
                Button("New agent") {}.buttonStyle(.nw(.primary))
                Button("New mission") {}.buttonStyle(.nw(.secondary))
            }
            NWLoadingRows()
            NWWordmark(size: .large)
        }
        .frame(width: 360)
        .nwToast(item: $toast)
    }
}

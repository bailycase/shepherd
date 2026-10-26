import SwiftUI

#Preview("Agent state") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            ForEach(AgentState.allCases, id: \.self) { state in
                HStack(spacing: 14) {
                    SHStatusPill(state, label: state == .stuck ? "Stuck 14m" : nil)
                    HStack(spacing: SH.Space.m) {
                        SHStatusDot(state)
                        Text(state.label).font(.shSans(12.5)).foregroundStyle(.sh.textSecondary)
                    }
                    SHStateGlyph(state)
                    SHBranchGlyph(state)
                }
            }
        }
    }
}

#Preview("Progress") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().progressViewStyle(.shSpinner)
                Text("Tool or turn in progress").font(.shSans(12.5)).foregroundStyle(.sh.textPrimary)
            }
            HStack(spacing: 10) {
                SHSparkline([2, 4, 3, 7, 5, 9, 4, 6, 5, 8])
                Text("Tool calls per minute").font(.shSans(12.5)).foregroundStyle(.sh.textPrimary)
            }
            ProgressView(value: 0.62).progressViewStyle(.shBar)
            ProgressView(value: 0.8).progressViewStyle(.shBar(tint: .sh.lantern))
            ProgressView(value: 1).progressViewStyle(.shBar(tint: .sh.done))
            SHStepStrip([.done, .done, .done, .running, .attention, nil])
        }
        .frame(width: 320)
    }
}

#Preview("Banners") {
    SHPreviewBoth {
        VStack(spacing: 10) {
            SHBanner(.attention, title: "ios asks: keep MobileTokens as an alias?",
                     message: "Migrating touches 31 call sites; an alias is 4 lines but leaves two token systems.") {
                Button("Migrate") {}.buttonStyle(.sh(.primary, size: .s))
                Button("Keep alias") {}.buttonStyle(.sh(.secondary, size: .s))
                Button("Reply…") {}.buttonStyle(.sh(.ghost, size: .s))
            }
            SHBanner(.failed, title: "tests failed 3 times", message: "3 snapshot tests fail at Dynamic Type XL. Retrying won’t help.") {
                Button("Open replay") {}.buttonStyle(.sh(.secondary, size: .s))
            }
            SHBanner(.running, title: "horizon reconnecting", message: "Last seen 3h ago. Remote agents resume when it’s back.",
                     systemImage: "desktopcomputer") {
                Button("Retry now") {}.buttonStyle(.sh(.secondary, size: .s))
            }
            SHBanner(.done, title: "Mission done", message: "Every “done when” check is verified.")
        }
        .frame(width: 560)
    }
}

#Preview("Toast, empty, shimmer") {
    @Previewable @State var toast: SHToast? = SHToast(.done, subject: "worker", message: "finished · 5 files", action: .init("Open") {})
    SHPreviewBoth {
        VStack(spacing: SH.Space.xl) {
            SHToastView(toast: SHToast(.done, subject: "worker", message: "finished · 5 files", action: .init("Open") {})) {}
            SHEmptyState(Text("No agents on watch"), message: "Start one here, or pick a repo and let a mission plan the work.") {
                Button("New agent") {}.buttonStyle(.sh(.primary))
                Button("New mission") {}.buttonStyle(.sh(.secondary))
            }
            SHLoadingRows()
            SHWordmark(size: .large)
        }
        .frame(width: 360)
        .shToast(item: $toast)
    }
}

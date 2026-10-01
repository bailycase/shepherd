import SwiftUI

/// The single model · thinking control on NWComposer. Standard speed draws no glyph.
public struct NWModelSettingsLabel: View {
  let model: String
  let thinking: String?
  let fast: Bool
  let changeable: Bool

  public init(model: String, thinking: String? = nil, fast: Bool = false, changeable: Bool = true) {
    self.model = model
    self.thinking = thinking
    self.fast = fast
    self.changeable = changeable
  }

  public var body: some View {
    HStack(spacing: NW.Space.s) {
      Text(model.isEmpty ? "Default" : model).font(.nwMono(12)).lineLimit(1).truncationMode(.middle)
      if let thinking {
        Text("·").foregroundStyle(Color.nw.textTertiary)
        Text(thinking).fixedSize()
      }
      if fast {
        Image(systemName: "bolt").foregroundStyle(Color.nw.lanternText)
          .font(.nwSans(NWComposerMetrics.chipSymbol, .medium)).accessibilityLabel("Fast")
      }
      if changeable { NWChipChevron() }
    }
  }
}

/// The quiet worktree chip in the composer's trailing controls.
public struct NWComposerBranchLabel: View {
  let branch: String
  let changes: Int
  let checkout: Bool
  let host: String?

  public init(branch: String, changes: Int, checkout: Bool = false, host: String? = nil) {
    self.branch = branch
    self.changes = changes
    self.checkout = checkout
    self.host = host
  }

  public var body: some View {
    HStack(spacing: NW.Space.s) {
      Image(systemName: checkout ? "house" : "square.on.square")
        .font(.nwSans(NWComposerMetrics.branchSymbol, .medium))
      Text(branch).font(.nwMono(NWComposerMetrics.branchText)).foregroundStyle(Color.nw.textPrimary)
        .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
      if changes > 0 {
        Text("●\(changes)").font(.nwMono(NWComposerMetrics.branchCount)).foregroundStyle(
          Color.nw.lanternText
        )
        .fixedSize().nwContentTransition(.numeric())
      }
      if let host {
        Text(host).font(.nwMono(NWComposerMetrics.branchCount)).foregroundStyle(
          Color.nw.textTertiary)
      }
      NWChipChevron()
    }
  }
}

/// NWComposer's one popover, with recent models and the current model's real capabilities.
public struct NWModelSettings: View {
  let models: [NWModelOption]
  let thinking: [NWThinkingOption]
  let currentThinking: String?
  let speeds: [NWSpeedOption]
  let currentSpeed: String
  let modelEnabled: Bool
  let thinkingEnabled: Bool
  let speedEnabled: Bool
  let maxHeight: CGFloat?
  let chooseModel: (NWModelOption) -> Void
  let chooseThinking: (String) -> Void
  let chooseSpeed: (String) -> Void
  let allModels: () -> Void
  let close: () -> Void
  @State private var selection = 0
  @FocusState private var focused: Bool

  public init(
    models: [NWModelOption], thinking: [NWThinkingOption], currentThinking: String?,
    speeds: [NWSpeedOption], currentSpeed: String, modelEnabled: Bool = true,
    thinkingEnabled: Bool = true, speedEnabled: Bool = true, maxHeight: CGFloat? = nil,
    chooseModel: @escaping (NWModelOption) -> Void, chooseThinking: @escaping (String) -> Void,
    chooseSpeed: @escaping (String) -> Void, allModels: @escaping () -> Void,
    close: @escaping () -> Void
  ) {
    self.models = models
    self.thinking = thinking
    self.currentThinking = currentThinking
    self.speeds = speeds
    self.currentSpeed = currentSpeed
    self.modelEnabled = modelEnabled
    self.thinkingEnabled = thinkingEnabled
    self.speedEnabled = speedEnabled
    self.maxHeight = maxHeight
    self.chooseModel = chooseModel
    self.chooseThinking = chooseThinking
    self.chooseSpeed = chooseSpeed
    self.allModels = allModels
    self.close = close
  }

  public var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          NWModelSettingsHeader("Model")
          ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
            NWMenuRow(
              highlighted: selection == index, action: { if modelEnabled { chooseModel(model) } },
              onHover: { selection = index }
            ) {
              Text(model.title).font(.nwMono(12)).foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1).truncationMode(.middle)
              Spacer(minLength: NW.Space.m)
              if model.isCurrent {
                if currentSpeed != "standard", !speeds.isEmpty {
                  Image(systemName: "bolt").foregroundStyle(Color.nw.lanternText)
                }
                Image(systemName: "checkmark").foregroundStyle(Color.nw.running)
              }
            }
            .disabled(!modelEnabled)
            .id(index)
          }
          NWMenuRow(
            highlighted: selection == models.count, action: { if modelEnabled { allModels() } },
            onHover: { selection = models.count }
          ) {
            Text("All models…").font(.nw(.ui)).foregroundStyle(Color.nw.textSecondary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(Color.nw.textTertiary)
          }
          .disabled(!modelEnabled)
          .id(models.count)
          if !thinking.isEmpty {
            NWHairline().padding(.vertical, NW.Space.xs)
            NWModelSettingsHeader("Thinking")
            ForEach(Array(thinking.enumerated()), id: \.element.id) { index, option in
              NWMenuRow(
                highlighted: selection == models.count + 1 + index,
                action: { chooseThinking(option.id) },
                onHover: { selection = models.count + 1 + index }
              ) {
                Text(option.title).font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary)
                  .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                if let note = option.note {
                  Text(note).font(.nwSans(12)).foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if option.id == currentThinking {
                  Image(systemName: "checkmark").foregroundStyle(Color.nw.running)
                }
              }
              .disabled(!thinkingEnabled)
              .id(models.count + 1 + index)
              .accessibilityAddTraits(option.id == currentThinking ? .isSelected : [])
            }
          }
          if !speeds.isEmpty {
            NWHairline().padding(.vertical, NW.Space.xs)
            NWModelSettingsHeader("Speed")
            NWModelSettingsSegments(
              options: speeds.map { ($0.id, $0.title) },
              current: currentSpeed, highlighted: selection - models.count - 1 - thinking.count,
              enabled: speedEnabled, boosted: speeds.first(where: \.boosted)?.id,
              start: models.count + 1 + thinking.count,
              hover: { selection = models.count + 1 + thinking.count + $0 }, choose: chooseSpeed)
          }
        }
        .padding(NW.Space.s)
      }
      .scrollBounceBehavior(.basedOnSize)
      .focusable().focusEffectDisabled().focused($focused)
      .onKeyPress(.upArrow) {
        selection = max(0, selection - 1)
        proxy.scrollTo(selection, anchor: .center)
        return .handled
      }
      .onKeyPress(.downArrow) {
        selection = min(models.count + thinking.count + speeds.count, selection + 1)
        proxy.scrollTo(selection, anchor: .center)
        return .handled
      }
    }
    .frame(width: NWComposerMetrics.modelSettingsWidth)
    .frame(maxHeight: maxHeight)
    .fixedSize(horizontal: false, vertical: true)
    .nwPopover()
    .onAppear { focused = true }
    .onKeyPress(.return) {
      chooseSelection()
      return .handled
    }
    .onKeyPress(.escape) {
      close()
      return .handled
    }
    .accessibilityLabel("Model, thinking and speed")
    .onChange(of: models.count + thinking.count + speeds.count) { _, last in
      selection = min(selection, last)
    }
  }

  private func chooseSelection() {
    if selection < models.count {
      if modelEnabled { chooseModel(models[selection]) }
    } else if selection == models.count {
      if modelEnabled { allModels() }
    } else {
      let index = selection - models.count - 1
      if index < thinking.count {
        if thinkingEnabled { chooseThinking(thinking[index].id) }
      } else if speeds.indices.contains(index - thinking.count), speedEnabled {
        chooseSpeed(speeds[index - thinking.count].id)
      }
    }
  }
}

private struct NWModelSettingsHeader: View {
  let title: String
  init(_ title: String) { self.title = title }
  var body: some View {
    Text(title).textCase(.uppercase).font(.nwMono(10, .medium)).tracking(0.6)
      .foregroundStyle(Color.nw.textTertiary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, NW.Space.m).frame(height: NWComposerMetrics.menuHeaderHeight)
      .accessibilityAddTraits(.isHeader)
  }
}

/// Speed tiers share a single segmented row.
private struct NWModelSettingsSegments: View {
  let options: [(String, String)]
  let current: String?
  let highlighted: Int
  let enabled: Bool
  var boosted: String? = nil
  let start: Int
  let hover: (Int) -> Void
  let choose: (String) -> Void

  var body: some View {
    HStack(spacing: NW.Space.xxs) {
      ForEach(Array(options.enumerated()), id: \.element.0) { index, option in
        Button {
          choose(option.0)
        } label: {
          HStack(spacing: NW.Space.xs) {
            if option.0 == boosted {
              Image(systemName: "bolt").foregroundStyle(Color.nw.lanternText)
            }
            Text(option.1).lineLimit(1).fixedSize(horizontal: true, vertical: false)
          }
          .font(.nwSans(12, current == option.0 ? .semibold : .medium))
          .foregroundStyle(current == option.0 ? Color.nw.textPrimary : Color.nw.textSecondary)
          .frame(maxWidth: .infinity).frame(height: NW.Height.controlS)
          .background(
            current == option.0 ? Color.nw.bgSelected : .clear,
            in: RoundedRectangle(cornerRadius: NW.Radius.xs)
          )
          .nwBorder(
            highlighted == index
              ? Color.nw.running : current == option.0 ? Color.nw.lineStrong : .clear,
            radius: NW.Radius.xs)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .id(start + index)
        .onHover { if $0 { hover(index) } }
        .accessibilityAddTraits(current == option.0 ? .isSelected : [])
      }
    }
    .padding(NW.Space.xxs)
    .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
    .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.s)
    .padding(.horizontal, NW.Space.m).padding(.bottom, NW.Space.s)
  }
}

import SwiftUI

/// The single model · thinking button on SHComposer: the model's name in mono, a dot, the
/// thinking level, and a bolt only while speed is Fast (`SHFastBolt`). Standard draws nothing, a
/// model without thinking has no level, and a model without speed has no bolt.
public struct SHModelSettingsLabel: View {
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
    HStack(spacing: SH.Space.s) {
      Text(model.isEmpty ? "Default" : model).font(.shMono(12)).lineLimit(1).truncationMode(.middle)
      if let thinking {
        Text("·").foregroundStyle(Color.sh.textTertiary)
        Text(thinking).fixedSize()
      }
      if fast { SHFastBolt() }
      if changeable { SHChipChevron() }
    }
  }
}

/// The quiet worktree chip in the composer's trailing controls: the glyph, the branch in mono,
/// a lantern ●n for changed files, and the chevron, all in the chip's `textSecondary`.
public struct SHComposerBranchLabel: View {
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
    HStack(spacing: SH.Space.s) {
      Image(systemName: checkout ? "house" : "square.on.square")
        .font(.shSans(SHComposerMetrics.branchSymbol, .medium))
      Text(branch).font(.shMono(SHComposerMetrics.branchText))
        .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
      if changes > 0 {
        Text("●\(changes)").font(.shMono(SHComposerMetrics.branchCount)).foregroundStyle(
          Color.sh.lanternText
        )
        .fixedSize().shContentTransition(.numeric())
      }
      if let host {
        Text(host).font(.shMono(SHComposerMetrics.branchCount)).foregroundStyle(
          Color.sh.textTertiary)
      }
      SHChipChevron()
    }
  }
}

/// Where ↑↓ stop in the popover, top to bottom: each model, All models…, each thinking level,
/// each speed. ↩ chooses the stop, and the pointer moves it too.
struct SHModelSettingsStops: Equatable {
  enum Stop: Equatable {
    case model(Int)
    case allModels
    case thinking(Int)
    case speed(Int)
  }

  var models: Int
  var thinking: Int
  var speeds: Int

  var count: Int { models + 1 + thinking + speeds }

  func stop(at index: Int) -> Stop? {
    guard (0..<count).contains(index) else { return nil }
    if index < models { return .model(index) }
    if index == models { return .allModels }
    let past = index - models - 1
    return past < thinking ? .thinking(past) : .speed(past - thinking)
  }

  func index(of stop: Stop) -> Int {
    switch stop {
    case .model(let index): index
    case .allModels: models
    case .thinking(let index): models + 1 + index
    case .speed(let index): models + 1 + thinking + index
    }
  }

  /// `index` moved by `step`, held inside the list.
  func moved(_ index: Int, by step: Int) -> Int {
    min(max(0, index + step), max(0, count - 1))
  }
}

/// SHComposer's one popover (SHModelSettings): the model, the thinking level and the speed. The
/// button that opens it reads model · thinking, plus a bolt when speed is Fast.
///
/// MODEL lists the current model and one recent (a bolt marks a model with a Fast tier, a check
/// the current one) over All models…, THINKING is a segmented control of the levels the model
/// takes, and SPEED a segmented control of its tiers (Standard | Fast). Only what the model really
/// offers appears: no Speed row for a model without a raised tier. A model choice closes the
/// popover; a level or a speed can change while it stays open. ↑↓ move, ↩ chooses, esc closes.
public struct SHModelSettings: View {
  let models: [SHModelOption]
  let thinking: [SHThinkingOption]
  let currentThinking: String?
  let speeds: [SHSpeedOption]
  let currentSpeed: String
  let modelEnabled: Bool
  let thinkingEnabled: Bool
  let speedEnabled: Bool
  let maxHeight: CGFloat?
  let chooseModel: (SHModelOption) -> Void
  let chooseThinking: (String) -> Void
  let chooseSpeed: (String) -> Void
  let allModels: () -> Void
  let close: () -> Void
  @State private var selection = 0
  @FocusState private var focused: Bool

  public init(
    models: [SHModelOption], thinking: [SHThinkingOption], currentThinking: String?,
    speeds: [SHSpeedOption], currentSpeed: String, modelEnabled: Bool = true,
    thinkingEnabled: Bool = true, speedEnabled: Bool = true, maxHeight: CGFloat? = nil,
    chooseModel: @escaping (SHModelOption) -> Void, chooseThinking: @escaping (String) -> Void,
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

  private var stops: SHModelSettingsStops {
    SHModelSettingsStops(models: models.count, thinking: thinking.count, speeds: speeds.count)
  }

  public var body: some View {
    let stops = stops
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          SHMenuHeader("Model")
          modelRows(stops)
          if !thinking.isEmpty {
            SHHairline().padding(.vertical, SH.Space.xs)
            SHMenuHeader("Thinking")
            SHModelSettingsSegments(
              label: "Thinking",
              segments: thinking.map {
                SHModelSettingsSegment(id: $0.id, title: $0.title, note: $0.note)
              },
              current: currentThinking, highlighted: highlighted(.thinking(0), in: stops, count: thinking.count),
              enabled: thinkingEnabled, start: stops.index(of: .thinking(0)),
              hover: { selection = stops.index(of: .thinking($0)) }, choose: chooseThinking)
          }
          if !speeds.isEmpty {
            SHHairline().padding(.vertical, SH.Space.xs)
            SHMenuHeader("Speed")
            SHModelSettingsSegments(
              label: "Speed",
              segments: speeds.map {
                SHModelSettingsSegment(
                  id: $0.id, title: $0.title, note: $0.detail, bolt: $0.boosted)
              },
              current: currentSpeed, highlighted: highlighted(.speed(0), in: stops, count: speeds.count),
              enabled: speedEnabled, start: stops.index(of: .speed(0)),
              hover: { selection = stops.index(of: .speed($0)) }, choose: chooseSpeed)
          }
        }
        .padding(SH.Space.s)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(width: SHComposerMetrics.modelSettingsWidth)
      .frame(maxHeight: maxHeight)
      .fixedSize(horizontal: false, vertical: true)
      .shPopover()
      // The popover takes the keyboard, not its scroll view (which would scroll on ↑↓ itself),
      // as every composer menu does.
      .focusable().focusEffectDisabled().focused($focused)
      .onAppear { focused = true }
      .onKeyPress(.upArrow) {
        selection = stops.moved(selection, by: -1)
        proxy.scrollTo(selection, anchor: .center)
        return .handled
      }
      .onKeyPress(.downArrow) {
        selection = stops.moved(selection, by: 1)
        proxy.scrollTo(selection, anchor: .center)
        return .handled
      }
      .onKeyPress(.return) {
        chooseSelection()
        return .handled
      }
      .onKeyPress(.escape) {
        close()
        return .handled
      }
    }
    .accessibilityLabel("Model, thinking and speed")
    .onChange(of: stops.count) { _, count in
      selection = min(selection, max(0, count - 1))
    }
  }

  /// The model rows and All models…, which share one enabled state.
  private func modelRows(_ stops: SHModelSettingsStops) -> some View {
    Group {
      ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
        SHMenuRow(
          highlighted: selection == index, action: { if modelEnabled { chooseModel(model) } },
          onHover: { selection = index }
        ) {
          Text(model.title).font(.shMono(12)).foregroundStyle(Color.sh.textPrimary)
            .lineLimit(1).truncationMode(.middle)
          Spacer(minLength: SH.Space.m)
          if model.fast { SHFastBolt() }
          if model.isCurrent {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Color.sh.running)
          }
        }
        .id(index)
        .accessibilityLabel(
          model.title + (model.isCurrent ? ", current" : "") + (model.fast ? ", offers Fast" : ""))
      }
      SHMenuRow(
        highlighted: selection == models.count, action: { if modelEnabled { allModels() } },
        onHover: { selection = models.count }
      ) {
        Text("All models…").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.sh.textTertiary)
      }
      .id(models.count)
    }
    .shEnabledOpacity(modelEnabled)
  }

  /// Which of `count` segments starting at `first` ↑↓ or the pointer is on, if any.
  private func highlighted(_ first: SHModelSettingsStops.Stop, in stops: SHModelSettingsStops, count: Int) -> Int? {
    let index = selection - stops.index(of: first)
    return (0..<count).contains(index) ? index : nil
  }

  private func chooseSelection() {
    switch stops.stop(at: selection) {
    case .model(let index): if modelEnabled { chooseModel(models[index]) }
    case .allModels: if modelEnabled { allModels() }
    case .thinking(let index): if thinkingEnabled { chooseThinking(thinking[index].id) }
    case .speed(let index): if speedEnabled { chooseSpeed(speeds[index].id) }
    case nil: break
    }
  }
}

/// One choice of a segmented row: a level or a speed.
struct SHModelSettingsSegment: Equatable {
  var id: String
  var title: String
  /// What it means, a tooltip ("quick", "Faster responses, billed at a higher rate").
  var note: String?
  /// It wears the Fast bolt.
  var bolt = false
}

/// A segmented control in the popover: a `bgSunken` track of equal segments, the chosen one lifted
/// on `bgSelected`. Up to four segments share one row; more (a model with all seven thinking
/// levels) wrap onto balanced rows of the same track, so no title is cut.
///
/// A segment is not a `Button`, as no menu row is: the popover keeps the keyboard, and the whole
/// segment answers a click (the content shape), not just its words. A `Button` with a clear
/// background answered only over its label: 39×16pt of a 147×24pt Fast segment.
struct SHModelSettingsSegments: View {
  let label: String
  let segments: [SHModelSettingsSegment]
  let current: String?
  /// The segment ↑↓ or the pointer is on.
  let highlighted: Int?
  let enabled: Bool
  /// Where this control's first segment is among the popover's stops, for scrolling it into view.
  let start: Int
  let hover: (Int) -> Void
  let choose: (String) -> Void

  /// Segments per row at most.
  static let perRow = 4

  /// The ranges of `count` segments that share a row: one row up to four, then balanced rows
  /// (5 → 3 + 2, 6 → 3 + 3, 7 → 4 + 3).
  static func rows(of count: Int) -> [Range<Int>] {
    guard count > 0 else { return [] }
    let rows = (count + perRow - 1) / perRow
    let size = (count + rows - 1) / rows
    return stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
  }

  var body: some View {
    VStack(spacing: SH.Space.xxs) {
      ForEach(Self.rows(of: segments.count), id: \.lowerBound) { range in
        HStack(spacing: SH.Space.xxs) {
          ForEach(range, id: \.self) { index in segment(index) }
        }
      }
    }
    .padding(SH.Space.xxs)
    .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.s))
    .shBorder(Color.sh.lineSubtle, radius: SH.Radius.s)
    .shEnabledOpacity(enabled)
    .padding(.horizontal, SH.Space.m).padding(.bottom, SH.Space.s)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }

  private func segment(_ index: Int) -> some View {
    let option = segments[index]
    let selected = option.id == current
    let lit = highlighted == index
    return HStack(spacing: SH.Space.xs) {
      if option.bolt { SHFastBolt() }
      Text(option.title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
    .font(.shSans(12, selected ? .semibold : .medium))
    .foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary)
    .frame(maxWidth: .infinity).frame(height: SH.Height.controlS)
    .background(
      selected ? Color.sh.bgSelected : lit ? Color.sh.runningTint : .clear,
      in: RoundedRectangle(cornerRadius: SH.Radius.xs)
    )
    .shBorder(
      lit && selected ? Color.sh.running : selected ? Color.sh.lineStrong : .clear,
      radius: SH.Radius.xs
    )
    .contentShape(Rectangle())
    .onTapGesture { if enabled { choose(option.id) } }
    .onHover { if $0 { hover(index) } }
    .id(start + index)
    .help(option.note ?? "")
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { if enabled { choose(option.id) } }
  }
}

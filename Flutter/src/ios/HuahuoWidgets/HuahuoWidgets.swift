import Foundation
import SwiftUI
import WidgetKit

private let huahuoWidgetAppGroup = "group.com.hangzhouchuda.huahuoai.capture"

private enum HuahuoWidgetPalette {
  static func surface(for scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 0.09, green: 0.10, blue: 0.12)
      : Color(red: 0.98, green: 0.99, blue: 1.00)
  }

  static func primaryText(for scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 0.97, green: 0.98, blue: 0.99)
      : Color(red: 0.06, green: 0.08, blue: 0.12)
  }

  static func secondaryText(for scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 0.73, green: 0.76, blue: 0.81)
      : Color(red: 0.34, green: 0.39, blue: 0.47)
  }

  static func brand(for scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 0.35, green: 0.82, blue: 0.70)
      : Color(red: 0.03, green: 0.42, blue: 0.34)
  }

  static func secondaryAction(for scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 0.17, green: 0.19, blue: 0.23)
      : Color(red: 0.89, green: 0.92, blue: 0.94)
  }

  static func connected(for scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 0.42, green: 0.91, blue: 0.58)
      : Color(red: 0.03, green: 0.44, blue: 0.25)
  }
}

private struct HuahuoWidgetSnapshot {
  let authenticated: Bool
  let personalContentCount: Int
  let depositedContentCount: Int
  let level: Int
  let pointsInLevel: Int
  let recordingConnected: Bool
  let recordingState: String
  let recordingElapsedSeconds: Int
  let updatedAt: Date
  let recordingBatteryPercent: Int?
  var levelSpan: Int? = nil
  var recordingActionToken: String? = nil

  var growthLabel: String {
    guard let span = levelSpan else { return "成长数据待更新" }
    return span == 0 && level == 10 ? "已达最高等级" : "本级 \(pointsInLevel)/\(span)"
  }

  static func current(at date: Date = Date()) -> HuahuoWidgetSnapshot {
    guard let defaults = UserDefaults(suiteName: huahuoWidgetAppGroup),
      defaults.bool(forKey: "homeWidget.authenticated")
    else {
      return HuahuoWidgetSnapshot(
        authenticated: false,
        personalContentCount: 0,
        depositedContentCount: 0,
        level: 1,
        pointsInLevel: 0,
        recordingConnected: false,
        recordingState: "disconnected",
        recordingElapsedSeconds: 0,
        updatedAt: Date(),
        recordingBatteryPercent: nil
      )
    }
    let storedState = defaults.string(forKey: "homeWidget.recordingState") ?? "disconnected"
    let updatedAt = Date(timeIntervalSince1970:
      defaults.double(forKey: "homeWidget.updatedAtEpochMs") / 1000)
    let age = date.timeIntervalSince(updatedAt)
    let knownState = ["disconnected", "idle", "recording", "paused"].contains(storedState)
    let fresh = age >= 0 && age < 1800
    let recordingState = !knownState || (storedState != "disconnected" && !fresh)
      ? "stale" : storedState
    let connected = ["idle", "recording", "paused"].contains(recordingState)
    let battery = connected && defaults.object(forKey: "homeWidget.recordingBattery") != nil
      ? min(max(defaults.integer(forKey: "homeWidget.recordingBattery"), 0), 100)
      : nil
    let span = (defaults.object(forKey: "homeWidget.levelSpan") as? NSNumber)?.intValue
    let token = defaults.string(forKey: "homeWidget.recordingActionToken")
    return HuahuoWidgetSnapshot(
      authenticated: true,
      personalContentCount: min(max(defaults.integer(forKey: "homeWidget.personalContent"), 0), 1_000_000),
      depositedContentCount: min(max(defaults.integer(forKey: "homeWidget.depositedContent"), 0), 1_000_000),
      level: min(max(defaults.integer(forKey: "homeWidget.level"), 1), 10),
      pointsInLevel: min(max(defaults.integer(forKey: "homeWidget.pointsInLevel"), 0), max(span ?? 0, 0)),
      recordingConnected: connected,
      recordingState: recordingState,
      recordingElapsedSeconds: min(
        max(defaults.integer(forKey: "homeWidget.recordingElapsed"), 0),
        86_400_000
      ),
      updatedAt: updatedAt,
      recordingBatteryPercent: battery,
      levelSpan: span.flatMap { (0...1_000_000).contains($0) ? $0 : nil },
      recordingActionToken: connected && token?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil ? token : nil
    )
  }
}

private struct HuahuoWidgetEntry: TimelineEntry {
  let date: Date
  let snapshot: HuahuoWidgetSnapshot
}

private struct HuahuoWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> HuahuoWidgetEntry {
    HuahuoWidgetEntry(
      date: Date(),
      snapshot: HuahuoWidgetSnapshot(
        authenticated: true,
        personalContentCount: 24,
        depositedContentCount: 12,
        level: 3,
        pointsInLevel: 4,
        recordingConnected: true,
        recordingState: "recording",
        recordingElapsedSeconds: 83,
        updatedAt: Date(),
        recordingBatteryPercent: 72,
        levelSpan: 5
      )
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (HuahuoWidgetEntry) -> Void) {
    completion(
      context.isPreview
        ? placeholder(in: context)
        : HuahuoWidgetEntry(date: Date(), snapshot: .current())
    )
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<HuahuoWidgetEntry>) -> Void) {
    let now = Date()
    let snapshot = HuahuoWidgetSnapshot.current(at: now)
    var entries = [HuahuoWidgetEntry(date: now, snapshot: snapshot)]
    if snapshot.recordingConnected {
      let expiry = snapshot.updatedAt.addingTimeInterval(1800)
      entries.append(HuahuoWidgetEntry(date: expiry, snapshot: .current(at: expiry)))
    }
    completion(Timeline(entries: entries, policy: .never))
  }
}

private struct HuahuoQuickCreationView: View {
  let entry: HuahuoWidgetEntry
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HuahuoWidgetHeader(symbol: "sparkles", title: "快速开始")
      Text("捕捉想法，继续创作")
        .font(.caption)
        .foregroundColor(HuahuoWidgetPalette.secondaryText(for: colorScheme))
        .lineLimit(2)
      Spacer(minLength: 4)
      Link(destination: HuahuoWidgetRoute.freeCreation.url) {
        HuahuoWidgetAction(label: "自由创作", primary: true)
      }
      Link(destination: HuahuoWidgetRoute.newNote.url) {
        HuahuoWidgetAction(label: "记笔记", primary: false)
      }
    }
    .foregroundColor(HuahuoWidgetPalette.primaryText(for: colorScheme))
    .padding(14)
    .huahuoWidgetSurface(colorScheme: colorScheme)
    .widgetURL(HuahuoWidgetRoute.feed.url)
  }
}

private struct HuahuoRecordingCardView: View {
  let entry: HuahuoWidgetEntry
  @Environment(\.widgetFamily) private var family
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if family == .systemSmall {
        VStack(alignment: .leading, spacing: 6) {
          HuahuoWidgetHeader(symbol: "waveform", title: "录音卡")
          Text(compactSummary)
            .font(.caption.weight(.semibold))
            .foregroundColor(
              entry.snapshot.recordingConnected
                ? HuahuoWidgetPalette.connected(for: colorScheme)
                : HuahuoWidgetPalette.primaryText(for: colorScheme)
            )
            .lineLimit(2)
          if entry.snapshot.recordingConnected {
            recordingDuration
          }
          Spacer(minLength: 0)
          HuahuoWidgetAction(label: actionLabel, primary: true)
        }
      } else {
        VStack(alignment: .leading, spacing: 9) {
          HuahuoWidgetHeader(symbol: "waveform", title: "录音卡")
          if !entry.snapshot.authenticated {
            Text("登录后查看设备状态")
              .font(.subheadline.weight(.semibold))
            Text("状态只保存在本机")
              .font(.caption)
              .foregroundColor(HuahuoWidgetPalette.secondaryText(for: colorScheme))
          } else if entry.snapshot.recordingConnected {
            Label("上次同步 · \(statusLabel)", systemImage: "checkmark.circle.fill")
              .font(.subheadline.weight(.semibold))
              .foregroundColor(HuahuoWidgetPalette.connected(for: colorScheme))
            Label(
              entry.snapshot.recordingBatteryPercent.map { "\($0)%" } ?? "--",
              systemImage: "battery.75"
            )
            .font(.caption)
            .foregroundColor(HuahuoWidgetPalette.secondaryText(for: colorScheme))
          } else {
            Text(entry.snapshot.recordingState == "stale" ? "状态待刷新" : "未连接")
              .font(.subheadline.weight(.semibold))
            Text("打开 App 连接录音卡")
              .font(.caption)
              .foregroundColor(HuahuoWidgetPalette.secondaryText(for: colorScheme))
          }
          Spacer(minLength: 4)
          HuahuoWidgetAction(label: actionLabel, primary: true)
        }
      }
    }
    .foregroundColor(HuahuoWidgetPalette.primaryText(for: colorScheme))
    .padding(14)
    .huahuoWidgetSurface(colorScheme: colorScheme)
    .widgetURL(HuahuoWidgetRoute.recordingControl(
      action: action, revision: Int64(entry.snapshot.updatedAt.timeIntervalSince1970 * 1000),
      token: entry.snapshot.recordingActionToken
    ).url)
  }

  private var compactSummary: String {
    if !entry.snapshot.authenticated { return "登录后查看设备状态" }
    if entry.snapshot.recordingConnected {
      let battery = entry.snapshot.recordingBatteryPercent.map { "\($0)%" } ?? "--"
      return "上次同步 · \(statusLabel) · 电量 \(battery)"
    }
    if entry.snapshot.recordingState == "stale" { return "状态待刷新 · 打开 App 确认" }
    return "未连接 · 打开 App 连接录音卡"
  }

  @ViewBuilder
  private var recordingDuration: some View {
    if entry.snapshot.recordingState == "recording" {
      Text(timerStart, style: .timer)
        .font(.title3.monospacedDigit().weight(.semibold))
    } else {
      Text(formatDuration(entry.snapshot.recordingElapsedSeconds))
        .font(.title3.monospacedDigit().weight(.semibold))
    }
  }

  private var timerStart: Date {
    entry.snapshot.updatedAt.addingTimeInterval(
      -Double(entry.snapshot.recordingElapsedSeconds)
    )
  }

  private var statusLabel: String {
    switch entry.snapshot.recordingState {
    case "recording": return "录音中"
    case "paused": return "已暂停"
    default: return "待机"
    }
  }

  private var action: String {
    if entry.snapshot.recordingConnected && entry.snapshot.recordingActionToken == nil { return "refresh" }
    return actionForState
  }

  private var actionForState: String {
    switch entry.snapshot.recordingState {
    case "idle": return "start"
    case "recording": return "pause"
    case "paused": return "resume"
    case "stale": return "refresh"
    default: return "connect"
    }
  }

  private var actionLabel: String {
    switch action {
    case "start": return "开始"
    case "pause": return "暂停"
    case "resume": return "继续"
    case "refresh": return "刷新状态"
    default: return "连接录音卡"
    }
  }
}

private struct HuahuoAssetsView: View {
  let entry: HuahuoWidgetEntry
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HuahuoWidgetHeader(symbol: "chart.bar.fill", title: "成长与资产")
      if entry.snapshot.authenticated {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("Lv.\(entry.snapshot.level)")
            .font(.title2.weight(.bold))
          Text(entry.snapshot.growthLabel)
            .font(.caption)
            .foregroundColor(HuahuoWidgetPalette.secondaryText(for: colorScheme))
        }
        if let span = entry.snapshot.levelSpan {
          ProgressView(value: span == 0 ? 1 : Double(entry.snapshot.pointsInLevel), total: Double(max(span, 1)))
            .accentColor(HuahuoWidgetPalette.brand(for: colorScheme))
        }
        Text("我的创建 \(entry.snapshot.personalContentCount) · 已沉淀 \(entry.snapshot.depositedContentCount)")
          .font(.caption)
          .foregroundColor(HuahuoWidgetPalette.secondaryText(for: colorScheme))
          .lineLimit(1)
      } else {
        Text("登录后查看成长进度")
          .font(.headline)
        Text("资产统计仅在本机显示")
          .font(.caption)
          .foregroundColor(HuahuoWidgetPalette.secondaryText(for: colorScheme))
      }
      Spacer(minLength: 2)
      HStack(spacing: 8) {
        Link(destination: HuahuoWidgetRoute.assets.url) {
          HuahuoWidgetAction(label: "我的资产", primary: true)
        }
        Link(destination: HuahuoWidgetRoute.workbench.url) {
          HuahuoWidgetAction(label: "创作台", primary: false)
        }
      }
    }
    .foregroundColor(HuahuoWidgetPalette.primaryText(for: colorScheme))
    .padding(14)
    .huahuoWidgetSurface(colorScheme: colorScheme)
    .widgetURL(HuahuoWidgetRoute.feed.url)
  }
}

private struct HuahuoWidgetHeader: View {
  let symbol: String
  let title: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .foregroundColor(HuahuoWidgetPalette.brand(for: colorScheme))
      Text(title)
        .font(.headline)
        .foregroundColor(HuahuoWidgetPalette.primaryText(for: colorScheme))
        .lineLimit(1)
    }
  }
}

private struct HuahuoWidgetAction: View {
  let label: String
  let primary: Bool
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Text(label)
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .frame(maxWidth: .infinity, minHeight: 34)
      .foregroundColor(
        primary ? .white : HuahuoWidgetPalette.primaryText(for: colorScheme)
      )
      .background(
        primary
          ? HuahuoWidgetPalette.brand(for: colorScheme)
          : HuahuoWidgetPalette.secondaryAction(for: colorScheme)
      )
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
  }
}

private enum HuahuoWidgetRoute: String {
  case feed = "/v3/feed"
  case freeCreation = "/v3/workbench/canvas"
  case newNote = "/v3/feed/note"
  case recordingCard = "/v3/recording-card"
  case assets = "/v3/profile/assets"
  case workbench = "/v3/workbench"

  var url: URL { URL(string: "huahuoai://\(rawValue)")! }

  static func recordingControl(action: String, revision: Int64, token: String?) -> HuahuoWidgetDestination {
    HuahuoWidgetDestination(
      url: URL(
        string: "huahuoai:///v3/recording-card/control?widgetAction=\(action)&widgetRevision=\(revision)&widgetToken=\(token ?? "")"
      )!
    )
  }
}

private struct HuahuoWidgetDestination {
  let url: URL
}

private func formatDuration(_ seconds: Int) -> String {
  let bounded = max(0, seconds)
  let hours = bounded / 3600
  let minutes = (bounded % 3600) / 60
  let remainder = bounded % 60
  return hours > 0
    ? String(format: "%02d:%02d:%02d", hours, minutes, remainder)
    : String(format: "%02d:%02d", minutes, remainder)
}

private extension View {
  @ViewBuilder
  func huahuoWidgetSurface(colorScheme: ColorScheme) -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      containerBackground(HuahuoWidgetPalette.surface(for: colorScheme), for: .widget)
    } else {
      background(HuahuoWidgetPalette.surface(for: colorScheme))
    }
  }
}

struct HuahuoQuickCreationWidget: Widget {
  let kind = "HuahuoQuickCreationWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: HuahuoWidgetProvider()) { entry in
      HuahuoQuickCreationView(entry: entry)
    }
    .configurationDisplayName("快速创作")
    .description("快速打开自由创作或新建笔记。")
    .supportedFamilies([.systemMedium])
  }
}

struct HuahuoRecordingCardWidget: Widget {
  let kind = "HuahuoRecordingCardWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: HuahuoWidgetProvider()) { entry in
      HuahuoRecordingCardView(entry: entry)
    }
    .configurationDisplayName("录音卡状态")
    .description("查看录音卡连接和电量状态。")
    .supportedFamilies([.systemSmall])
  }
}

struct HuahuoAssetsWidget: Widget {
  let kind = "HuahuoAssetsWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: HuahuoWidgetProvider()) { entry in
      HuahuoAssetsView(entry: entry)
    }
    .configurationDisplayName("成长与资产")
    .description("查看等级进度和资产数量。")
    .supportedFamilies([.systemMedium])
  }
}

@main
struct HuahuoWidgetBundle: WidgetBundle {
  var body: some Widget {
    HuahuoQuickCreationWidget()
    HuahuoRecordingCardWidget()
    HuahuoAssetsWidget()
  }
}

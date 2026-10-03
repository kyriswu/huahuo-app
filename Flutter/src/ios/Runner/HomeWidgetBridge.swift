import Flutter
import Foundation
import WidgetKit

final class HomeWidgetBridge {
  private static let channelName = "huahuoai/home_widgets"
  private static let appGroup = "group.com.hangzhouchuda.huahuoai.capture"
  private static let allowedKeys: Set<String> = [
    "schemaVersion",
    "isAuthenticated",
    "personalContentCount",
    "depositedContentCount",
    "level",
    "pointsInLevel",
    "levelSpan",
    "recordingActionToken",
    "recordingState",
    "recordingCardBatteryPercent",
    "recordingElapsedSeconds",
    "updatedAtEpochMs",
  ]

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "updateSnapshot" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let snapshot = parseSnapshot(call.arguments),
        let defaults = UserDefaults(suiteName: appGroup)
      else {
        result(
          FlutterError(
            code: "HOME_WIDGET_SNAPSHOT_INVALID",
            message: "Home widget snapshot is invalid.",
            details: nil
          )
        )
        return
      }

      defaults.set(snapshot.isAuthenticated, forKey: "homeWidget.authenticated")
      defaults.set(snapshot.personalContentCount, forKey: "homeWidget.personalContent")
      defaults.set(snapshot.depositedContentCount, forKey: "homeWidget.depositedContent")
      defaults.set(snapshot.level, forKey: "homeWidget.level")
      defaults.set(snapshot.pointsInLevel, forKey: "homeWidget.pointsInLevel")
      defaults.set(snapshot.levelSpan, forKey: "homeWidget.levelSpan")
      defaults.set(snapshot.recordingActionToken, forKey: "homeWidget.recordingActionToken")
      defaults.set(snapshot.recordingState, forKey: "homeWidget.recordingState")
      defaults.set(snapshot.recordingElapsedSeconds, forKey: "homeWidget.recordingElapsed")
      defaults.set(snapshot.updatedAtEpochMs, forKey: "homeWidget.updatedAtEpochMs")
      if let battery = snapshot.recordingCardBatteryPercent {
        defaults.set(battery, forKey: "homeWidget.recordingBattery")
      } else {
        defaults.removeObject(forKey: "homeWidget.recordingBattery")
      }
      if #available(iOS 14.0, *) {
        WidgetCenter.shared.reloadAllTimelines()
      }
      result(true)
    }
  }

  private static func parseSnapshot(_ raw: Any?) -> SafeHomeWidgetSnapshot? {
    guard let values = raw as? [String: Any],
      Set(values.keys).isSubset(of: allowedKeys),
      let version = integer(values["schemaVersion"]),
      [2, 3].contains(version),
      let isAuthenticated = values["isAuthenticated"] as? Bool,
      let personalContentCount = integer(values["personalContentCount"]),
      let depositedContentCount = integer(values["depositedContentCount"]),
      let level = integer(values["level"]),
      let pointsInLevel = integer(values["pointsInLevel"]),
      let recordingState = values["recordingState"] as? String,
      let recordingElapsedSeconds = integer(values["recordingElapsedSeconds"]),
      let updatedAtEpochMs = integer64(values["updatedAtEpochMs"]),
      (0...1_000_000).contains(personalContentCount),
      (0...1_000_000).contains(depositedContentCount),
      (1...10).contains(level),
      (0...1_000_000).contains(pointsInLevel),
      ["disconnected", "idle", "recording", "paused"].contains(recordingState),
      (0...86_400_000).contains(recordingElapsedSeconds),
      updatedAtEpochMs > 0
    else {
      return nil
    }
    let levelSpan = version == 3 ? integer(values["levelSpan"]) : nil
    if version == 3 {
      guard let span = levelSpan,
        (level == 10 ? span == 0 : (1...1_000_000).contains(span)),
        pointsInLevel <= span, isAuthenticated || span == 1
      else { return nil }
    } else if pointsInLevel > 100 { return nil }
    let token = version == 3 ? values["recordingActionToken"] as? String : nil
    if version == 3, values.keys.contains("recordingActionToken") {
      guard let token = token, isAuthenticated, recordingState != "disconnected",
        token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
      else { return nil }
    }
    let battery: Int?
    if values.keys.contains("recordingCardBatteryPercent") {
      guard let parsed = integer(values["recordingCardBatteryPercent"]),
        (0...100).contains(parsed),
        recordingState != "disconnected"
      else {
        return nil
      }
      battery = parsed
    } else {
      battery = nil
    }
    if !isAuthenticated,
      personalContentCount != 0 || depositedContentCount != 0 || level != 1
        || pointsInLevel != 0 || recordingState != "disconnected" || battery != nil
    {
      return nil
    }
    if recordingState == "disconnected",
      battery != nil || recordingElapsedSeconds != 0
    {
      return nil
    }
    return SafeHomeWidgetSnapshot(
      isAuthenticated: isAuthenticated,
      personalContentCount: personalContentCount,
      depositedContentCount: depositedContentCount,
      level: level,
      pointsInLevel: pointsInLevel,
      levelSpan: levelSpan,
      recordingActionToken: token,
      recordingState: recordingState,
      recordingElapsedSeconds: recordingElapsedSeconds,
      recordingCardBatteryPercent: battery,
      updatedAtEpochMs: updatedAtEpochMs
    )
  }

  private static func integer(_ raw: Any?) -> Int? {
    guard let number = raw as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let value = number.int64Value
    guard NSNumber(value: value) == number, value >= Int64(Int.min), value <= Int64(Int.max)
    else {
      return nil
    }
    return Int(value)
  }

  private static func integer64(_ raw: Any?) -> Int64? {
    guard let number = raw as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let value = number.int64Value
    return NSNumber(value: value) == number ? value : nil
  }
}

private struct SafeHomeWidgetSnapshot {
  let isAuthenticated: Bool
  let personalContentCount: Int
  let depositedContentCount: Int
  let level: Int
  let pointsInLevel: Int
  let levelSpan: Int?
  let recordingActionToken: String?
  let recordingState: String
  let recordingElapsedSeconds: Int
  let recordingCardBatteryPercent: Int?
  let updatedAtEpochMs: Int64
}

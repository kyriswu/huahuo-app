# Simulator 真实蓝牙调试

状态：`implementation-partial`。真实扫描已验证；连接、协议握手、录音、文件传输及 iPhone 实机回归尚未验收。

## 边界与共用代码

```text
Flutter 页面 / controller
        ↓ 同一个 MethodChannel
RecordingCardBridge（唯一的 FW920 协议、鉴权、文件校验实现）
        ↓ 编译时选择
Debug Simulator → GATT 适配器 → 本机 TCP → Mac CoreBluetooth → 录音卡
iPhone / Profile / Release → 原有 CoreBluetooth → 录音卡
```

Mac 工具只负责通用 GATT，不解析录音卡协议、不调用云端、不存储音频。iPhone 的类型别名直接指向系统类，没有运行时代理开关。Android 不受影响。Simulator 本身仍没有蓝牙硬件支持，真实无线通信发生在 Mac。

## 启动

在 Flutter 移动端目录 `Flutter/src` 执行，需要已安装的 Xcode、FVM、Python 3、rbenv 与项目 Bundler 依赖，不新增 Python 依赖。使用现有已启动模拟器：

```sh
xcrun simctl list devices booted
python3 tool/ble_proxy/run.py --device <模拟器UUID> --build
```

`--build` 使用明确的 `lib/main.dart` 正式入口及 HTTPS API，先由 Flutter config-only 生成输入，再由 xcodebuild 针对指定模拟器增量编译 Debug。这样避免本机 Xcode 通用 Simulator 目标曾出现的退出码 255。后续源码未变化时可以省略；启动器检查产物中的入口标记，拒绝测试包或未标记旧包，并要求重新 `--build`。

保持终端运行；Ctrl-C 关闭 Mac 服务。服务断开后 App 会报告代理不可用，不自动重放指令；重新执行启动命令开启新会话。首次使用时允许 Mac 工具的蓝牙权限；若拒绝，可到系统设置的隐私与安全性 → 蓝牙中启用。录音卡须开机、靠近 Mac，并断开与其他手机的连接。App 仍走正常登录、SN 校验和账户绑定流程，不绕过鉴权。

## 测试

```sh
python3 tool/ble_proxy/run.py --self-test
python3 tool/ble_proxy/run.py --probe
python3 tool/ble_proxy/run.py --device <模拟器UUID> --integration-test
```

后两条仅扫描，不连接、写入、录音或删除设备文件。集成测试调用真实 Flutter MethodChannel 和共享原生驱动；附近必须存在可被驱动识别的广播。候选设备数不等于已经确认归属或可连接的设备数。测试后执行日常启动命令并带 `--build` 恢复正式 App。

## 正式包与测试包隔离

- 测试启动器只向测试子进程传 `HUAHUO_ALLOW_NON_FORMAL_FLUTTER_TARGET=1`，不修改 shell 配置。
- Runner Scheme 在普通构建时恢复 `lib/main.dart`，并保持 Debug/Profile/Release 模式；发布模式和归档忽略测试开关。
- Runner 的 Flutter build phase 独立执行 `tool/ios_entrypoint_guard.sh`，即使绕过 Scheme，也拒绝 Release/Profile/Archive 中的非正式入口或已知测试/demo define。
- `HuahuoFlutterEntrypoint` 写入每个 App 的 Info.plist。日常启动器检查已构建产物，不凭可能过期的 Generated.xcconfig 判断。
- 代理 Swift 网络代码只编入 Debug Simulator；Mac host 不属于 Runner target。`BLE_PROXY_TESTING` 仅用于 Mac 原生单测，不得添加到 Runner 编译条件。

正式构建示例（签名发布仍需公司 Team 权限）：

```sh
rbenv exec bundle exec fvm flutter build ipa --release --target=lib/main.dart --dart-define=HUAHUO_API_BASE_URL=https://chuda.cc
```

无签名的 `flutter build ios --release --no-codesign` 只能验证编译和产物，不能证明安装、真机权限或 App Store 发布成功。

## 协议与故障处理

IPv4 `127.0.0.1` 上使用动态端口、每次启动随机 token、单客户端、版本 1 的长度前缀 JSON。token 文件权限为 0600，结束后清理；不记录 token、设备标识或 GATT/音频内容。每帧最多 1 MiB，待发数据最多 4 MiB；错误帧、认证失败、序号重复、队列溢出和心跳超时均关闭会话。

无响应写入一次只允许一个在途请求，主机分发确认才解除背压。传输失败不丢字节后假装成功，也不重试录音或删除指令。服务关闭时取消扫描和连接，旧会话回调不归属新会话。Mac 工具的 ad-hoc 签名是正常工具构建，不修改或补签 iOS App。

## 必须用 iPhone 验收的范围

- 蓝牙授权、锁屏/后台恢复、系统杀进程后的行为。
- 实际连接、SN/鉴权、录音控制、BLE 文件下载/校验/入库及异常恢复。
- Wi-Fi 热点切换、局域网权限、真实吞吐和无线时序。模拟器代理会在发出热点开启命令前返回 `RECORDING_CARD_SIMULATOR_WIFI_UNSUPPORTED`。
- Mac 与 iPhone 的 CoreBluetooth peripheral UUID 不相同；不能用模拟器缓存指纹证明手机设备身份，仍以原有 SN/云端校验为准。

这条代理用于长期复用 App 业务/协议回归，不能替代上述真实平台验收。

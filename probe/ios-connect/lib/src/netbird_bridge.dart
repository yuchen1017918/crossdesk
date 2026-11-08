// netbird_bridge.dart —— flutter_netbird 的**唯一**接触面
//
// ⚠️ 本文件是整套 Dart 探针里唯一需要按 flutter_netbird 实际签名校对的地方
//    （约 40 行，全部用 ADAPT(n) 标出）。原因：交付本探针的机器上没有
//    dart/flutter，且 pub.dev 不可达，无法拉到 1.0.5 的源码核对签名。
//    因此这里**不声称可编译**，只给出契约形状。
//
// 契约（来自 plan-v3 §1 + 任务书）：
//   1. initialize(NetbirdConfig)  —— 注入 management/relay/setup key
//   2. up(NetbirdAuth)            —— 加入 overlay（iOS userspace，无 packet tunnel）
//   3. startProxy()               —— 起本地 HTTP 代理，返回本地端口
//   4. NetbirdHttpOverrides(port) —— 让 dart:io HttpClient 走该代理（CONNECT）
//
// 关键认知（决定验收口径）：iOS 上 netbird 是 **userspace**，不接管系统路由，
// 所以 100.x 对 Socket.connect 不可达；只有打了 overrides 的 dart:io 请求能出去。
// 这也是为什么 B1 必须"经 CONNECT 隧道"而不是直连 100.x。

import 'package:flutter_netbird/flutter_netbird.dart';

/// 探针需要从 netbird 拿到的只有两样：本地代理端口、以及连接态。
class NetbirdBridge {
  NetbirdBridge._();

  static int? proxyPort;

  /// 启动 netbird 并起本地代理，返回代理端口。
  ///
  /// [managementUrl] / [setupKey] / [psk] 来自配对材料（见 runbook §3）。
  static Future<int> bootstrap({
    required String managementUrl,
    required String setupKey,
    required String psk,
    String? relayUrl,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // ── ADAPT(1) ─────────────────────────────────────────────────────────
    // NetbirdConfig 的字段名以 flutter_netbird 实际版本为准；下面按"至少需要
    // management 地址 + setup key"建模。若字段名不同，只改这一处。
    final config = NetbirdConfig(
      managementUrl: managementUrl,
      setupKey: setupKey,
      relayUrl: relayUrl,
    );
    await FlutterNetbird.initialize(config);
    // ─────────────────────────────────────────────────────────────────────

    // ── ADAPT(2) ─────────────────────────────────────────────────────────
    // up() 的参数形态（psk？setupKey？deviceName？）需按版本核对。
    await FlutterNetbird.up(NetbirdAuth(psk: psk));
    // ─────────────────────────────────────────────────────────────────────

    // 等 overlay 起来（后台存活观测也复用这个轮询函数）
    final deadline = DateTime.now().add(timeout);
    var status = await FlutterNetbird.getFullStatus();
    while (!_isConnected(status) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      status = await FlutterNetbird.getFullStatus();
    }
    if (!_isConnected(status)) {
      throw StateError('netbird 未进入连接态：$status');
    }

    // ── ADAPT(3) ─────────────────────────────────────────────────────────
    // startProxy() 的返回值（int? / 对象?）需核对；这里假定返回本地端口。
    final proxy = await FlutterNetbird.startProxy();
    proxyPort = proxy is int ? proxy : int.parse('$proxy');
    // ─────────────────────────────────────────────────────────────────────
    return proxyPort!;
  }

  /// 交给 `HttpOverrides.global`，让 dart:io 的 HttpClient 走 CONNECT。
  ///
  /// ⚠️ 只影响 dart:io 的 HttpClient（以及内部用它的 WebSocket.connect）。
  /// 本探针的裸 WS 路径用的是自己的 Socket + 手工 CONNECT，所以**不依赖**它；
  /// 两者都测，才能区分"隧道不行"和"overrides 没接上"。
  static HttpOverrides httpOverrides(int port) => NetbirdHttpOverrides(port);

  /// 轮询连接态（B4 后台存活用）。
  static Future<Map<String, dynamic>> status() async {
    final s = await FlutterNetbird.getFullStatus();
    return <String, dynamic>{
      'raw': '$s',
      'connected': _isConnected(s),
    };
  }

  static Future<void> down() async {
    // ── ADAPT(4) ─────────────────────────────────────────────────────────
    await FlutterNetbird.down();
    // ─────────────────────────────────────────────────────────────────────
    proxyPort = null;
  }

  static bool _isConnected(Object? status) {
    // netbird 的状态是 JSON 字符串或结构体，字段名以版本为准。
    final text = '$status'.toLowerCase();
    return text.contains('"status":"connected"') ||
        text.contains('connected=true') ||
        text.contains('"connected":true');
  }
}

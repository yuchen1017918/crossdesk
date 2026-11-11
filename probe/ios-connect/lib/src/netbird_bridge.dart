// netbird_bridge.dart —— flutter_netbird 1.0.5 的**唯一**接触面
//
// 本文件已按 flutter_netbird **1.0.5 真实源码**对齐（2026-11-11，源码取自
// GitHub Actions 的 pub-cache，见 .github/workflows/ios-dart.yml 的 API dump 步骤）。
//
// 真实 API（flutter_netbird.dart）：
//   class NetbirdSDK                     —— factory 单例，`NetbirdSDK()` 直接拿
//   int  initialize(NetbirdConfig)       —— **同步**，返回 rc（0 = 成功）
//   Future<int> upAsync({NetbirdAuth?})  —— 异步版 up（iOS 上要用这个）
//   Future<int> downAsync()
//   Future<NetbirdFullStatus> getFullStatusAsync()
//   Future<int> startProxy()             —— 只起代理，返回 rc
//   Future<int> getProxyPort()           —— **端口要单独取**（startProxy 不返回端口）
//   bool get isInitialized
//
// NetbirdConfig({deviceName, managementURL, configPath, statePath, logLevel, setupKey, ...})
// NetbirdAuth({setupKey, jwtToken, privateKey})   ← **没有 psk 字段**
//
// 关键认知（决定验收口径）：iOS 上 netbird 是 **userspace**，不接管系统路由，
// 所以 100.x 对 `Socket.connect` 不可达；只有经 `getProxyPort()` 拿到的本地
// CONNECT 端口才能出去。这也是 B1 必须"经 CONNECT 隧道"而不是直连 100.x 的原因。
//
// 注意：1.0.5 **没有** `NetbirdHttpOverrides` 这个类。本探针的裸 WS 路径用
// `wire.dart` 自己的 Socket + 手工 CONNECT，因此不依赖任何 HttpOverrides。
// 若将来要用 SDK 内置的 httpGet/httpPost（它们内部已走 proxy），那是另一条路。

import 'dart:async';

import 'package:flutter_netbird/flutter_netbird.dart';

/// 探针需要从 netbird 拿到的只有两样：本地代理端口、以及连接态。
class NetbirdBridge {
  NetbirdBridge._();

  /// `NetbirdSDK()` 是 factory 单例（源码里 `static final _instance = NetbirdSDK._internal()`）。
  static final NetbirdSDK _sdk = NetbirdSDK();

  static int? proxyPort;

  /// 初始化 → 加入 overlay → 起本地代理，返回代理端口。
  ///
  /// [configPath] / [statePath] 必须可写且持久：iOS 上没有它们每次都是新设备，
  /// overlay IP 会漂（Windows 侧已实测过这个坑，见 plan-v3 A6）。
  static Future<int> bootstrap({
    required String managementUrl,
    required String setupKey,
    required String configPath,
    required String statePath,
    String deviceName = 'crossdesk-ios-probe',
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final rc = _sdk.initialize(NetbirdConfig(
      deviceName: deviceName,
      managementURL: managementUrl, // 注意是大写 URL
      configPath: configPath,
      statePath: statePath,
      logLevel: 'info',
    ));
    if (rc != 0) {
      throw StateError('NetbirdSDK.initialize 返回 $rc（非 0 即失败）');
    }

    final upRc = await _sdk.upAsync(auth: NetbirdAuth(setupKey: setupKey));
    if (upRc != 0) {
      throw StateError('NetbirdSDK.upAsync 返回 $upRc（setup key / management URL 不对？）');
    }

    // 等 overlay 进入连接态（B4 的后台存活观测复用同一函数）
    final deadline = DateTime.now().add(timeout);
    var st = await _sdk.getFullStatusAsync();
    while (!_isConnected(st) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      st = await _sdk.getFullStatusAsync();
    }
    if (!_isConnected(st)) {
      throw StateError('netbird ${timeout.inSeconds}s 内未进入连接态：${_describe(st)}');
    }

    final startRc = await _sdk.startProxy();
    if (startRc != 0) {
      throw StateError('NetbirdSDK.startProxy 返回 $startRc');
    }
    final port = await _sdk.getProxyPort();
    if (port <= 0) {
      throw StateError('NetbirdSDK.getProxyPort 返回 $port（代理没起来？）');
    }

    proxyPort = port;
    return port;
  }

  /// 轮询连接态（B4 后台存活用）。返回可直接进 JSON 报告的形状。
  static Future<Map<String, dynamic>> status() async {
    final s = await _sdk.getFullStatusAsync();
    Map<String, dynamic> raw;
    try {
      raw = s.toJson();
    } catch (_) {
      raw = <String, dynamic>{'unparsed': '$s'};
    }
    return <String, dynamic>{
      'connected': _isConnected(s),
      'raw': raw,
    };
  }

  static bool get isInitialized => _sdk.isInitialized;

  static Future<void> down() async {
    try {
      await _sdk.downAsync();
    } finally {
      proxyPort = null;
    }
  }

  /// 清掉 SDK 的全局状态（进程退出前调用，避免下一个用例拿到脏状态）。
  static void cleanup() => _sdk.cleanup();

  static bool _isConnected(NetbirdFullStatus s) {
    // 优先看结构体字段；字段名不确定时退回字符串匹配。
    // 注意 `contains('connected')` 会把 'disconnected' 也判真，所以必须精确比较。
    try {
      final j = s.toJson();
      for (final key in const ['status', 'state', 'connectionStatus', 'connected']) {
        if (!j.containsKey(key)) continue;
        final v = '${j[key]}'.toLowerCase();
        if (v == 'connected' || v == 'true') return true;
        if (v == 'disconnected' || v == 'false' || v == 'idle') return false;
      }
    } catch (_) {}
    final t = s.toString().toLowerCase();
    if (t.contains('disconnected')) return false;
    return t.contains('connected');
  }

  static String _describe(NetbirdFullStatus s) {
    try {
      return s.toJson().toString();
    } catch (_) {
      return '$s';
    }
  }
}

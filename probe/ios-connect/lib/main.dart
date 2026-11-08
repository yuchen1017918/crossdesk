// main.dart —— Flutter 宿主：起 netbird → 跑 B1..B4 → 显示/导出 JSON
//
// 这是"真机跑一趟"的第二条路（第一条见 integration_test/probe_test.dart）：
//   flutter run -d <device> \
//     --dart-define=PROBE_HOST=motifd-laptop \
//     --dart-define=PROBE_TOKEN=<bearer> \
//     --dart-define=NETBIRD_MGMT=https://api.netbird.io \
//     --dart-define=NETBIRD_SETUP_KEY=<setup key> \
//     --dart-define=MOTIF_PSK=<pair link 里的 psk>
//
// 本机无 flutter → 未编译、未运行（见 README 的"状态"一节）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'src/netbird_bridge.dart';
import 'src/probe.dart';
import 'src/wire.dart';

/// `--dart-define` 必须是编译期常量，所以集中在这里，不在运行时拼名字。
class Env {
  static const String host = String.fromEnvironment('PROBE_HOST', defaultValue: 'motifd-laptop');
  static const int port = int.fromEnvironment('PROBE_PORT', defaultValue: 7777);
  static const String token = String.fromEnvironment('PROBE_TOKEN', defaultValue: '');
  static const String netbirdMgmt =
      String.fromEnvironment('NETBIRD_MGMT', defaultValue: 'https://api.netbird.io');
  static const String setupKey = String.fromEnvironment('NETBIRD_SETUP_KEY', defaultValue: '');
  static const String psk = String.fromEnvironment('MOTIF_PSK', defaultValue: '');
  static const bool useNetbird =
      bool.fromEnvironment('PROBE_NETBIRD', defaultValue: true);
  static const int b2Seconds = int.fromEnvironment('PROBE_B2_SECONDS', defaultValue: 45);
  static const int b3Bytes = int.fromEnvironment('PROBE_B3_BYTES', defaultValue: 1048576);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProbeApp());
}

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});

  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> with WidgetsBindingObserver {
  final List<Map<String, dynamic>> _lifecycle = [];
  Map<String, dynamic>? _report;
  String _status = 'idle';
  int? _proxyPort;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 后台存活记录：iOS 进后台后进程会被挂起，Dart 定时器随之中断。
  /// 所以这里记的不是"后台还能跑多久"，而是"回到前台时隧道是否还活着"。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle.add({
      'at': DateTime.now().toIso8601String(),
      'state': state.name,
      'proxy_port': _proxyPort,
    });
    if (state == AppLifecycleState.resumed) {
      _probeAfterResume();
    }
    setState(() {});
  }

  Future<void> _probeAfterResume() async {
    if (_proxyPort == null) return;
    final sw = Stopwatch()..start();
    final entry = <String, dynamic>{
      'at': DateTime.now().toIso8601String(),
      'event': 'resume_probe',
    };
    try {
      final t = await Tunnel.open(
        host: Env.host,
        port: Env.port,
        proxyHost: '127.0.0.1',
        proxyPort: _proxyPort,
      );
      final conn = RawHttpConn(t);
      final r = await conn.request('GET', '/ping');
      await t.close();
      entry['ok'] = r.status == 200;
      entry['http_status'] = r.status;
    } catch (e) {
      entry['ok'] = false;
      entry['error'] = '$e';
    }
    entry['ms'] = sw.elapsedMilliseconds;
    _lifecycle.add(entry);
    setState(() {});
  }

  ProbeConfig _cfg() => ProbeConfig(
        host: Env.host,
        port: Env.port,
        token: Env.token,
        transport: 'connect',
        proxyHost: '127.0.0.1',
        proxyPort: _proxyPort,
        b2Seconds: Env.b2Seconds,
        b3Bytes: Env.b3Bytes,
      );

  Future<void> _boot() async {
    if (!Env.useNetbird) {
      setState(() => _status = 'netbird 跳过（PROBE_NETBIRD=false），只跑裸 CONNECT 路径');
      return;
    }
    setState(() => _status = 'netbird 启动中…');
    try {
      final port = await NetbirdBridge.bootstrap(
        managementUrl: Env.netbirdMgmt,
        setupKey: Env.setupKey,
        psk: Env.psk,
      );
      HttpOverrides.global = NetbirdBridge.httpOverrides(port);
      setState(() {
        _proxyPort = port;
        _status = 'netbird 已连接，本地代理 127.0.0.1:$port';
      });
    } catch (e) {
      setState(() => _status = 'netbird 失败：$e');
    }
  }

  Future<void> _run() async {
    setState(() => _status = '跑批中…');
    final runner = ProbeRunner(_cfg());
    final report = await runner.runAll();
    report['lifecycle'] = _lifecycle;
    final file = File('${Directory.systemTemp.path}/crossdesk-p0b-device-'
        '${DateTime.now().millisecondsSinceEpoch}.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    setState(() {
      _report = report;
      _status = '完成：${report['verdict']['overall']} → ${file.path}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Crossdesk P0-B 探针')),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_status),
                  const SizedBox(height: 8),
                  Row(children: [
                    FilledButton(onPressed: _run, child: const Text('跑 B1–B4')),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => setState(() => _lifecycle.clear()),
                      child: const Text('清空生命周期记录'),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text('生命周期事件：${_lifecycle.length} 条'
                      '（前后台切换 + 每次回前台后的隧道探测）'),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _report == null
                      ? '还没有报告。点「跑 B1–B4」。\n\n'
                          '后台存活测法：把 app 切后台 5 / 15 / 30 分钟再回前台，'
                          '每次回来会追加一条 resume_probe（ok/error + 耗时）。'
                      : const JsonEncoder.withIndent('  ').convert(_report),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

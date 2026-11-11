// integration_test/probe_test.dart —— 真机一条命令跑完 B1–B4
//
//   flutter test integration_test/probe_test.dart -d <device-id> \
//     --dart-define=PROBE_HOST=motifd-laptop \
//     --dart-define=PROBE_TOKEN=<bearer> \
//     --dart-define=NETBIRD_MGMT=https://api.netbird.io \
//     --dart-define=NETBIRD_SETUP_KEY=<setup key> \
//     --dart-define=MOTIF_PSK=<pair link 里的 psk> \
//     --dart-define=PROBE_B2_SECONDS=300
//
// 退出码：任一必需层不是 pass → 测试失败（CI/人工都能一眼看）。
// 报告同时写到 Directory.systemTemp（Xcode → Devices → Containers 可取，
// 或再用 `flutter logs` 里的 JSON 复制）。
//
// ⚠️ 交付机没有 dart/flutter，本文件未编译、未在真机跑过。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ios_connect_probe/src/netbird_bridge.dart';
import 'package:ios_connect_probe/src/probe.dart';

class Env {
  static const String host = String.fromEnvironment('PROBE_HOST', defaultValue: 'motifd-laptop');
  static const int port = int.fromEnvironment('PROBE_PORT', defaultValue: 7777);
  static const String token = String.fromEnvironment('PROBE_TOKEN', defaultValue: '');
  static const String mgmt =
      String.fromEnvironment('NETBIRD_MGMT', defaultValue: 'https://api.netbird.io');
  static const String setupKey = String.fromEnvironment('NETBIRD_SETUP_KEY', defaultValue: '');
  static const String psk = String.fromEnvironment('MOTIF_PSK', defaultValue: '');
  static const int b2Seconds = int.fromEnvironment('PROBE_B2_SECONDS', defaultValue: 45);
  static const bool useNetbird = bool.fromEnvironment('PROBE_NETBIRD', defaultValue: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('P0-B B1/B1p/B2/B3/B4 经 CONNECT 隧道', (tester) async {
    int? proxyPort;
    if (Env.useNetbird) {
      final dir = Directory.systemTemp.path;
      proxyPort = await NetbirdBridge.bootstrap(
        managementUrl: Env.mgmt,
        setupKey: Env.setupKey,
        configPath: '$dir/crossdesk_nb_config.json',
        statePath: '$dir/crossdesk_nb_state.json',
      );
      // 1.0.5 没有 NetbirdHttpOverrides；本探针走裸 CONNECT（wire.dart），不需要它。
    } else {
      proxyPort = int.tryParse(
          const String.fromEnvironment('PROBE_PROXY_PORT', defaultValue: ''));
    }

    final cfg = ProbeConfig(
      host: Env.host,
      port: Env.port,
      token: Env.token,
      transport: proxyPort == null ? 'direct' : 'connect',
      proxyHost: '127.0.0.1',
      proxyPort: proxyPort,
      b2Seconds: Env.b2Seconds,
    );
    final runner = ProbeRunner(cfg);
    final report = await runner.runAll();

    final json = const JsonEncoder.withIndent('  ').convert(report);
    // ignore: avoid_print
    print('=== P0B REPORT BEGIN ===');
    // ignore: avoid_print
    print(json);
    // ignore: avoid_print
    print('=== P0B REPORT END ===');

    final file = File('${Directory.systemTemp.path}/crossdesk-p0b-'
        '${DateTime.now().millisecondsSinceEpoch}.json');
    await file.writeAsString(json);
    // ignore: avoid_print
    print('[probe] report written to ${file.path}');

    final layers = (report['verdict']['layers'] as Map).cast<String, dynamic>();
    expect(layers['B1_ping'], 'pass', reason: 'B1: /ping 经隧道不通 → 隧道层问题');
    expect(layers['B1p_auth_session'], 'pass',
        reason: 'B1p: 鉴权/会话语义不通 → 先查 bearer，再查隧道');
    expect(layers['B2_events_ws'], 'pass', reason: 'B2: /events 长连接不达标');
    expect(layers['B3_pty_bidirectional'], 'pass',
        reason: 'B3: /pty 双向 1MB 校验失败 → 触发兜底决策树');
    expect(layers['B4_reconnect_409'], 'pass', reason: 'B4: 409 → 重 attach 恢复失败');

    if (Env.useNetbird) {
      await NetbirdBridge.down();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}

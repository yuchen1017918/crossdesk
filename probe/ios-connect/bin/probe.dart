// bin/probe.dart —— 纯 Dart CLI（不 import Flutter，不依赖 flutter_netbird）
//
// 它能跑的场景：macOS/Linux/Windows 上有一个本地 HTTP 代理端口（例如 netbird 在
// 桌面端的 start_proxy，或者 probe/sim/connect_proxy.py），验证"经 CONNECT 跑
// B1–B4"。它**不能**在 iOS 真机上跑（那里必须由 Flutter 宿主提供代理端口），
// 真机走 integration_test/probe_test.dart。
//
// 用法：
//   dart run bin/probe.dart \
//     --host 127.0.0.1 --port 17777 \
//     --proxy-host 127.0.0.1 --proxy-port 18080 \
//     --token p0b-sim-token --out report.json
//
//   # 直连（对照）
//   dart run bin/probe.dart --host 127.0.0.1 --port 17777 --token t
//
// ⚠️ 交付机没有 dart，未编译过；按 README 的"状态"口径使用。

import 'dart:convert';
import 'dart:io';

import 'package:ios_connect_probe/src/probe.dart';

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);
  final cfg = ProbeConfig(
    host: args.host,
    port: args.port,
    token: args.token,
    transport: args.proxyPort == null ? 'direct' : 'connect',
    proxyHost: args.proxyHost,
    proxyPort: args.proxyPort,
    b1Requests: args.b1,
    b2Seconds: args.b2,
    b3Bytes: args.b3Bytes,
    b4Cycles: args.b4,
    b3Payloads: args.payloads,
  );
  stdout.writeln('[probe] target=${cfg.host}:${cfg.port} '
      'transport=${cfg.transport} proxy=${cfg.proxyHost}:${cfg.proxyPort}');
  final runner = ProbeRunner(cfg);
  final report = await runner.runAll();
  final json = const JsonEncoder.withIndent('  ').convert(report);
  final out = args.out ?? 'p0b-report-${DateTime.now().millisecondsSinceEpoch}.json';
  await File(out).writeAsString(json);
  stdout.writeln(json);
  stdout.writeln('[probe] wrote $out');
  final verdict = report['verdict']['overall'];
  exit(verdict == 'pass' ? 0 : (verdict == 'partial' ? 2 : 1));
}

class _Args {
  _Args({
    required this.host,
    required this.port,
    required this.token,
    this.proxyHost = '127.0.0.1',
    this.proxyPort,
    this.out,
    this.b1 = 200,
    this.b2 = 45,
    this.b3Bytes = 1048576,
    this.b4 = 3,
    this.payloads = const ['random', 'tui'],
  });

  final String host;
  final int port;
  final String token;
  final String proxyHost;
  final int? proxyPort;
  final String? out;
  final int b1;
  final int b2;
  final int b3Bytes;
  final int b4;
  final List<String> payloads;

  static _Args parse(List<String> argv) {
    String? opt(String name) {
      final i = argv.indexOf('--$name');
      if (i < 0 || i + 1 >= argv.length) return null;
      return argv[i + 1];
    }

    return _Args(
      host: opt('host') ?? '127.0.0.1',
      port: int.tryParse(opt('port') ?? '') ?? 7777,
      token: opt('token') ?? '',
      proxyHost: opt('proxy-host') ?? '127.0.0.1',
      proxyPort: int.tryParse(opt('proxy-port') ?? ''),
      out: opt('out'),
      b1: int.tryParse(opt('b1-requests') ?? '') ?? 200,
      b2: int.tryParse(opt('b2-seconds') ?? '') ?? 45,
      b3Bytes: int.tryParse(opt('b3-bytes') ?? '') ?? 1048576,
      b4: int.tryParse(opt('b4-cycles') ?? '') ?? 3,
      payloads: (opt('payloads') ?? 'random,tui').split(','),
    );
  }
}

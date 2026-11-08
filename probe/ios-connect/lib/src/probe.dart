// probe.dart —— B1 / B1' / B2 / B3 / B4 四层验收，输出与 probe/sim/bench.py
// **同一 schema** 的 JSON（schema: crossdesk.p0b.probe/1）。
//
// 与 Python 侧一致的口径（2026-11-08 lead 纠偏）：
//   B1  GET /ping        经 CONNECT 隧道 200 + 版本（只验隧道，无鉴权变量）
//   B1' POST /rpc/session.list + Bearer 200（验鉴权头透传，**不等于** psk 派生已验证）
//   B2  GET /events?session=  WS 升级 + 保持 N 秒，20s Ping 计数按观测窗口折算
//   B3  GET /pty/<id>?session=  双向 1MB sha256；legacy raw 与 framed zlib 各一档
//   B4  409 NotAttached → 重新 attach → 恢复（后台存活另由 lifecycle.dart 记录）

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'wire.dart';

const String kSchema = 'crossdesk.p0b.probe/1';

String isoNow() => DateTime.now().toIso8601String();

String sha256Hex(List<int> data) => crypto.sha256.convert(data).toString();

/// 统计摘要，键名与 Python 侧 stats() 完全一致。
Map<String, dynamic> stats(List<double> values) {
  if (values.isEmpty) return {'n': 0};
  final s = List<double>.from(values)..sort();
  double pct(double p) {
    if (s.length == 1) return s[0];
    final k = (s.length - 1) * (p / 100.0);
    final lo = k.floor();
    final hi = min(lo + 1, s.length - 1);
    final frac = k - lo;
    return s[lo] * (1 - frac) + s[hi] * frac;
  }

  double round3(double v) => (v * 1000).roundToDouble() / 1000;
  final mean = s.reduce((a, b) => a + b) / s.length;
  return {
    'n': s.length,
    'min': round3(s.first),
    'p50': round3(pct(50)),
    'p95': round3(pct(95)),
    'p99': round3(pct(99)),
    'max': round3(s.last),
    'mean': round3(mean),
  };
}

// ---------------------------------------------------------------------------
// 载荷生成（xorshift32：跨次运行可复现；与 Python 侧不要求逐字节相同，
// 因为校验在各自进程内完成 —— sent 与 echoed 自比对）
// ---------------------------------------------------------------------------
class XorShift32 {
  XorShift32(int seed) : _s = seed == 0 ? 0x9E3779B9 : seed;
  int _s;
  int next() {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x & 0xFFFFFFFF;
    return _s;
  }
}

Uint8List makePayload(int size, String kind) {
  if (kind == 'random') {
    final rnd = XorShift32(1234);
    final out = Uint8List(size);
    for (var i = 0; i < size; i++) {
      out[i] = rnd.next() & 0xFF;
    }
    return out;
  }
  if (kind == 'tui') {
    final sb = ByteSink();
    var i = 0;
    while (sb.length < size) {
      i++;
      final line = '\x1b[38;5;${i % 256}m~/proj/src/main.rs:${i % 500}\x1b[0m  '
          '\x1b[1;32m+${i % 97}\x1b[0m \x1b[2mfn handler_${i % 40}(&self) -> Result<()>\x1b[0m\r\n'
          '\x1b[34m  cargo build --release --target aarch64-apple-ios\x1b[0m\r\n'
          '   Compiling crossdesk v0.1.${i % 9} (${i % 500}/512)\r\n';
      sb.add(utf8.encode(line));
    }
    return Uint8List.fromList(sb.takeBytes().sublist(0, size));
  }
  throw ArgumentError('unknown payload kind $kind');
}

// ---------------------------------------------------------------------------
class ProbeConfig {
  ProbeConfig({
    required this.host,
    required this.port,
    required this.token,
    this.proxyHost,
    this.proxyPort,
    this.transport = 'connect',
    this.b1Requests = 200,
    this.b2Seconds = 45,
    this.pingIntervalSeconds = 20,
    this.b3Bytes = 1024 * 1024,
    this.b3FrameSize = 64 * 1024,
    this.b3Payloads = const ['random', 'tui'],
    this.b4Cycles = 3,
  });

  final String host;
  final int port;
  final String token;
  final String? proxyHost;
  final int? proxyPort;
  final String transport; // direct | connect | overrides
  final int b1Requests;
  final int b2Seconds;
  final int pingIntervalSeconds;
  final int b3Bytes;
  final int b3FrameSize;
  final List<String> b3Payloads;
  final int b4Cycles;

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'transport': transport,
        'proxy_port': proxyPort,
        'b1_requests': b1Requests,
        'b2_seconds': b2Seconds,
        'ping_interval_s': pingIntervalSeconds,
        'b3_bytes': b3Bytes,
        'b3_frame': b3FrameSize,
        'b3_payloads': b3Payloads,
        'b4_cycles': b4Cycles,
      };
}

class ProbeRunner {
  ProbeRunner(this.cfg);

  final ProbeConfig cfg;
  final List<Map<String, dynamic>> findings = [];

  Map<String, String> get _auth => {'Authorization': 'Bearer ${cfg.token}'};

  Future<Tunnel> _tunnel() => Tunnel.open(
        host: cfg.host,
        port: cfg.port,
        proxyHost: cfg.transport == 'connect' ? (cfg.proxyHost ?? '127.0.0.1') : null,
        proxyPort: cfg.transport == 'connect' ? cfg.proxyPort : null,
      );

  // -- B1 ---------------------------------------------------------------
  Future<Map<String, dynamic>> b1() async {
    final out = <String, dynamic>{
      'status': 'fail',
      'endpoint': 'GET /ping',
      'auth_required': false,
      'requests': cfg.b1Requests,
      'ok': 0,
      'errors': 0,
      'versions': <String>[],
      'error_samples': <String>[],
    };
    final lat = <double>[];
    final ttfb = <double>[];
    final versions = <String>{};
    Tunnel? t;
    try {
      t = await _tunnel();
      final conn = RawHttpConn(t);
      for (var i = 0; i < cfg.b1Requests; i++) {
        try {
          final r = await conn.request('GET', '/ping');
          if (r.status != 200) {
            out['errors'] = (out['errors'] as int) + 1;
            (out['error_samples'] as List).add('HTTP ${r.status}');
            continue;
          }
          final j = r.json as Map<String, dynamic>;
          versions.add('${j['version']}');
          out['ok'] = (out['ok'] as int) + 1;
          lat.add(r.totalMs);
          ttfb.add(r.ttfbMs);
        } catch (e) {
          out['errors'] = (out['errors'] as int) + 1;
          (out['error_samples'] as List).add('$e');
          if ((out['error_samples'] as List).length > 3) break;
        }
      }
    } catch (e) {
      (out['error_samples'] as List).add('tunnel: $e');
    } finally {
      await t?.close();
    }
    out['versions'] = versions.toList()..sort();
    out['latency_ms'] = stats(lat);
    out['ttfb_ms'] = stats(ttfb);
    final ok = out['ok'] == cfg.b1Requests;
    out['status'] = ok ? 'pass' : ((out['ok'] as int) > 0 ? 'partial' : 'fail');
    return out;
  }

  // -- B1' --------------------------------------------------------------
  Future<Map<String, dynamic>> b1p() async {
    final checks = <String, dynamic>{};

    Future<void> run(String name, Future<Map<String, dynamic>> Function() fn) async {
      final sw = Stopwatch()..start();
      try {
        final val = await fn();
        final entry = <String, dynamic>{
          'ok': true,
          'detail': val,
          'ms': sw.elapsedMilliseconds,
        };
        if (val['status'] is int) entry['http_status'] = val['status'];
        checks[name] = entry;
      } catch (e) {
        checks[name] = <String, dynamic>{
          'ok': false,
          'error': '$e',
          'ms': sw.elapsedMilliseconds,
        };
      }
    }

    Future<RawResponse> withTunnel(Map<String, String> headers, String method,
        String path, {List<int>? body}) async {
      final t = await _tunnel();
      try {
        final conn = RawHttpConn(t);
        final r = await conn.request(method, path, headers: headers, body: body);
        return r;
      } finally {
        await t.close();
      }
    }

    await run('session_list_bearer_200', () async {
      final r = await withTunnel(_auth, 'POST', '/rpc/session.list', body: utf8.encode('{}'));
      if (r.status != 200) throw StateError('HTTP ${r.status}');
      final j = r.json as Map<String, dynamic>;
      return {'status': 200, 'sessions': (j['sessions'] as List?)?.length ?? 0};
    });

    await run('session_list_no_bearer_401', () async {
      final r = await withTunnel({}, 'POST', '/rpc/session.list', body: utf8.encode('{}'));
      if (r.status != 401) throw StateError('expected 401, got ${r.status}');
      final j = r.json as Map<String, dynamic>;
      return {'status': 401, 'body': (j['error'] as Map)['message']};
    });

    String? sid;
    await run('attach_returns_session_header', () async {
      final t = await _tunnel();
      try {
        final conn = RawHttpConn(t);
        final r = await conn.request('POST', '/rpc/session.attach',
            headers: _auth, body: utf8.encode('{"name":"main"}'));
        if (r.status != 200) throw StateError('HTTP ${r.status}');
        sid = r.headers['x-motif-session'];
        if (sid == null || sid!.isEmpty) throw StateError('missing X-Motif-Session');
        final j = r.json as Map<String, dynamic>;
        for (final k in ['session', 'client_id', 'ptys', 'last_seq']) {
          if (!j.containsKey(k)) throw StateError('attach body missing $k');
        }
        return {'sid_prefix': sid!.substring(0, min(10, sid!.length)), 'last_seq': j['last_seq']};
      } finally {
        await t.close();
      }
    });

    await run('unknown_method_404', () async {
      final r = await withTunnel(
          {..._auth, if (sid != null) 'X-Motif-Session': sid!},
          'POST',
          '/rpc/does.not.exist',
          body: utf8.encode('{}'));
      if (r.status != 404) throw StateError('expected 404, got ${r.status}');
      final j = r.json as Map<String, dynamic>;
      return {'status': 404, 'code': (j['error'] as Map)['code']};
    });

    await run('pty_create_without_session_409', () async {
      final r = await withTunnel(_auth, 'POST', '/rpc/pty.create', body: utf8.encode('{}'));
      if (r.status != 409) throw StateError('expected 409, got ${r.status}');
      final j = r.json as Map<String, dynamic>;
      return {'status': 409, 'message': (j['error'] as Map)['message']};
    });

    await run('pty_create_with_session_200', () async {
      if (sid == null) throw StateError('no sid from attach');
      final r = await withTunnel({..._auth, 'X-Motif-Session': sid!}, 'POST',
          '/rpc/pty.create', body: utf8.encode('{"cols":120,"rows":32}'));
      if (r.status != 200) throw StateError('expected 200, got ${r.status}');
      final j = r.json as Map<String, dynamic>;
      return {'status': 200, 'pty_id': (j['info'] as Map)['id']};
    });

    final passed = checks.values.where((c) => (c as Map)['ok'] == true).length;
    return {
      'status': passed == checks.length ? 'pass' : (passed > 0 ? 'partial' : 'fail'),
      'passed': passed,
      'total': checks.length,
      'checks': checks,
      'used_stub_auth': true,
      'real_psk_derivation_verified': false,
      'auth_note': 'Bearer 头的存在性与 401/409/404 语义已验；真正的 psk→bearer 派生'
          '（rzv::derive_bearer）必须在真实 motifd 上对拍，见 runbook §3。',
    };
  }

  // -- B2 ---------------------------------------------------------------
  Future<Map<String, dynamic>> b2(String sid) async {
    final expected = cfg.pingIntervalSeconds > 0
        ? (cfg.b2Seconds ~/ cfg.pingIntervalSeconds)
        : 0;
    final out = <String, dynamic>{
      'status': 'fail',
      'duration_s': cfg.b2Seconds,
      'ping_interval_s': cfg.pingIntervalSeconds,
      'ping_observed': 0,
      'ping_expected_by_window': expected,
      'ping_window_too_short': cfg.b2Seconds < cfg.pingIntervalSeconds,
      'ping_verdict': 'n/a',
      'upgrade_ms': null,
      'events': 0,
      'seq_gaps': 0,
      'close_code': null,
      'errors': <String>[],
      'first_event_ms': null,
      'inter_event_ms': {'n': 0},
    };
    Tunnel? t;
    Timer? watchdog;
    try {
      t = await _tunnel();
      // 读等待用 watchdog 兜底：到点销毁 socket，让挂起的读抛错，避免探测卡死。
      watchdog = Timer(Duration(seconds: cfg.b2Seconds + 15), () {
        try {
          t?.socket.destroy();
        } catch (_) {}
      });
      final ws = WsClient(t);
      await ws.connect('/events?session=$sid&since=0', headers: _auth);
      out['upgrade_ms'] = ws.handshakeMs;
      if (!ws.acceptOk) throw StateError('bad Sec-WebSocket-Accept');
      final t0 = DateTime.now();
      final deadline = t0.add(Duration(seconds: cfg.b2Seconds));
      int? lastSeq;
      var gaps = 0;
      final inter = <double>[];
      int? lastArrivalUs;
      while (DateTime.now().isBefore(deadline)) {
        final frame = await ws.recvMessage();
        if (frame[0] == opClose) {
          out['close_code'] = ws.closeCode;
          break;
        }
        if (frame[0] != opText) continue;
        final nowUs = DateTime.now().microsecondsSinceEpoch;
        final msg = jsonDecode(utf8.decode(frame.sublist(1))) as Map<String, dynamic>;
        final params = (msg['params'] as Map?)?.cast<String, dynamic>() ?? {};
        final seq = params['seq'] as int?;
        out['events'] = (out['events'] as int) + 1;
        out['first_event_ms'] ??= (nowUs - t0.microsecondsSinceEpoch) / 1000.0;
        if (lastSeq != null && seq != null && seq - lastSeq - 1 > 0) gaps++;
        lastSeq = seq;
        if (lastArrivalUs != null) inter.add((nowUs - lastArrivalUs) / 1000.0);
        lastArrivalUs = nowUs;
      }
      out['pings'] = ws.pingsRecv;
      out['ping_observed'] = ws.pingsRecv;
      out['ping_verdict'] = ws.pingsRecv >= expected
          ? 'pass'
          : (cfg.b2Seconds < cfg.pingIntervalSeconds ? 'window_too_short' : 'missing');
      out['seq_gaps'] = gaps;
      out['inter_event_ms'] = stats(inter);
      out['elapsed_s'] = DateTime.now().difference(t0).inMilliseconds / 1000.0;
      await ws.close();
    } catch (e) {
      (out['errors'] as List).add('$e');
    } finally {
      watchdog?.cancel();
      await t?.close();
    }
    final pingsOk = out['ping_verdict'] == 'pass' || out['ping_verdict'] == 'window_too_short';
    out['status'] = (out['errors'] as List).isEmpty &&
            (out['events'] as int) > 0 &&
            (out['seq_gaps'] as int) == 0 &&
            pingsOk
        ? 'pass'
        : ((out['events'] as int) > 0 ? 'partial' : 'fail');
    return out;
  }

  // -- B3 ---------------------------------------------------------------
  Future<Map<String, dynamic>> b3(
      String sid, String ptyId, Uint8List payload, bool framed) async {
    final out = <String, dynamic>{
      'status': 'fail',
      'mode': framed ? 'framed-zlib' : 'legacy-raw',
      'bytes_up': payload.length,
      'bytes_down': 0,
      'wire_bytes_down': 0,
      'sha256_up': sha256Hex(payload),
      'sha256_down': null,
      'match': false,
      'frame_size': cfg.b3FrameSize,
      'frames': 0,
      'frame_rtt_ms': {'n': 0},
      'throughput_mbps': null,
      'meta_ms': null,
      'compression_ratio': null,
      'errors': <String>[],
    };
    Tunnel? t;
    Timer? watchdog;
    try {
      t = await _tunnel();
      watchdog = Timer(const Duration(seconds: 180), () {
        try {
          t?.socket.destroy();
        } catch (_) {}
      });
      final ws = WsClient(t);
      var path = '/pty/$ptyId?session=$sid&since=0';
      if (framed) path += '&pty_frame=v1&pty_compress=zlib';
      await ws.connect(path, headers: _auth);
      if (!ws.acceptOk) throw StateError('bad Sec-WebSocket-Accept');

      final metaStart = nowUs();
      final metaFrame = await ws.recvMessage();
      out['meta_ms'] = (nowUs() - metaStart) / 1000.0;
      final meta = jsonDecode(utf8.decode(metaFrame.sublist(1))) as Map<String, dynamic>;
      if (framed && meta['pty_frame'] != 'v1') {
        throw StateError('framed mode not confirmed: $meta');
      }

      final frameSize = cfg.b3FrameSize;
      final nframes = (payload.length + frameSize - 1) ~/ frameSize;
      final sendTimes = List<int>.filled(nframes, 0);
      final recv = ByteSink();
      var wire = 0;
      var framesDone = 0;
      final rtts = <double>[];
      final tStart = nowUs();
      int? tFirst;

      final sender = () async {
        for (var i = 0; i < nframes; i++) {
          final start = i * frameSize;
          final end = min(start + frameSize, payload.length);
          sendTimes[i] = nowUs();
          await ws.sendBinary(payload.sublist(start, end));
        }
      }();

      Future<void> receiver() async {
        while (recv.length < payload.length) {
          final frame = await ws.recvMessage();
          if (frame[0] == opClose) {
            (out['errors'] as List).add('closed code=${ws.closeCode}');
            break;
          }
          if (frame[0] != opBinary) continue;
          final data = Uint8List.fromList(frame.sublist(1));
          wire += data.length;
          Uint8List body;
          if (framed) {
            if (data.isEmpty) throw StateError('empty framed frame');
            final flags = data[0];
            if (flags & 0xFE != 0) throw StateError('reserved flags: $flags');
            body = flags & 1 == 1
                ? Uint8List.fromList(zlib.decode(data.sublist(1)))
                : Uint8List.fromList(data.sublist(1));
          } else {
            body = data;
          }
          recv.add(body);
          tFirst ??= nowUs();
          while (framesDone < nframes &&
              recv.length >= min((framesDone + 1) * frameSize, payload.length)) {
            rtts.add((nowUs() - sendTimes[framesDone]) / 1000.0);
            framesDone++;
          }
        }
      }

      await Future.wait([sender, receiver()]);
      final tLast = nowUs();
      final got = recv.takeBytes();
      out['bytes_down'] = got.length;
      out['wire_bytes_down'] = wire;
      out['sha256_down'] = sha256Hex(got);
      out['match'] = out['sha256_down'] == out['sha256_up'];
      out['frames'] = framesDone;
      out['frame_rtt_ms'] = stats(rtts);
      if (tFirst != null) {
        // `tFirst` 是在循环里被 `??=` 赋值的，Dart 的类型提升跨这个边界不成立，
        // 所以这里必须显式 `!`（否则 `int? - int` 直接编译失败）。
        final first = tFirst!;
        final mbps = got.length / max((tLast - first) / 1e6, 1e-9) / (1024 * 1024);
        out['throughput_mbps'] = double.parse(mbps.toStringAsFixed(3));
        out['total_elapsed_s'] =
            double.parse(((tLast - tStart) / 1e6).toStringAsFixed(4));
      }
      if (framed && got.isNotEmpty) {
        out['compression_ratio'] =
            double.parse((got.length / max(wire, 1)).toStringAsFixed(3));
      }
      await ws.close();
    } catch (e, st) {
      (out['errors'] as List).add('$e');
      out['trace'] = '$st'.split('\n').take(3).join(' | ');
    } finally {
      watchdog?.cancel();
      await t?.close();
    }
    final ok = out['match'] == true && (out['errors'] as List).isEmpty;
    out['status'] = ok ? 'pass' : ((out['bytes_down'] as int) > 0 ? 'partial' : 'fail');
    return out;
  }

  // -- B4 ---------------------------------------------------------------
  Future<Map<String, dynamic>> b4() async {
    final out = <String, dynamic>{
      'status': 'fail',
      'cycles': cfg.b4Cycles,
      'observed_409': 0,
      'recovered': 0,
      'reattach_ms': {'n': 0},
      'errors': <String>[],
    };
    final samples = <double>[];
    try {
      for (var i = 0; i < cfg.b4Cycles; i++) {
        final (sid, _) = await _attach();
        // 正常一轮 WS
        Tunnel? t = await _tunnel();
        final ws = WsClient(t);
        await ws.connect('/events?session=$sid&since=0', headers: _auth);
        await ws.close();
        await t.close();
        // detach → sid 失效
        t = await _tunnel();
        await RawHttpConn(t).request('POST', '/rpc/session.detach',
            headers: {..._auth, 'X-Motif-Session': sid}, body: utf8.encode('{}'));
        await t.close();
        // 失效 sid 必须 409
        try {
          final t2 = await _tunnel();
          final ws2 = WsClient(t2);
          await ws2.connect('/events?session=$sid&since=0', headers: _auth);
          (out['errors'] as List).add('stale sid still upgraded (expected 409)');
          await t2.close();
        } on SocketException catch (e) {
          if ('$e'.contains('409')) {
            out['observed_409'] = (out['observed_409'] as int) + 1;
          } else {
            (out['errors'] as List).add('$e');
          }
        }
        // 恢复
        final sw = Stopwatch()..start();
        final (sid2, _) = await _attach();
        final t3 = await _tunnel();
        final ws3 = WsClient(t3);
        await ws3.connect('/events?session=$sid2&since=0', headers: _auth);
        await ws3.close();
        await t3.close();
        samples.add(sw.elapsedMicroseconds / 1000.0);
        out['recovered'] = (out['recovered'] as int) + 1;
      }
      out['reattach_ms'] = stats(samples);
    } catch (e) {
      (out['errors'] as List).add('$e');
    }
    final ok = out['observed_409'] == cfg.b4Cycles &&
        out['recovered'] == cfg.b4Cycles &&
        (out['errors'] as List).isEmpty;
    out['status'] = ok ? 'pass' : ((out['recovered'] as int) > 0 ? 'partial' : 'fail');
    return out;
  }

  Future<(String, RawResponse)> _attach() async {
    final t = await _tunnel();
    try {
      final r = await RawHttpConn(t).request('POST', '/rpc/session.attach',
          headers: _auth, body: utf8.encode('{"name":"main"}'));
      final sid = r.headers['x-motif-session'];
      if (sid == null || sid.isEmpty) throw StateError('no X-Motif-Session');
      return (sid, r);
    } finally {
      await t.close();
    }
  }

  // -- 跑全套 -----------------------------------------------------------
  Future<Map<String, dynamic>> runAll() async {
    final acceptance = <String, dynamic>{};
    acceptance['B1_ping'] = await b1();
    acceptance['B1p_auth_session'] = await b1p();

    String? sid;
    try {
      final (s, _) = await _attach();
      sid = s;
    } catch (e) {
      (acceptance['B1p_auth_session'] as Map)['attach_error'] = '$e';
    }

    if (sid != null) {
      acceptance['B2_events_ws'] = await b2(sid);
      // 注意：这个 map 曾经叫 `b3`，直接遮蔽了上面的同名函数 `b3(...)`，
      // 于是 `await b3(...)` 变成"调用 Map" —— 静态分析器抓出来的真 bug。
      final b3res = <String, dynamic>{};
      for (final kind in cfg.b3Payloads) {
        final payload = makePayload(cfg.b3Bytes, kind);
        for (final framed in [false, true]) {
          b3res['${kind}_${framed ? 'framed_zlib' : 'legacy_raw'}'] =
              await b3(sid, 'pty-1', payload, framed);
        }
      }
      final subs = b3res.values.whereType<Map<String, dynamic>>().toList();
      final okN = subs.where((v) => v['status'] == 'pass').length;
      b3res['status'] = subs.isNotEmpty && okN == subs.length
          ? 'pass'
          : (okN > 0 ? 'partial' : 'fail');
      b3res['passed'] = okN;
      b3res['total'] = subs.length;
      acceptance['B3_pty_bidirectional'] = b3res;
    } else {
      acceptance['B2_events_ws'] = {'status': 'fail', 'errors': ['no sid']};
      acceptance['B3_pty_bidirectional'] = {'status': 'fail', 'errors': ['no sid']};
    }
    acceptance['B4_reconnect_409'] = await b4();

    final b1r = acceptance['B1_ping'] as Map<String, dynamic>;
    final b3r = acceptance['B3_pty_bidirectional'] as Map;
    String? rawKey = b3r.keys.whereType<String>().firstWhere(
        (k) => k.endsWith('legacy_raw'), orElse: () => '');
    String? framedKey = b3r.keys.whereType<String>().firstWhere(
        (k) => k.endsWith('framed_zlib'), orElse: () => '');
    final perf = <String, dynamic>{
      'rpc_rtt_ms': b1r['latency_ms'],
      'rpc_ttfb_ms': b1r['ttfb_ms'],
      'ws_upgrade_ms': (acceptance['B2_events_ws'] as Map)['upgrade_ms'],
      if (rawKey.isNotEmpty) 'pty_throughput_mbps_raw': (b3r[rawKey] as Map)['throughput_mbps'],
      if (framedKey.isNotEmpty)
        'pty_throughput_mbps_framed': (b3r[framedKey] as Map)['throughput_mbps'],
      if (framedKey.isNotEmpty)
        'pty_compression_ratio_framed': (b3r[framedKey] as Map)['compression_ratio'],
      if (rawKey.isNotEmpty) 'pty_first_byte_ms_raw': (b3r[rawKey] as Map)['meta_ms'],
    };

    final layers = <String, dynamic>{
      for (final e in acceptance.entries) e.key: (e.value as Map)['status'],
    };
    final allPass = layers.values.every((v) => v == 'pass');
    final anyPass = layers.values.any((v) => v == 'pass');

    return {
      'schema': kSchema,
      'run_id': 'device-${DateTime.now().millisecondsSinceEpoch}',
      'generated_at': isoNow(),
      'harness': {
        'kind': 'device',
        'name': 'dart',
        'dart': Platform.version,
        'os': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'hostname': Platform.localHostname,
        'cpus': Platform.numberOfProcessors,
      },
      'target': {
        'host': cfg.host,
        'port': cfg.port,
        'transport': cfg.transport,
        'proxy_port': cfg.proxyPort,
      },
      'config': cfg.toJson(),
      'acceptance': acceptance,
      'perf': perf,
      'findings': findings,
      'verdict': {
        'layers': layers,
        'overall': allPass ? 'pass' : (anyPass ? 'partial' : 'fail'),
      },
    };
  }
}

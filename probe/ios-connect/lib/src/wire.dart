// wire.dart —— 裸字节层：CONNECT 隧道 / HTTP/1.1 / WebSocket 客户端
//
// 为什么不用 dart:io 的 HttpClient/WebSocket：要测的是"CONNECT 隧道里跑
// HTTP+WS 到底成不成"，中间层越少结论越干净；而且 dart:io 的 WebSocket.connect
// 不接受"经 HTTP 代理"的显式参数（它只认 HttpOverrides）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

Uint8List sha1Bytes(List<int> data) =>
    Uint8List.fromList(crypto.sha1.convert(data).bytes);

/// 简单字节累加器（刻意不用 BytesBuilder：它在 dart:io / dart:typed_data 的归属
/// 随 SDK 版本变动，两个 library 都 import 时可能二义）。
class ByteSink {
  final List<int> _b = <int>[];
  void add(List<int> d) => _b.addAll(d);
  void addByte(int v) => _b.add(v);
  int get length => _b.length;
  Uint8List takeBytes() => Uint8List.fromList(_b);
}

const String wsGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// 帧 opcode
const int opCont = 0x0;
const int opText = 0x1;
const int opBinary = 0x2;
const int opClose = 0x8;
const int opPing = 0x9;
const int opPong = 0xA;

int nowUs() => DateTime.now().microsecondsSinceEpoch;

Uint8List xorMask(Uint8List data, Uint8List mask) {
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = data[i] ^ mask[i & 3];
  }
  return out;
}

/// 带缓冲的字节读：所有读都从这里走，握手后的残留字节不会丢。
class ByteReader {
  ByteReader(Stream<List<int>> stream) {
    _it = StreamIterator<List<int>>(stream);
  }

  late final StreamIterator<List<int>> _it;
  final List<int> _buf = <int>[];
  bool eof = false;

  int get buffered => _buf.length;

  Future<bool> _fill() async {
    if (eof) return false;
    final has = await _it.moveNext();
    if (!has) {
      eof = true;
      return false;
    }
    _buf.addAll(_it.current);
    return true;
  }

  Future<Uint8List> readExact(int n) async {
    while (_buf.length < n) {
      if (!await _fill()) throw const SocketException('eof');
    }
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  Future<Uint8List> readUntil(List<int> delim, {int limit = 1 << 20}) async {
    while (true) {
      final idx = _indexOf(_buf, delim);
      if (idx >= 0) {
        final end = idx + delim.length;
        final out = Uint8List.fromList(_buf.sublist(0, end));
        _buf.removeRange(0, end);
        return out;
      }
      if (_buf.length > limit) throw StateError('header too large');
      if (!await _fill()) throw const SocketException('eof');
    }
  }

  Future<Uint8List> readLine() => readUntil(const [13, 10]);

  static int _indexOf(List<int> hay, List<int> needle) {
    if (needle.isEmpty) return 0;
    final first = needle[0];
    for (var i = 0; i <= hay.length - needle.length; i++) {
      if (hay[i] != first) continue;
      var ok = true;
      for (var j = 1; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  Future<void> close() async {
    await _it.cancel();
  }
}

String _latin1(Uint8List b) => String.fromCharCodes(b);

Map<String, String> parseHeaders(List<String> lines) {
  final h = <String, String>{};
  for (final line in lines) {
    final i = line.indexOf(':');
    if (i <= 0) continue;
    h[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
  }
  return h;
}

/// 一条到 motifd 的连接；给 proxy 时先走 HTTP CONNECT（iOS netbird 的形态）。
class Tunnel {
  Tunnel._(this.socket, this.reader, this.target);

  final Socket socket;
  final ByteReader reader;
  final String target;
  int connectMs = 0;
  int connectStatus = 0;

  static Future<Tunnel> open({
    required String host,
    required int port,
    String? proxyHost,
    int? proxyPort,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final sw = Stopwatch()..start();
    final target = '$host:$port';
    late Socket sock;
    if (proxyHost != null) {
      sock = await Socket.connect(proxyHost, proxyPort!, timeout: timeout);
      sock.setOption(SocketOption.tcpNoDelay, true);
      sock.add(latin1.encode('CONNECT $target HTTP/1.1\r\n'
          'Host: $target\r\n'
          'Proxy-Connection: keep-alive\r\n\r\n'));
      await sock.flush();
      final r = ByteReader(sock);
      final statusLine = _latin1(await r.readLine()).trim();
      final parts = statusLine.split(' ');
      if (parts.length < 2 || int.tryParse(parts[1]) != 200) {
        sock.destroy();
        throw SocketException('CONNECT failed: $statusLine');
      }
      while (true) {
        final line = await r.readLine();
        if (line.length == 2) break; // \r\n
      }
      final t = Tunnel._(sock, r, target);
      t.connectStatus = 200;
      t.connectMs = sw.elapsedMilliseconds;
      return t;
    }
    sock = await Socket.connect(host, port, timeout: timeout);
    sock.setOption(SocketOption.tcpNoDelay, true);
    final t = Tunnel._(sock, ByteReader(sock), target);
    t.connectMs = sw.elapsedMilliseconds;
    return t;
  }

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
    socket.destroy();
  }
}

class RawResponse {
  RawResponse(this.status, this.reason, this.headers, this.body, this.tSentUs,
      this.tFirstUs, this.tDoneUs);

  final int status;
  final String reason;
  final Map<String, String> headers;
  final Uint8List body;
  final int tSentUs;
  final int tFirstUs;
  final int tDoneUs;

  double get ttfbMs => (tFirstUs - tSentUs) / 1000.0;
  double get totalMs => (tDoneUs - tSentUs) / 1000.0;
  dynamic get json => jsonDecode(utf8.decode(body));
}

class RawHttpConn {
  RawHttpConn(this.tunnel);

  final Tunnel tunnel;

  Future<RawResponse> request(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
    bool chunked = false,
  }) async {
    final h = <String, String>{
      'Host': tunnel.target,
      'User-Agent': 'crossdesk-p0b-probe-dart/1',
      'Connection': 'keep-alive',
    };
    if (headers != null) h.addAll(headers);
    if (body != null && body.isNotEmpty) {
      if (chunked) {
        h['Transfer-Encoding'] = 'chunked';
      } else {
        h['Content-Length'] = '${body.length}';
      }
    }
    final sb = StringBuffer('$method $path HTTP/1.1\r\n');
    h.forEach((k, v) => sb.write('$k: $v\r\n'));
    sb.write('\r\n');
    final out = ByteSink();
    out.add(latin1.encode(sb.toString()));
    if (body != null && body.isNotEmpty) {
      if (chunked) {
        out.add(latin1.encode('${body.length.toRadixString(16)}\r\n'));
        out.add(body);
        out.add(latin1.encode('\r\n0\r\n\r\n'));
      } else {
        out.add(body);
      }
    }
    final tSent = nowUs();
    tunnel.socket.add(out.takeBytes());
    await tunnel.socket.flush();

    final r = tunnel.reader;
    final statusLine = _latin1(await r.readLine()).trim();
    final tFirst = nowUs();
    final parts = statusLine.split(' ');
    if (parts.length < 2) throw StateError('bad status line: $statusLine');
    final status = int.parse(parts[1]);
    final reason = parts.length > 2 ? parts[2] : '';
    final headerLines = <String>[];
    while (true) {
      final line = _latin1(await r.readLine());
      if (line == '\r\n') break;
      headerLines.add(line.trim());
    }
    final hs = parseHeaders(headerLines);
    final payload = ByteSink();
    final te = hs['transfer-encoding'] ?? '';
    if (te.toLowerCase().contains('chunked')) {
      while (true) {
        final sizeLine = _latin1(await r.readLine()).trim();
        final size = int.parse(sizeLine.split(';').first, radix: 16);
        if (size == 0) {
          await r.readLine();
          break;
        }
        payload.add(await r.readExact(size));
        await r.readExact(2);
      }
    } else if (hs.containsKey('content-length')) {
      final n = int.parse(hs['content-length']!);
      if (n > 0) payload.add(await r.readExact(n));
    } else {
      // close-delimited
      try {
        while (true) {
          payload.add(await r.readExact(4096));
        }
      } catch (_) {}
    }
    final tDone = nowUs();
    return RawResponse(status, reason, hs, payload.takeBytes(), tSent, tFirst, tDone);
  }
}

/// WS 帧编解码（客户端发必须掩码）。
class RawWs {
  RawWs(this.tunnel) : _rnd = Random.secure();

  final Tunnel tunnel;
  final Random _rnd;
  int closeCode = 0;
  String closeReason = '';
  bool lastFin = true;

  Future<void> send(int opcode, List<int> payload, {bool fin = true}) async {
    final n = payload.length;
    final header = ByteSink();
    header.addByte((fin ? 0x80 : 0x00) | opcode);
    if (n < 126) {
      header.addByte(0x80 | n);
    } else if (n < (1 << 16)) {
      header.addByte(0x80 | 126);
      header.addByte((n >> 8) & 0xFF);
      header.addByte(n & 0xFF);
    } else {
      header.addByte(0x80 | 127);
      final bd = ByteData(8)..setUint64(0, n, Endian.big);
      header.add(bd.buffer.asUint8List());
    }
    final key = Uint8List.fromList(List<int>.generate(4, (_) => _rnd.nextInt(256)));
    header.add(key);
    header.add(xorMask(Uint8List.fromList(payload), key));
    tunnel.socket.add(header.takeBytes());
    await tunnel.socket.flush();
  }

  Future<List<int>> recvFrame() async {
    final h = await tunnel.reader.readExact(2);
    final b1 = h[0], b2 = h[1];
    lastFin = (b1 & 0x80) != 0;
    final opcode = b1 & 0x0F;
    final masked = (b2 & 0x80) != 0;
    var len = b2 & 0x7F;
    if (len == 126) {
      final b = await tunnel.reader.readExact(2);
      len = (b[0] << 8) | b[1];
    } else if (len == 127) {
      final b = await tunnel.reader.readExact(8);
      var l = 0;
      for (final x in b) {
        l = (l << 8) | x;
      }
      len = l;
    }
    Uint8List? mask;
    if (masked) mask = await tunnel.reader.readExact(4);
    var payload = len > 0 ? await tunnel.reader.readExact(len) : Uint8List(0);
    if (mask != null) payload = xorMask(payload, mask);
    if (opcode == opClose) {
      if (payload.length >= 2) {
        closeCode = (payload[0] << 8) | payload[1];
        closeReason = utf8.decode(payload.sublist(2), allowMalformed: true);
      } else {
        closeCode = 1005;
      }
    }
    return <int>[opcode, ...payload];
  }
}

class WsClient {
  WsClient(this.tunnel);

  final Tunnel tunnel;
  late final RawWs ws;
  int handshakeMs = 0;
  bool acceptOk = false;
  int status = 0;
  int pingsRecv = 0;
  int closeCode = 0;

  Future<void> connect(String path, {Map<String, String>? headers}) async {
    final rnd = Random.secure();
    final keyBytes = Uint8List.fromList(List<int>.generate(16, (_) => rnd.nextInt(256)));
    final key = base64.encode(keyBytes);
    final h = <String, String>{
      'Host': tunnel.target,
      'Upgrade': 'websocket',
      'Connection': 'Upgrade',
      'Sec-WebSocket-Key': key,
      'Sec-WebSocket-Version': '13',
      'User-Agent': 'crossdesk-p0b-probe-dart/1',
    };
    if (headers != null) h.addAll(headers);
    final sb = StringBuffer('GET $path HTTP/1.1\r\n');
    h.forEach((k, v) => sb.write('$k: $v\r\n'));
    sb.write('\r\n');
    final sw = Stopwatch()..start();
    tunnel.socket.add(latin1.encode(sb.toString()));
    await tunnel.socket.flush();
    final r = tunnel.reader;
    final statusLine = _latin1(await r.readLine()).trim();
    final parts = statusLine.split(' ');
    status = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    final headerLines = <String>[];
    while (true) {
      final line = _latin1(await r.readLine());
      if (line == '\r\n') break;
      headerLines.add(line.trim());
    }
    handshakeMs = sw.elapsedMilliseconds;
    if (status != 101) throw SocketException('upgrade failed: $statusLine');
    final hs = parseHeaders(headerLines);
    final expect = base64.encode(sha1Bytes(latin1.encode(key + wsGuid)));
    acceptOk = hs['sec-websocket-accept'] == expect;
    ws = RawWs(tunnel);
  }

  Future<List<int>> recvMessage({bool autoPong = true}) async {
    var opcode = -1;
    final data = ByteSink();
    while (true) {
      final frame = await ws.recvFrame();
      final op = frame[0];
      final payload = frame.sublist(1);
      if (op == opPing) {
        pingsRecv++;
        if (autoPong) await ws.send(opPong, payload);
        continue;
      }
      if (op == opPong) continue;
      if (op == opClose) {
        closeCode = ws.closeCode;
        return <int>[opClose, ...payload];
      }
      if (op == opCont) {
        data.add(payload);
      } else {
        opcode = op;
        data.add(payload);
      }
      if (ws.lastFin) return <int>[opcode, ...data.takeBytes()];
    }
  }

  Future<void> sendText(String s) => ws.send(opText, utf8.encode(s));
  Future<void> sendBinary(List<int> b) => ws.send(opBinary, b);

  Future<void> close([int code = 1000]) async {
    try {
      final b = Uint8List(2)
        ..[0] = (code >> 8) & 0xFF
        ..[1] = code & 0xFF;
      await ws.send(opClose, b);
    } catch (_) {}
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:backend/dart_server_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory fixtureRoot;
  late Directory outsideRoot;
  DartServerService? server;

  setUp(() async {
    fixtureRoot = await Directory.systemTemp.createTemp('kdedeck-frontend');
    outsideRoot = await Directory.systemTemp.createTemp('kdedeck-outside');
    await File('${fixtureRoot.path}/index.html')
        .writeAsString('<html>fixture</html>');
    await File('${fixtureRoot.path}/style.css').writeAsString('body {}');
    await File('${fixtureRoot.path}/app.js')
        .writeAsString('const fixture = 1;');
    await File('${fixtureRoot.path}/asset.json').writeAsString('{"ok":true}');
    await Directory('${fixtureRoot.path}/assets').create();
    await File('${fixtureRoot.path}/assets/icon.png').writeAsBytes([1, 2, 3]);
    await File('${outsideRoot.path}/outside.txt').writeAsString('outside');
  });

  tearDown(() async {
    await server?.stopServer();
    await fixtureRoot.delete(recursive: true);
    await outsideRoot.delete(recursive: true);
  });

  test(
    'serves the root and regular frontend assets with safe content types',
    () async {
      server = _newServer(fixtureRoot, outsideRoot);
      await server!.startServer();

      final index = await _get(server!, '/');
      expect(index.statusCode, HttpStatus.ok);
      expect(index.body, '<html>fixture</html>');
      expect(index.contentType, 'text/html');
      _expectSecurityHeaders(index);

      final css = await _get(server!, '/style.css');
      expect(css.statusCode, HttpStatus.ok);
      expect(css.body, 'body {}');
      expect(css.contentType, 'text/css');
      _expectSecurityHeaders(css);

      final js = await _get(server!, '/app.js');
      expect(js.statusCode, HttpStatus.ok);
      expect(js.body, 'const fixture = 1;');
      expect(js.contentType, 'application/javascript');

      final asset = await _get(server!, '/asset.json');
      expect(asset.statusCode, HttpStatus.ok);
      expect(asset.body, '{"ok":true}');
      expect(asset.contentType, 'application/json');

      final nested = await _get(server!, '/assets/icon.png');
      expect(nested.statusCode, HttpStatus.ok);
      expect(nested.contentType, 'image/png');
    },
  );

  test(
    'serves same-origin static GETs independently of WebSocket Origin',
    () async {
      server = _newServer(fixtureRoot, outsideRoot);
      await server!.startServer();

      final response = await _get(
        server!,
        '/',
        origin: 'http://127.0.0.1:${server!.port}',
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body, '<html>fixture</html>');
    },
  );

  test(
    'returns 404 for traversal, encoded traversal, and absolute paths',
    () async {
      server = _newServer(fixtureRoot, outsideRoot);
      await server!.startServer();

      for (final requestPath in [
        '/..%2foutside.txt',
        '/%2e%2e/outside.txt',
        '/%252e%252e/outside.txt',
        '/%2f${outsideRoot.path.substring(1)}/outside.txt',
        '//${outsideRoot.path.substring(1)}/outside.txt',
        '/${outsideRoot.path.substring(1)}/outside.txt',
      ]) {
        final response = await _get(server!, requestPath);
        expect(response.statusCode, HttpStatus.notFound, reason: requestPath);
        expect(response.body, 'Not Found');
        expect(response.body, isNot(contains(outsideRoot.path)));
      }
    },
  );

  test('returns 404 for missing paths without filesystem details', () async {
    server = _newServer(fixtureRoot, outsideRoot);
    await server!.startServer();

    final response = await _get(server!, '/missing.js');
    expect(response.statusCode, HttpStatus.notFound);
    expect(response.body, 'Not Found');
    expect(response.body, isNot(contains(fixtureRoot.path)));
    _expectSecurityHeaders(response);

    final directoryResponse = await _get(server!, '/assets');
    expect(directoryResponse.statusCode, HttpStatus.notFound);
    expect(directoryResponse.body, 'Not Found');
    _expectSecurityHeaders(directoryResponse);

    final iconError = await _get(
      server!,
      '/system_icons?path=${Uri.encodeComponent(outsideRoot.path)}',
    );
    expect(iconError.statusCode, HttpStatus.notFound);
    _expectSecurityHeaders(iconError);
  });

  test('returns 404 for a symlink that escapes the frontend root', () async {
    if (!Platform.isLinux) return;
    final link = Link('${fixtureRoot.path}/escape.js');
    await link.create('${outsideRoot.path}/outside.txt');

    server = _newServer(fixtureRoot, outsideRoot);
    await server!.startServer();

    final response = await _get(server!, '/escape.js');
    expect(response.statusCode, HttpStatus.notFound);
    expect(response.body, 'Not Found');
    expect(response.body, isNot(contains(outsideRoot.path)));
  });

  test('fails closed when the frontend root is missing', () async {
    server = DartServerService.forTesting(
      configPath: '${outsideRoot.path}/config.json',
      frontendRoot: '${outsideRoot.path}/missing-root',
    );
    await server!.startServer();

    final response = await _get(server!, '/');
    expect(response.statusCode, HttpStatus.notFound);
    expect(response.body, 'Not Found');
  });

  test('rejects an oversized request target before static routing', () async {
    server = _newServer(fixtureRoot, outsideRoot, maxRequestTargetBytes: 8);
    await server!.startServer();

    final response = await _rawRequest(
      server!,
      'GET /toolongx HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n',
    );
    expect(response.statusCode, HttpStatus.requestEntityTooLarge);
    expect(response.body, 'Payload Too Large');
    expect(response.body, isNot(contains('toolongx')));
  });

  test('rejects oversized normalized headers before static routing', () async {
    server = _newServer(fixtureRoot, outsideRoot, maxRequestHeaderBytes: 32);
    await server!.startServer();

    final response = await _rawRequest(
      server!,
      'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Padding: 1234567890\r\n\r\n',
    );
    expect(response.statusCode, HttpStatus.requestEntityTooLarge);
    expect(response.body, 'Payload Too Large');
    expect(response.body, isNot(contains('X-Padding')));
  });

  test('rejects oversized header counts before static routing', () async {
    server = _newServer(fixtureRoot, outsideRoot, maxRequestHeaderCount: 1);
    await server!.startServer();

    final response = await _rawRequest(
      server!,
      'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Extra: value\r\n\r\n',
    );
    expect(response.statusCode, HttpStatus.requestEntityTooLarge);
    expect(response.body, 'Payload Too Large');
  });

  test(
    'rejects a declared oversized body before reading its contents',
    () async {
      server = _newServer(fixtureRoot, outsideRoot, maxRequestBodyBytes: 4);
      await server!.startServer();

      final response = await _rawRequest(
        server!,
        'POST / HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Content-Length: 1000000000\r\n\r\n',
      );
      expect(response.statusCode, HttpStatus.requestEntityTooLarge);
      expect(response.body, 'Payload Too Large');
      expect(response.body, isNot(contains('1000000000')));
    },
  );

  test(
    'rejects a chunked body after the bounded read crosses its limit',
    () async {
      server = _newServer(fixtureRoot, outsideRoot, maxRequestBodyBytes: 4);
      await server!.startServer();

      final response = await _rawRequest(
        server!,
        'POST / HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Transfer-Encoding: chunked\r\n\r\n'
        '5\r\nhello\r\n0\r\n\r\n',
      );
      expect(response.statusCode, HttpStatus.requestEntityTooLarge);
      expect(response.body, 'Payload Too Large');
    },
  );

  test('returns a bounded 400 for a malformed request target', () async {
    server = _newServer(fixtureRoot, outsideRoot);
    await server!.startServer();

    final response = await _rawRequest(
      server!,
      'GET /index.html#fragment HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\n'
      '\r\n',
    );
    expect(response.statusCode, HttpStatus.badRequest);
    expect(response.body, 'Bad Request');
    expect(response.body, isNot(contains('fragment')));
  });
}

final class _RawResponse {
  const _RawResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

DartServerService _newServer(
  Directory fixtureRoot,
  Directory outsideRoot, {
  int? maxRequestTargetBytes,
  int? maxRequestHeaderBytes,
  int? maxRequestHeaderCount,
  int? maxRequestBodyBytes,
}) {
  return DartServerService.forTesting(
    configPath: '${outsideRoot.path}/config.json',
    frontendRoot: fixtureRoot.path,
    maxRequestTargetBytes:
        maxRequestTargetBytes ?? DartServerService.defaultMaxRequestTargetBytes,
    maxRequestHeaderBytes:
        maxRequestHeaderBytes ?? DartServerService.defaultMaxRequestHeaderBytes,
    maxRequestHeaderCount:
        maxRequestHeaderCount ?? DartServerService.defaultMaxRequestHeaderCount,
    maxRequestBodyBytes:
        maxRequestBodyBytes ?? DartServerService.defaultMaxRequestBodyBytes,
  );
}

Future<_RawResponse> _rawRequest(
  DartServerService server,
  String request,
) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
  );
  try {
    socket.add(utf8.encode(request));
    await socket.flush();
    final bytes = await socket
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))
        .timeout(const Duration(seconds: 5));
    final text = latin1.decode(bytes);
    final headerEnd = text.indexOf('\r\n\r\n');
    expect(headerEnd, greaterThanOrEqualTo(0), reason: 'missing response');
    final statusLine = text.substring(0, text.indexOf('\r\n'));
    final statusCode = int.parse(statusLine.split(' ')[1]);
    return _RawResponse(statusCode, text.substring(headerEnd + 4));
  } finally {
    socket.destroy();
  }
}

Future<_StaticResponse> _get(
  DartServerService server,
  String requestPath, {
  String? origin,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}$requestPath'),
    );
    if (origin != null) request.headers.set('Origin', origin);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return _StaticResponse(
      response.statusCode,
      body,
      response.headers.contentType?.mimeType,
      {
        'X-Content-Type-Options': response.headers.value(
          'X-Content-Type-Options',
        ),
        'X-Frame-Options': response.headers.value('X-Frame-Options'),
        'Referrer-Policy': response.headers.value('Referrer-Policy'),
        'Content-Security-Policy': response.headers.value(
          'Content-Security-Policy',
        ),
        'Cache-Control': response.headers.value('Cache-Control'),
        'Access-Control-Allow-Origin': response.headers.value(
          'Access-Control-Allow-Origin',
        ),
      },
    );
  } finally {
    client.close(force: true);
  }
}

final class _StaticResponse {
  const _StaticResponse(
    this.statusCode,
    this.body,
    this.contentType,
    this.headers,
  );

  final int statusCode;
  final String body;
  final String? contentType;
  final Map<String, String?> headers;
}

void _expectSecurityHeaders(_StaticResponse response) {
  expect(response.headers['X-Content-Type-Options'], 'nosniff');
  expect(response.headers['X-Frame-Options'], 'DENY');
  expect(response.headers['Referrer-Policy'], 'no-referrer');
  expect(response.headers['Cache-Control'], 'no-store');
  expect(response.headers['Access-Control-Allow-Origin'], isNull);

  final contentSecurityPolicy = response.headers['Content-Security-Policy'];
  expect(contentSecurityPolicy, isNotNull);
  expect(contentSecurityPolicy, contains("default-src 'self'"));
  expect(contentSecurityPolicy, contains("frame-ancestors 'none'"));
  expect(contentSecurityPolicy, contains('https://fonts.googleapis.com'));
  expect(contentSecurityPolicy, contains('https://fonts.gstatic.com'));
  expect(contentSecurityPolicy, isNot(contains('*')));
}

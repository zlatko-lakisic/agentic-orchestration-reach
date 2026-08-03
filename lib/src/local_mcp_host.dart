import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs one or more MCP stdio servers behind `mcp-proxy` on loopback.
///
/// Bound to `127.0.0.1` only — [SessionBridge] is the sole path out via the AO tunnel.
class LocalMcpHost {
  final Map<String, _McpInstance> _byAlias = {};

  bool get isRunning => _byAlias.isNotEmpty;
  bool isAliasRunning(String alias) => _byAlias.containsKey(alias);

  List<String> get activeAliases => _byAlias.keys.toList()..sort();

  String recentLogFor(String alias) => _byAlias[alias]?.log.toString() ?? '';

  Uri mcpUriFor(String alias) {
    final inst = _byAlias[alias];
    if (inst == null) throw StateError('LocalMcpHost alias not started: $alias');
    return Uri.parse('http://127.0.0.1:${inst.port}/mcp');
  }

  /// Back-compat: filesystem MCP URI when that alias is running.
  Uri get mcpUri => mcpUriFor(filesystemTunnelAliasPublic);

  int? get port => _byAlias[filesystemTunnelAliasPublic]?.port;

  /// Exposed for callers that import host without ids (same as [filesystemTunnelAlias]).
  static const filesystemTunnelAliasPublic = 'filesystem';

  Future<void> startFilesystem(List<String> allowlistDirs) async {
    await stopAlias(filesystemTunnelAliasPublic);
    final dirs = allowlistDirs.map((d) => d.trim()).where((d) => d.isNotEmpty).toList();
    if (dirs.isEmpty) {
      throw StateError('Filesystem MCP requires at least one allowlisted directory');
    }
    for (final d in dirs) {
      if (!await Directory(d).exists()) {
        throw StateError('Allowlisted directory does not exist: $d');
      }
    }
    final npx = await _resolveNpx();
    await _startProxy(
      alias: filesystemTunnelAliasPublic,
      npx: npx,
      innerArgs: [npx, '-y', '@modelcontextprotocol/server-filesystem', ...dirs],
    );
  }

  /// Generic `npx -y <package>` MCP behind mcp-proxy (session tunnel).
  ///
  /// When [package] is already installed under `~/.local/node_modules` (or npm
  /// global root), runs `node <entry>` instead of a nested `npx -y` — Pi cold
  /// starts otherwise exceed the health window.
  Future<void> startNpxPackage({
    required String alias,
    required String package,
    Map<String, String>? extraEnv,
    Duration readyTimeout = const Duration(seconds: 90),
  }) async {
    await stopAlias(alias);
    final npx = await _resolveNpx();
    final localEntry = await resolveInstalledPackageEntry(package);
    final List<String> innerArgs;
    if (localEntry != null) {
      final node = await _resolveNode();
      innerArgs = [node, localEntry];
    } else {
      innerArgs = [npx, '-y', package];
    }
    await _startProxy(
      alias: alias,
      npx: npx,
      innerArgs: innerArgs,
      extraEnv: extraEnv,
      readyTimeout: readyTimeout,
    );
  }

  /// Generic `python -m <module>` MCP behind mcp-proxy (session tunnel).
  Future<void> startPythonModule({
    required String alias,
    required String module,
    Map<String, String>? extraEnv,
    Duration readyTimeout = const Duration(seconds: 90),
  }) async {
    await stopAlias(alias);
    final npx = await _resolveNpx();
    final python = await _resolvePython();
    await _startProxy(
      alias: alias,
      npx: npx,
      innerArgs: [python, '-m', module],
      extraEnv: extraEnv,
      readyTimeout: readyTimeout,
    );
  }

  /// Stdio MCP via an explicit command (argv[0] executable + args) behind mcp-proxy.
  Future<void> startStdioCommand({
    required String alias,
    required List<String> command,
    Map<String, String>? extraEnv,
    Duration readyTimeout = const Duration(seconds: 90),
  }) async {
    if (command.isEmpty) {
      throw StateError('startStdioCommand requires a non-empty command');
    }
    await stopAlias(alias);
    final npx = await _resolveNpx();
    await _startProxy(
      alias: alias,
      npx: npx,
      innerArgs: command,
      extraEnv: extraEnv,
      readyTimeout: readyTimeout,
    );
  }

  /// Legacy name used by older call sites / tests.
  Future<void> start(List<String> allowlistDirs) => startFilesystem(allowlistDirs);

  /// Attach a managed loopback HTTP MCP process (e.g. Python streamable HTTP).
  ///
  /// Unlike [attachLoopbackAlias], [process] is tracked and killed by [stopAlias].
  Future<void> attachManagedLoopback({
    required String alias,
    required int port,
    required Process process,
    Duration readyTimeout = const Duration(seconds: 20),
  }) async {
    await stopAlias(alias);
    final inst = _McpInstance(alias: alias, port: port, process: process);
    _byAlias[alias] = inst;

    process.stdout.transform(utf8.decoder).listen((chunk) {
      _appendLog(inst, chunk);
    });
    process.stderr.transform(utf8.decoder).listen((chunk) {
      _appendLog(inst, chunk);
    });

    try {
      await _waitHealthy(inst, timeout: readyTimeout);
    } catch (e) {
      await stopAlias(alias);
      rethrow;
    }
  }

  /// Attach an already-listening loopback HTTP port as a tunnel alias (tests / custom hosts).
  void attachLoopbackAlias(String alias, int port) {
    _byAlias[alias] = _McpInstance(alias: alias, port: port, process: null);
  }

  Future<void> _startProxy({
    required String alias,
    required String npx,
    required List<String> innerArgs,
    Map<String, String>? extraEnv,
    Duration readyTimeout = const Duration(seconds: 90),
  }) async {
    final port = await _pickFreePort();
    // Pin 5.0.x: newer mcp-proxy pulls yargs that requires Node ≥20; Pi is on 18.
    // Do not insert a npx argv separator before innerArgs: npx treats "--" as its own
    // separator and mcp-proxy never receives the stdio server command.
    final args = <String>[
      '-y',
      // 5.12.x needs Node ≥20 (global crypto + modern regex). 5.0.0 on Node 18
      // falsely passed health checks then crashed on initialize/tools/list.
      'mcp-proxy@5.12.5',
      '--port',
      '$port',
      '--server',
      'stream',
      '--streamEndpoint',
      '/mcp',
      ...innerArgs,
    ];

    final env = Map<String, String>.from(Platform.environment);
    if (extraEnv != null) env.addAll(extraEnv);

    final process = await Process.start(
      npx,
      args,
      workingDirectory: Directory.systemTemp.path,
      environment: env,
      runInShell: false,
    );
    final inst = _McpInstance(alias: alias, port: port, process: process);
    _byAlias[alias] = inst;

    process.stdout.transform(utf8.decoder).listen((chunk) {
      _appendLog(inst, chunk);
    });
    process.stderr.transform(utf8.decoder).listen((chunk) {
      _appendLog(inst, chunk);
    });

    try {
      await _waitHealthy(inst, timeout: readyTimeout);
    } catch (e) {
      await stopAlias(alias);
      rethrow;
    }
  }

  /// Strip version from `name@version` / `@scope/name@version` for install lookup.
  static String packageNameFromSpec(String packageSpec) {
    final s = packageSpec.trim();
    if (s.startsWith('@')) {
      final at = s.lastIndexOf('@');
      return at > 0 ? s.substring(0, at) : s;
    }
    final at = s.indexOf('@');
    return at > 0 ? s.substring(0, at) : s;
  }

  /// Absolute path to a locally installed package entry (`main` / `dist/index.js`).
  Future<String?> resolveInstalledPackageEntry(String packageSpec) async {
    final name = packageNameFromSpec(packageSpec);
    final roots = <String>[];
    final home = Platform.environment['HOME']?.trim();
    if (home != null && home.isNotEmpty) {
      roots.add('$home/.local/node_modules/$name');
    }
    try {
      final r = await Process.run('npm', ['root', '-g']);
      if (r.exitCode == 0) {
        final root = (r.stdout as String).trim();
        if (root.isNotEmpty) roots.add('$root/$name');
      }
    } catch (_) {}
    try {
      final r = await Process.run('npm', ['root']);
      if (r.exitCode == 0) {
        final root = (r.stdout as String).trim();
        if (root.isNotEmpty) roots.add('$root/$name');
      }
    } catch (_) {}

    for (final dir in roots) {
      final entry = await _packageEntryIn(dir);
      if (entry != null) return entry;
    }
    return null;
  }

  Future<String?> _packageEntryIn(String dir) async {
    final dist = File('$dir/dist/index.js');
    if (await dist.exists()) return dist.absolute.path;
    final pkgFile = File('$dir/package.json');
    if (!await pkgFile.exists()) return null;
    try {
      final map = jsonDecode(await pkgFile.readAsString()) as Map<String, dynamic>;
      final main = (map['main'] as String?)?.trim();
      if (main != null && main.isNotEmpty) {
        final f = File('$dir/$main');
        if (await f.exists()) return f.absolute.path;
      }
      final bin = map['bin'];
      if (bin is String && bin.trim().isNotEmpty) {
        final f = File('$dir/${bin.trim()}');
        if (await f.exists()) return f.absolute.path;
      } else if (bin is Map && bin.isNotEmpty) {
        final first = bin.values.first;
        if (first is String && first.trim().isNotEmpty) {
          final f = File('$dir/${first.trim()}');
          if (await f.exists()) return f.absolute.path;
        }
      }
    } catch (_) {}
    return null;
  }

  void _appendLog(_McpInstance inst, String chunk) {
    inst.log.write(chunk);
    if (inst.log.length > 8000) {
      final s = inst.log.toString();
      inst.log
        ..clear()
        ..write(s.substring(s.length - 4000));
    }
  }

  Future<void> stopAlias(String alias) async {
    final inst = _byAlias.remove(alias);
    if (inst == null) return;
    final proc = inst.process;
    if (proc == null) return;
    try {
      proc.kill(ProcessSignal.sigterm);
    } catch (_) {}
    try {
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    final aliases = _byAlias.keys.toList();
    for (final a in aliases) {
      await stopAlias(a);
    }
  }

  /// Proxy one AO tunnel HTTP exchange to the local MCP HTTP endpoint for [alias].
  Future<({int status, Map<String, String> headers, List<int> body})> forward({
    required String alias,
    required String method,
    required String path,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    final inst = _byAlias[alias];
    if (inst == null) {
      throw StateError('LocalMcpHost alias is not running: $alias');
    }
    final normalized = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('http://127.0.0.1:${inst.port}$normalized');
    final client = HttpClient();
    try {
      final req = await client.openUrl(method.toUpperCase(), uri);
      headers.forEach((k, v) {
        final lower = k.toLowerCase();
        if (lower == 'host' || lower == 'content-length' || lower == 'connection') {
          return;
        }
        req.headers.set(k, v);
      });
      if (body.isNotEmpty) {
        req.add(body);
      }
      final res = await req.close().timeout(const Duration(seconds: 55));
      final bytes = await res.fold<List<int>>(<int>[], (prev, chunk) => prev..addAll(chunk));
      final outHeaders = <String, String>{};
      res.headers.forEach((name, values) {
        if (values.isNotEmpty) outHeaders[name] = values.join(',');
      });
      return (status: res.statusCode, headers: outHeaders, body: bytes);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _waitHealthy(_McpInstance inst, {required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    final proc = inst.process;
    if (proc == null) return;
    final exitFuture = proc.exitCode;

    while (DateTime.now().isBefore(deadline)) {
      if (!_byAlias.containsKey(inst.alias)) {
        throw StateError('LocalMcpHost exited before ready (${inst.alias})');
      }
      final exited = await Future.any<bool>([
        exitFuture.then((_) => true),
        Future<bool>.delayed(const Duration(milliseconds: 200), () => false),
      ]);
      if (exited) {
        throw StateError(
          'mcp-proxy exited early (${inst.alias}). Log:\n${inst.log.toString().trim()}',
        );
      }

      try {
        final client = HttpClient();
        try {
          final req = await client.openUrl(
            'POST',
            Uri.parse('http://127.0.0.1:${inst.port}/mcp'),
          );
          req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
          req.headers.set(
            HttpHeaders.acceptHeader,
            'application/json, text/event-stream',
          );
          // Real initialize — ping alone returned 400 on broken Node 18 stacks
          // and was treated as healthy (statusCode > 0).
          req.add(utf8.encode(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
            '{"protocolVersion":"2024-11-05","capabilities":{},'
            '"clientInfo":{"name":"ao-reach-health","version":"0"}}}',
          ));
          final res = await req.close().timeout(const Duration(seconds: 3));
          final body = await utf8.decoder.bind(res).join();
          if (res.statusCode >= 200 &&
              res.statusCode < 300 &&
              !body.contains('"error"') &&
              (body.contains('initialize') ||
                  body.contains('protocolVersion') ||
                  body.contains('serverInfo') ||
                  body.contains('capabilities'))) {
            return;
          }
          lastError = 'HTTP ${res.statusCode}: ${body.length > 200 ? body.substring(0, 200) : body}';
        } finally {
          client.close(force: true);
        }
      } catch (e) {
        lastError = e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError(
      'LocalMcpHost did not become ready on port ${inst.port} (${inst.alias}). '
      'Last error: $lastError\n${inst.log.toString().trim()}',
    );
  }

  Future<int> pickFreePort() => _pickFreePort();

  Future<int> _pickFreePort() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    return port;
  }

  Future<String> _resolveNpx() async {
    final candidates = Platform.isWindows
        ? <String>['npx.cmd', 'npx']
        : <String>['npx'];
    for (final c in candidates) {
      try {
        final r = await Process.run(
          c,
          ['--version'],
          runInShell: Platform.isWindows,
        );
        if (r.exitCode == 0) return c;
      } catch (_) {}
    }
    final which = Platform.isWindows ? 'where' : 'which';
    try {
      final r = await Process.run(which, ['npx'], runInShell: Platform.isWindows);
      if (r.exitCode == 0) {
        final line = (r.stdout as String).trim().split('\n').first.trim();
        if (line.isNotEmpty) return line;
      }
    } catch (_) {}
    throw StateError(
      'npx not found — install Node.js to run local MCP bridges '
      '(mcp-proxy + filesystem / tool servers).',
    );
  }

  Future<String> _resolveNode() async {
    final candidates = Platform.isWindows
        ? <String>['node.exe', 'node']
        : <String>['node'];
    for (final c in candidates) {
      try {
        final r = await Process.run(
          c,
          ['--version'],
          runInShell: Platform.isWindows,
        );
        if (r.exitCode == 0) {
          final ver = (r.stdout as String).trim();
          // mcp-proxy ≥5.1 and Workspace MCP need Node ≥20 (global crypto).
          final m = RegExp(r'v?(\d+)').firstMatch(ver);
          final major = int.tryParse(m?.group(1) ?? '') ?? 0;
          if (major >= 20) return c;
        }
      } catch (_) {}
    }
    final which = Platform.isWindows ? 'where' : 'which';
    try {
      final r = await Process.run(which, ['node'], runInShell: Platform.isWindows);
      if (r.exitCode == 0) {
        final line = (r.stdout as String).trim().split('\n').first.trim();
        if (line.isNotEmpty) {
          final v = await Process.run(line, ['--version']);
          final ver = (v.stdout as String).trim();
          final m = RegExp(r'v?(\d+)').firstMatch(ver);
          final major = int.tryParse(m?.group(1) ?? '') ?? 0;
          if (major >= 20) return line;
        }
      }
    } catch (_) {}
    throw StateError(
      'Node.js ≥20 required for local MCP packages (found older or missing). '
      'Install Node 20+ and ensure it is first on PATH.',
    );
  }

  Future<String> _resolvePython() async {
    final candidates = Platform.isWindows
        ? <String>['python', 'python3', 'py']
        : <String>['python3', 'python'];
    for (final c in candidates) {
      try {
        final r = await Process.run(
          c,
          ['--version'],
          runInShell: Platform.isWindows,
        );
        if (r.exitCode == 0) return c;
      } catch (_) {}
    }
    throw StateError(
      'python not found — install Python to tunnel python-module MCPs',
    );
  }
}

class _McpInstance {
  _McpInstance({required this.alias, required this.port, required this.process});

  final String alias;
  final int port;
  final Process? process;
  final log = StringBuffer();
}

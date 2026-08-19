/// Build wheel+manifest zip bundles for AO custom-tool sandbox upload.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'custom_tool_contract.dart';

class CustomToolBundle {
  CustomToolBundle({
    required this.manifest,
    required this.zipBytes,
    required this.wheelSha256,
    required this.zipSha256,
  });

  final CustomToolManifest manifest;
  final List<int> zipBytes;
  final String wheelSha256;
  final String zipSha256;
}

Future<String> _resolvePythonExecutable() async {
  for (final cmd in ['python', 'python3', 'py']) {
    try {
      final args = cmd == 'py' ? ['-3', '--version'] : ['--version'];
      final result = await Process.run(cmd, args, runInShell: true);
      if (result.exitCode == 0) return cmd;
    } catch (_) {
      continue;
    }
  }
  throw CustomToolContractError('python not found on PATH for pip wheel');
}

Future<File> buildWheel({
  required Directory projectDir,
  Directory? outDir,
}) async {
  final pyproject = File('${projectDir.path}/pyproject.toml');
  if (!await pyproject.exists()) {
    throw CustomToolContractError('no pyproject.toml in ${projectDir.path}');
  }
  final python = await _resolvePythonExecutable();
  final dest = outDir ?? await Directory.systemTemp.createTemp('ao-reach-wheel-');
  final pipArgs = python == 'py'
      ? ['-3', '-m', 'pip', 'wheel', projectDir.path, '--no-deps', '-w', dest.path]
      : ['-m', 'pip', 'wheel', projectDir.path, '--no-deps', '-w', dest.path];
  final result = await Process.run(python, pipArgs, runInShell: true);
  if (result.exitCode != 0) {
    throw CustomToolContractError(
      'pip wheel failed:\n${result.stdout}\n${result.stderr}',
    );
  }
  final wheels = dest
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.whl'))
      .toList();
  if (wheels.isEmpty) {
    throw CustomToolContractError('pip wheel produced no .whl in ${dest.path}');
  }
  wheels.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return wheels.first;
}

List<int> buildBundleZip({
  required Map<String, dynamic> manifest,
  required File wheelFile,
}) {
  validateManifestMap(manifest);
  final parsed = CustomToolManifest.fromJson(manifest);
  if (wheelFile.path.split(Platform.pathSeparator).last != parsed.wheel) {
    throw CustomToolContractError(
      'wheel filename ${wheelFile.uri.pathSegments.last} '
      'does not match manifest.wheel ${parsed.wheel}',
    );
  }

  final archive = Archive()
    ..addFile(
      ArchiveFile(
        'manifest.json',
        utf8.encode(parsed.toJsonString()).length,
        utf8.encode(parsed.toJsonString()),
      ),
    )
    ..addFile(
      ArchiveFile(
        parsed.wheel,
        wheelFile.lengthSync(),
        wheelFile.readAsBytesSync(),
      ),
    );
  return ZipEncoder().encode(archive);
}

Future<CustomToolBundle> packageCustomTool({
  Map<String, dynamic>? manifest,
  File? manifestFile,
  File? wheelFile,
  Directory? projectDir,
}) async {
  late Map<String, dynamic> data;
  if (manifest != null) {
    data = Map<String, dynamic>.from(manifest);
  } else if (manifestFile != null) {
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map) {
      throw CustomToolContractError('manifest file must contain a JSON object');
    }
    data = Map<String, dynamic>.from(decoded);
  } else {
    throw CustomToolContractError('manifest or manifestFile is required');
  }

  File? wheel = wheelFile;
  if (wheel == null && projectDir != null) {
    wheel = await buildWheel(projectDir: projectDir);
  }
  if (wheel == null) {
    final wheelName = (data['wheel'] ?? '').toString().trim();
    if (manifestFile != null && wheelName.isNotEmpty) {
      final candidate = File('${manifestFile.parent.path}/$wheelName');
      if (await candidate.exists()) wheel = candidate;
    }
  }
  if (wheel == null) {
    throw CustomToolContractError('wheelFile or projectDir is required');
  }

  final zipBytes = buildBundleZip(manifest: data, wheelFile: wheel);
  final parsed = CustomToolManifest.fromJson(data);
  final wheelHash = sha256.convert(await wheel.readAsBytes()).toString();
  final zipHash = sha256.convert(zipBytes).toString();
  return CustomToolBundle(
    manifest: parsed,
    zipBytes: zipBytes,
    wheelSha256: wheelHash,
    zipSha256: zipHash,
  );
}

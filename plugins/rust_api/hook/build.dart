import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets) return const {};
  final code = input.config.code;
  if (code.targetOS == OS.iOS) {
    final os = code.iOS;
    final simulator = os.targetSdk == IOSSdk.iPhoneSimulator;
    final sdk = _xcrun([
      '--sdk',
      simulator ? 'iphonesimulator' : 'iphoneos',
      '--show-sdk-path',
    ]);
    final clang = File(_xcrun(['--find', 'clang']));
    final deployment =
        Platform.environment['IPHONEOS_DEPLOYMENT_TARGET'] ??
        '${os.targetVersion}.0';
    final triple = 'arm64-apple-ios$deployment${simulator ? '-simulator' : ''}';
    return {
      'LIBCLANG_PATH': '${clang.parent.parent.path}/lib',
      'BINDGEN_EXTRA_CLANG_ARGS': '-isysroot "$sdk" --target=$triple',
    };
  }
  if (code.targetOS != OS.android) return const {};
  final compiler = code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final llvmRoot = File.fromUri(compiler).parent.parent;
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return {'LIBCLANG_PATH': directory.path};
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

String _xcrun(List<String> arguments) {
  final process = Process.runSync('/usr/bin/xcrun', arguments);
  if (process.exitCode != 0) {
    throw StateError('xcrun ${arguments.join(' ')}: ${process.stderr}');
  }
  return (process.stdout as String).trim();
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}

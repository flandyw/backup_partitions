import 'dart:io';

import 'process_runner.dart';

class AdbDevice {
  const AdbDevice({required this.serial, required this.state});

  final String serial;
  final String state;

  bool get isAuthorized => state == 'device';
}

class AdbService {
  AdbService({ProcessRunner? runner}) : _runner = runner ?? const SystemProcessRunner();

  final ProcessRunner _runner;

  Future<String> version() async {
    final result = await _runner.run('adb', ['version']);
    _ensureSuccess(result, 'Unable to run adb');
    return result.stdout.toString().trim().split('\n').first;
  }

  Future<List<AdbDevice>> listDevices() async {
    final result = await _runner.run('adb', ['devices']);
    _ensureSuccess(result, 'Unable to enumerate ADB devices');

    return result.stdout
        .toString()
        .split('\n')
        .skip(1)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) {
          final parts = line.split(RegExp(r'\s+'));
          return AdbDevice(
            serial: parts.first,
            state: parts.length > 1 ? parts[1] : 'unknown',
          );
        })
        .toList();
  }

  Future<String> getProp(String serial, String key) async {
    final result = await runForDevice(serial, ['shell', 'getprop', key]);
    _ensureSuccess(result, 'Unable to read $key');
    return result.stdout.toString().trim();
  }

  Future<bool> hasRoot(String serial) async {
    final result = await runRoot(serial, 'id');
    return result.exitCode == 0 && result.stdout.toString().contains('uid=0');
  }

  Future<String?> findPartitionDirectory(String serial) async {
    const candidates = [
      '/dev/block/bootdevice/by-name',
      '/dev/block/by-name',
      '/dev/block/platform/bootdevice/by-name',
    ];

    for (final candidate in candidates) {
      final result = await runRoot(
        serial,
        'test -d "$candidate" && echo ok',
      );
      if (result.exitCode == 0 && result.stdout.toString().trim() == 'ok') {
        return candidate;
      }
    }
    return null;
  }

  Future<List<String>> listPartitions(String serial, String directory) async {
    final result = await runRoot(serial, 'ls -1 "$directory"');
    _ensureSuccess(result, 'Unable to list partitions');
    final validName = RegExp(r'^[A-Za-z0-9._-]+$');
    return result.stdout
        .toString()
        .split('\n')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && validName.hasMatch(value))
        .toList()
      ..sort();
  }

  Future<int> partitionSize(String serial, String sourcePath) async {
    final result = await runRoot(
      serial,
      'blockdev --getsize64 "$sourcePath"',
    );
    _ensureSuccess(result, 'Unable to determine partition size');
    final size = int.tryParse(result.stdout.toString().trim());
    if (size == null || size <= 0) {
      throw const CommandFailure('Device returned an invalid partition size.');
    }
    return size;
  }

  Future<void> createPartitionImage(
    String serial,
    String sourcePath,
    String remotePath,
  ) async {
    final result = await runRoot(
      serial,
      'dd if="$sourcePath" of="$remotePath" bs=4M',
    );
    _ensureSuccess(result, 'dd failed while creating the partition image');

    final chmod = await runRoot(serial, 'chmod 0644 "$remotePath"');
    _ensureSuccess(chmod, 'Unable to make the temporary image readable by ADB');
  }

  Future<ProcessResult> pull(
    String serial,
    String remotePath,
    String localPath,
  ) {
    return runForDevice(serial, ['pull', remotePath, localPath]);
  }

  Future<void> removeRemote(String serial, String remotePath) async {
    final result = await runRoot(serial, 'rm -f "$remotePath"');
    _ensureSuccess(result, 'Unable to remove temporary device image');
  }

  Future<ProcessResult> runForDevice(String serial, List<String> arguments) {
    return _runner.run('adb', ['-s', serial, ...arguments]);
  }

  Future<ProcessResult> runRoot(String serial, String command) {
    return runForDevice(serial, ['shell', 'su', '-c', command]);
  }

  void _ensureSuccess(ProcessResult result, String message) {
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw CommandFailure(stderr.isEmpty ? message : '$message: $stderr');
    }
  }
}

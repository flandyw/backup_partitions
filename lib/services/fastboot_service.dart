import 'dart:io';

import 'process_runner.dart';

class FastbootDevice {
  const FastbootDevice(this.serial);

  final String serial;
}

class FastbootService {
  FastbootService({ProcessRunner? runner}) : _runner = runner ?? const SystemProcessRunner();

  final ProcessRunner _runner;

  Future<String> version() async {
    final result = await _runner.run('fastboot', ['--version']);
    _ensureSuccess(result, 'Unable to run fastboot');
    return result.stdout.toString().trim().split('\n').first;
  }

  Future<List<FastbootDevice>> listDevices() async {
    final result = await _runner.run('fastboot', ['devices']);
    _ensureSuccess(result, 'Unable to enumerate fastboot devices');
    return result.stdout
        .toString()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => FastbootDevice(line.split(RegExp(r'\s+')).first))
        .toList();
  }

  Future<String> getVar(String serial, String name) async {
    final result = await runForDevice(serial, ['getvar', name]);
    _ensureSuccess(result, 'Unable to read fastboot variable $name');
    final combined = '${result.stdout}\n${result.stderr}';
    for (final line in combined.split('\n')) {
      final trimmed = line.trim();
      final prefix = '$name:';
      if (trimmed.startsWith(prefix)) {
        return trimmed.substring(prefix.length).trim();
      }
    }
    throw CommandFailure('Fastboot did not return $name.');
  }

  Future<ProcessResult> flash(String serial, String partition, String imagePath) async {
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(partition)) {
      throw const CommandFailure('Invalid partition name.');
    }
    if (!await File(imagePath).exists()) {
      throw CommandFailure('Image does not exist: $imagePath');
    }
    final result = await runForDevice(serial, ['flash', partition, imagePath]);
    _ensureSuccess(result, 'Failed to flash $partition');
    return result;
  }

  Future<ProcessResult> wipe(String serial) async {
    final result = await runForDevice(serial, ['-w']);
    _ensureSuccess(result, 'Fastboot wipe failed');
    return result;
  }

  Future<ProcessResult> lockBootloader(String serial) async {
    final result = await runForDevice(serial, ['flashing', 'lock']);
    _ensureSuccess(result, 'Bootloader lock failed');
    return result;
  }

  Future<ProcessResult> unlockBootloader(String serial) async {
    final result = await runForDevice(serial, ['flashing', 'unlock']);
    _ensureSuccess(result, 'Bootloader unlock failed');
    return result;
  }

  Future<ProcessResult> rebootFastbootd(String serial) async {
    final result = await runForDevice(serial, ['reboot', 'fastboot']);
    _ensureSuccess(result, 'Unable to reboot to fastbootd');
    return result;
  }

  Future<ProcessResult> runForDevice(String serial, List<String> arguments) {
    return _runner.run('fastboot', ['-s', serial, ...arguments]);
  }

  void _ensureSuccess(ProcessResult result, String message) {
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw CommandFailure(stderr.isEmpty ? message : '$message: $stderr');
    }
  }
}

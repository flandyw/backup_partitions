import 'package:backup_partitions/services/adb_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_process_runner.dart';

void main() {
  test('listDevices parses authorized and unauthorized devices', () async {
    final runner = FakeProcessRunner([
      fakeResult(
        stdout: 'List of devices attached\nABC123\tdevice\nDEF456\tunauthorized\n\n',
      ),
    ]);
    final service = AdbService(runner: runner);

    final devices = await service.listDevices();

    expect(devices, hasLength(2));
    expect(devices[0].serial, 'ABC123');
    expect(devices[0].isAuthorized, isTrue);
    expect(devices[1].serial, 'DEF456');
    expect(devices[1].state, 'unauthorized');
  });

  test('device commands are scoped to the requested serial', () async {
    final runner = FakeProcessRunner([
      fakeResult(stdout: 'Pixel 8\n'),
    ]);
    final service = AdbService(runner: runner);

    final model = await service.getProp('ABC123', 'ro.product.model');

    expect(model, 'Pixel 8');
    expect(runner.commands.single.executable, 'adb');
    expect(
      runner.commands.single.arguments,
      ['-s', 'ABC123', 'shell', 'getprop', 'ro.product.model'],
    );
  });

  test('partition directory probing falls back to supported layouts', () async {
    final runner = FakeProcessRunner([
      fakeResult(exitCode: 1, stderr: 'missing'),
      fakeResult(stdout: 'ok\n'),
    ]);
    final service = AdbService(runner: runner);

    final directory = await service.findPartitionDirectory('ABC123');

    expect(directory, '/dev/block/by-name');
    expect(runner.commands, hasLength(2));
    expect(runner.commands[0].arguments.take(4), ['-s', 'ABC123', 'shell', 'su']);
    expect(runner.commands[1].arguments.last, contains('/dev/block/by-name'));
  });
}

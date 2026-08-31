import 'package:backup_partitions/services/fastboot_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_process_runner.dart';

void main() {
  test('getVar parses values emitted on stderr', () async {
    final runner = FakeProcessRunner([
      fakeResult(stderr: 'product: panther\nFinished. Total time: 0.001s\n'),
    ]);
    final service = FastbootService(runner: runner);

    final product = await service.getVar('ABC123', 'product');

    expect(product, 'panther');
    expect(
      runner.commands.single.arguments,
      ['-s', 'ABC123', 'getvar', 'product'],
    );
  });

  test('wipe is scoped to the selected serial', () async {
    final runner = FakeProcessRunner([
      fakeResult(stdout: 'wiping userdata\n'),
    ]);
    final service = FastbootService(runner: runner);

    await service.wipe('ABC123');

    expect(runner.commands.single.executable, 'fastboot');
    expect(runner.commands.single.arguments, ['-s', 'ABC123', '-w']);
  });

  test('listDevices extracts fastboot serials', () async {
    final runner = FakeProcessRunner([
      fakeResult(stdout: 'ABC123\tfastboot\nDEF456\tfastboot\n'),
    ]);
    final service = FastbootService(runner: runner);

    final devices = await service.listDevices();

    expect(devices.map((device) => device.serial), ['ABC123', 'DEF456']);
  });
}

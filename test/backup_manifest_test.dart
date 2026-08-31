import 'dart:io';

import 'package:backup_partitions/models/backup_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manifest round-trips and detects image corruption', () async {
    final directory = await Directory.systemTemp.createTemp('backup_partitions_test_');
    addTearDown(() => directory.delete(recursive: true));

    final image = File('${directory.path}${Platform.pathSeparator}boot.img');
    await image.writeAsBytes([1, 2, 3, 4, 5], flush: true);
    final hash = await sha256File(image);

    final manifest = BackupManifest(
      createdAt: DateTime.utc(2026, 8, 31),
      serial: 'ABC123',
      model: 'Pixel',
      manufacturer: 'Google',
      brand: 'google',
      device: 'panther',
      product: 'panther',
      fingerprint: 'google/panther/test',
      androidVersion: '16',
      slot: 'a',
      partitionDirectory: '/dev/block/by-name',
      partitions: [
        PartitionBackup(
          name: 'boot',
          file: 'boot.img',
          size: await image.length(),
          sha256: hash,
        ),
      ],
    );

    await manifest.writeTo(directory);
    final loaded = await BackupManifest.readFrom(directory);

    expect(loaded, isNotNull);
    expect(loaded!.serial, 'ABC123');
    expect(loaded.partitions.single.name, 'boot');
    expect(await loaded.partitions.single.verify(directory), isTrue);

    await image.writeAsBytes([9, 9, 9], flush: true);
    expect(await loaded.partitions.single.verify(directory), isFalse);
  });
}

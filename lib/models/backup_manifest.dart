import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

Future<String> sha256File(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

class PartitionBackup {
  const PartitionBackup({
    required this.name,
    required this.file,
    required this.size,
    required this.sha256,
  });

  final String name;
  final String file;
  final int size;
  final String sha256;

  Map<String, Object> toJson() => {
        'name': name,
        'file': file,
        'size': size,
        'sha256': sha256,
      };

  factory PartitionBackup.fromJson(Map<String, dynamic> json) {
    return PartitionBackup(
      name: json['name'] as String,
      file: json['file'] as String,
      size: json['size'] as int,
      sha256: json['sha256'] as String,
    );
  }

  Future<bool> verify(Directory directory) async {
    final image = File(path.join(directory.path, file));
    if (!await image.exists() || await image.length() != size) {
      return false;
    }
    return await sha256File(image) == sha256;
  }
}

class BackupManifest {
  const BackupManifest({
    required this.createdAt,
    required this.serial,
    required this.model,
    required this.manufacturer,
    required this.brand,
    required this.device,
    required this.product,
    required this.fingerprint,
    required this.androidVersion,
    required this.slot,
    required this.partitionDirectory,
    required this.partitions,
  });

  static const fileName = 'backup_manifest.json';
  static const schemaVersion = 1;

  final DateTime createdAt;
  final String serial;
  final String model;
  final String manufacturer;
  final String brand;
  final String device;
  final String product;
  final String fingerprint;
  final String androidVersion;
  final String slot;
  final String partitionDirectory;
  final List<PartitionBackup> partitions;

  Map<String, Object> toJson() => {
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'serial': serial,
        'model': model,
        'manufacturer': manufacturer,
        'brand': brand,
        'device': device,
        'product': product,
        'fingerprint': fingerprint,
        'androidVersion': androidVersion,
        'slot': slot,
        'partitionDirectory': partitionDirectory,
        'partitions': partitions.map((entry) => entry.toJson()).toList(),
      };

  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    final schema = json['schemaVersion'] as int?;
    if (schema != schemaVersion) {
      throw const FormatException('Unsupported backup manifest version.');
    }

    return BackupManifest(
      createdAt: DateTime.parse(json['createdAt'] as String),
      serial: json['serial'] as String,
      model: json['model'] as String,
      manufacturer: json['manufacturer'] as String,
      brand: json['brand'] as String,
      device: json['device'] as String,
      product: json['product'] as String,
      fingerprint: json['fingerprint'] as String,
      androidVersion: json['androidVersion'] as String,
      slot: json['slot'] as String,
      partitionDirectory: json['partitionDirectory'] as String,
      partitions: (json['partitions'] as List<dynamic>)
          .map((entry) => PartitionBackup.fromJson(entry as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<void> writeTo(Directory directory) async {
    final file = File(path.join(directory.path, fileName));
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(toJson())}\n', flush: true);
  }

  static Future<BackupManifest?> readFrom(Directory directory) async {
    final file = File(path.join(directory.path, fileName));
    if (!await file.exists()) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString());
    return BackupManifest.fromJson(decoded as Map<String, dynamic>);
  }
}

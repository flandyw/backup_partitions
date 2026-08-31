import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import 'models/backup_manifest.dart';
import 'services/adb_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.adbService,
    this.autoInitialize = true,
  });

  final AdbService? adbService;
  final bool autoInitialize;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AdbService _adb;
  final TextEditingController outputController = TextEditingController();

  Map<String, String> info = {};
  List<AdbDevice> devices = [];
  List<String> partitions = [];
  List<String> selectedPartitions = [];
  String? selectedSerial;
  String? partitionDirectory;
  String saveFolder = '';
  String filter = '';
  String adbVersion = '';
  bool backupInProgress = false;
  bool initializing = false;

  bool get busy => backupInProgress || initializing;

  @override
  void initState() {
    super.initState();
    _adb = widget.adbService ?? AdbService();
    if (widget.autoInitialize) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
    }
  }

  @override
  void dispose() {
    outputController.dispose();
    super.dispose();
  }

  void _appendOutput(String message) {
    outputController.text += message.endsWith('\n') ? message : '$message\n';
  }

  Future<void> _showMessage(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _initialize() async {
    if (initializing) return;
    setState(() => initializing = true);
    try {
      final version = await _adb.version();
      _appendOutput('ADB found.');
      if (mounted) {
        setState(() => adbVersion = version);
      }
      await _refreshDevices();
    } on ProcessException catch (error) {
      _appendOutput('ADB not found: $error');
      await _showMessage(
        'ADB Not Found',
        'Install Android platform-tools and ensure adb is available in PATH.',
      );
    } catch (error) {
      _appendOutput('Initialization failed: $error');
      await _showMessage('Initialization Failed', error.toString());
    } finally {
      if (mounted) {
        setState(() => initializing = false);
      }
    }
  }

  Future<void> _refreshDevices() async {
    final discovered = await _adb.listDevices();
    final authorized = discovered.where((device) => device.isAuthorized).toList();
    final unauthorized = discovered.where((device) => device.state == 'unauthorized').toList();

    if (mounted) {
      setState(() => devices = discovered);
    }

    if (unauthorized.isNotEmpty) {
      await _showMessage(
        'Unauthorized Device',
        'Authorize USB debugging on ${unauthorized.first.serial}, then refresh.',
      );
    }

    if (authorized.isEmpty) {
      if (mounted) {
        setState(() {
          selectedSerial = null;
          partitionDirectory = null;
          partitions = [];
          selectedPartitions = [];
          info = {};
        });
      }
      if (discovered.isEmpty) {
        await _showMessage('No Device Found', 'Connect an Android device and try again.');
      }
      return;
    }

    String? serial = selectedSerial;
    if (serial == null || !authorized.any((device) => device.serial == serial)) {
      serial = authorized.length == 1 ? authorized.first.serial : null;
    }

    if (mounted) {
      setState(() => selectedSerial = serial);
    }

    if (serial == null) {
      _appendOutput('Multiple authorized devices found. Select a target device.');
      return;
    }

    await _loadDevice(serial);
  }

  Future<void> _selectDevice(String serial) async {
    if (busy) return;
    setState(() {
      selectedSerial = serial;
      partitions = [];
      selectedPartitions = [];
      partitionDirectory = null;
      info = {};
    });
    try {
      await _loadDevice(serial);
    } catch (error) {
      _appendOutput('Unable to load device $serial: $error');
      await _showMessage('Device Error', error.toString());
    }
  }

  Future<void> _loadDevice(String serial) async {
    _appendOutput('Getting device info for $serial...');

    final nextInfo = <String, String>{
      'Serial': serial,
      'Model': await _adb.getProp(serial, 'ro.product.model'),
      'Manufacturer': await _adb.getProp(serial, 'ro.product.manufacturer'),
      'Brand': await _adb.getProp(serial, 'ro.product.brand'),
      'Device': await _adb.getProp(serial, 'ro.product.device'),
      'Product': await _adb.getProp(serial, 'ro.product.name'),
      'Arch': await _adb.getProp(serial, 'ro.product.cpu.abi'),
      'Android Version': await _adb.getProp(serial, 'ro.build.version.release'),
      'Fingerprint': await _adb.getProp(serial, 'ro.build.fingerprint'),
    };

    final slot = await _adb.getProp(serial, 'ro.boot.slot_suffix');
    nextInfo['Slot'] = slot.replaceFirst(RegExp(r'^_'), '');

    _appendOutput('Checking root access...');
    final rooted = await _adb.hasRoot(serial);
    nextInfo['Root'] = rooted ? 'Yes' : 'No';

    if (!rooted) {
      if (mounted) {
        setState(() {
          info = nextInfo;
          partitionDirectory = null;
          partitions = [];
          selectedPartitions = [];
        });
      }
      await _showMessage(
        'Root Required',
        'Root access for the ADB shell is required to read raw partitions.',
      );
      return;
    }

    final directory = await _adb.findPartitionDirectory(serial);
    if (directory == null) {
      throw const FileSystemException(
        'No supported by-name partition directory was found on the device.',
      );
    }

    final availablePartitions = await _adb.listPartitions(serial, directory);
    nextInfo['Partition Directory'] = directory;
    if (saveFolder.isNotEmpty) {
      nextInfo['Backup Folder'] = saveFolder;
    }

    if (mounted) {
      setState(() {
        info = nextInfo;
        partitionDirectory = directory;
        partitions = availablePartitions;
        selectedPartitions = selectedPartitions
            .where(availablePartitions.contains)
            .toList(growable: true);
      });
    }
    _appendOutput('Root access granted. ${availablePartitions.length} partitions found.');
  }

  Future<void> _replaceVerifiedImage(File partial, File destination) async {
    File? previous;
    if (await destination.exists()) {
      previous = File('${destination.path}.previous');
      if (await previous.exists()) {
        await previous.delete();
      }
      await destination.rename(previous.path);
    }

    try {
      await partial.rename(destination.path);
      if (previous != null && await previous.exists()) {
        await previous.delete();
      }
    } catch (_) {
      if (previous != null && await previous.exists() && !await destination.exists()) {
        await previous.rename(destination.path);
      }
      rethrow;
    }
  }

  Future<void> backupSelected() async {
    final serial = selectedSerial;
    final byNameDirectory = partitionDirectory;

    if (serial == null || byNameDirectory == null) {
      await _showMessage('Device Required', 'Select a rooted device before backing up.');
      return;
    }
    if (saveFolder.isEmpty || !Directory(saveFolder).existsSync()) {
      await _showMessage('Backup Folder Required', 'Select a valid backup folder first.');
      return;
    }
    if (selectedPartitions.isEmpty) return;

    final destinationDirectory = Directory(saveFolder);
    final successful = <PartitionBackup>[];
    final selections = List<String>.of(selectedPartitions);
    final validName = RegExp(r'^[A-Za-z0-9._-]+$');

    setState(() => backupInProgress = true);
    try {
      for (final rawPartition in selections) {
        final partition = rawPartition.trim();
        if (partition == 'userdata') {
          _appendOutput('Skipping userdata partition.');
          continue;
        }
        if (!validName.hasMatch(partition)) {
          _appendOutput('Skipping invalid partition name: $partition');
          continue;
        }

        final sourcePath = '$byNameDirectory/$partition';
        final remotePath = '/data/local/tmp/backup_partitions_$partition.img';
        final finalImage = File(path.join(saveFolder, '$partition.img'));
        final partialImage = File('${finalImage.path}.partial');
        var remoteCreated = false;

        _appendOutput('Backing up $partition.img...');
        try {
          if (await partialImage.exists()) {
            await partialImage.delete();
          }

          final expectedSize = await _adb.partitionSize(serial, sourcePath);
          await _adb.createPartitionImage(serial, sourcePath, remotePath);
          remoteCreated = true;

          final pullResult = await _adb.pull(serial, remotePath, partialImage.path);
          if (pullResult.stderr.toString().trim().isNotEmpty) {
            _appendOutput(pullResult.stderr.toString().trim());
          }
          if (pullResult.exitCode != 0) {
            throw FileSystemException(
              'adb pull failed: ${pullResult.stderr.toString().trim()}',
            );
          }
          if (!await partialImage.exists()) {
            throw const FileSystemException('adb pull completed without creating a local image.');
          }

          final actualSize = await partialImage.length();
          if (actualSize != expectedSize) {
            throw FileSystemException(
              'Size verification failed for $partition: expected $expectedSize bytes, got $actualSize.',
            );
          }

          final hash = await sha256File(partialImage);
          await _replaceVerifiedImage(partialImage, finalImage);
          successful.add(
            PartitionBackup(
              name: partition,
              file: path.basename(finalImage.path),
              size: actualSize,
              sha256: hash,
            ),
          );

          try {
            await _adb.removeRemote(serial, remotePath);
            remoteCreated = false;
          } catch (error) {
            _appendOutput('Backup verified, but temporary cleanup failed: $error');
          }

          _appendOutput('Backup of $partition.img verified successfully.');
        } catch (error) {
          if (await partialImage.exists()) {
            await partialImage.delete();
          }
          _appendOutput('Backup of $partition.img failed: $error');
          if (remoteCreated) {
            _appendOutput('The temporary image was retained at $remotePath for recovery.');
          }
        }
      }

      if (successful.isNotEmpty) {
        final manifest = BackupManifest(
          createdAt: DateTime.now(),
          serial: serial,
          model: info['Model'] ?? '',
          manufacturer: info['Manufacturer'] ?? '',
          brand: info['Brand'] ?? '',
          device: info['Device'] ?? '',
          product: info['Product'] ?? '',
          fingerprint: info['Fingerprint'] ?? '',
          androidVersion: info['Android Version'] ?? '',
          slot: info['Slot'] ?? '',
          partitionDirectory: byNameDirectory,
          partitions: successful,
        );
        await manifest.writeTo(destinationDirectory);
        _appendOutput('Wrote ${BackupManifest.fileName} for ${successful.length} verified backups.');
      }
    } finally {
      if (mounted) {
        setState(() => backupInProgress = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredPartitions = partitions
        .where((partition) => partition.toLowerCase().contains(filter.toLowerCase()))
        .toList();
    final authorizedDevices = devices.where((device) => device.isAuthorized).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Partition Backup${adbVersion.isEmpty ? '' : ' - $adbVersion'}',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('About this app'),
                  content: const Text('Partition Backup\n(c) 2024 Andrew Wang.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('OK'),
                    ),
                    TextButton(
                      onPressed: () => launchUrl(
                        Uri.parse('https://github.com/flandyw/backup_partitions'),
                      ),
                      child: const Text('GitHub'),
                    ),
                  ],
                ),
              );
            },
            icon: const Icon(Icons.info),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  onPressed: busy ? null : _initialize,
                  child: const Text('Refresh'),
                ),
                if (authorizedDevices.isNotEmpty)
                  DropdownButton<String>(
                    value: selectedSerial,
                    hint: const Text('Select device'),
                    items: authorizedDevices
                        .map(
                          (device) => DropdownMenuItem(
                            value: device.serial,
                            child: Text(device.serial),
                          ),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value != null) _selectDevice(value);
                          },
                  ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final selectedDirectory = await FilePicker.platform.getDirectoryPath();
                          if (selectedDirectory == null) return;
                          setState(() {
                            saveFolder = selectedDirectory;
                            info = Map<String, String>.of(info)
                              ..['Backup Folder'] = selectedDirectory;
                          });
                        },
                  child: const Text('Browse Backup Folder'),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => selectedPartitions = <String>[]),
                  child: const Text('Clear Selection'),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => setState(
                            () => selectedPartitions = List<String>.of(partitions),
                          ),
                  child: const Text('Select All'),
                ),
                if (selectedPartitions.isNotEmpty)
                  FilledButton(
                    onPressed: busy ? null : backupSelected,
                    child: const Text('Backup Selected'),
                  ),
                FilledButton(
                  onPressed: busy ? null : () => Navigator.pushNamed(context, '/flash'),
                  child: const Text('Flash Partitions'),
                ),
                ElevatedButton(
                  onPressed: () => outputController.clear(),
                  child: const Text('Clear Output'),
                ),
              ],
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              onChanged: (value) => setState(() => filter = value),
              decoration: InputDecoration(
                hintText: 'Search partitions...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _ListPanel(
                    title: 'Device Info',
                    child: ListView(
                      children: info.entries
                          .map(
                            (entry) => ListTile(
                              title: Text(entry.key),
                              subtitle: Text(entry.value),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
                Expanded(
                  child: _ListPanel(
                    title: 'Available Partitions',
                    child: ListView.builder(
                      itemCount: filteredPartitions.length,
                      itemBuilder: (context, index) {
                        final partition = filteredPartitions[index];
                        return CheckboxListTile(
                          value: selectedPartitions.contains(partition),
                          title: Text(partition),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: busy
                              ? null
                              : (value) {
                                  setState(() {
                                    if (value == true) {
                                      if (!selectedPartitions.contains(partition)) {
                                        selectedPartitions.add(partition);
                                      }
                                    } else {
                                      selectedPartitions.remove(partition);
                                    }
                                  });
                                },
                        );
                      },
                    ),
                  ),
                ),
                Expanded(
                  child: _ListPanel(
                    title: 'Selected Partitions',
                    child: ListView.builder(
                      itemCount: selectedPartitions.length,
                      itemBuilder: (context, index) => ListTile(
                        title: Text(selectedPartitions[index]),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: _ListPanel(
                    title: 'Output',
                    child: TextField(
                      controller: outputController,
                      readOnly: true,
                      expands: true,
                      minLines: null,
                      maxLines: null,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _ListPanel extends StatelessWidget {
  const _ListPanel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

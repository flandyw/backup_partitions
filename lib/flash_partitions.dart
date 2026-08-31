import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'models/backup_manifest.dart';
import 'services/fastboot_service.dart';

class FlashPartitions extends StatefulWidget {
  const FlashPartitions({
    super.key,
    this.fastbootService,
    this.autoInitialize = true,
  });

  final FastbootService? fastbootService;
  final bool autoInitialize;

  @override
  State<FlashPartitions> createState() => _FlashPartitionsState();
}

class _FlashPartitionsState extends State<FlashPartitions> {
  late final FastbootService _fastboot;
  final TextEditingController outputController = TextEditingController();

  Directory? backupFolder;
  BackupManifest? manifest;
  List<FastbootDevice> devices = [];
  String? selectedSerial;
  String fastbootProduct = 'Unknown';
  String fastbootSlot = 'Unknown';
  String fastbootVersion = '';
  bool operating = false;

  @override
  void initState() {
    super.initState();
    _fastboot = widget.fastbootService ?? FastbootService();
    if (widget.autoInitialize) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDevices());
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

  void _logResult(ProcessResult result) {
    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();
    if (stdout.isNotEmpty) _appendOutput(stdout);
    if (stderr.isNotEmpty) _appendOutput(stderr);
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

  Future<bool> _confirmDestructive({
    required String title,
    required String message,
    required String phrase,
  }) async {
    if (!mounted) return false;
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message),
                const SizedBox(height: 16),
                Text('Type "$phrase" to continue.'),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (controller.text.trim() == phrase) {
                    Navigator.pop(context, true);
                  }
                },
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;
    controller.dispose();
    return confirmed;
  }

  Future<void> _refreshDevices() async {
    if (operating) return;
    setState(() => operating = true);
    try {
      fastbootVersion = await _fastboot.version();
      final discovered = await _fastboot.listDevices();
      var serial = selectedSerial;
      if (serial == null || !discovered.any((device) => device.serial == serial)) {
        serial = discovered.length == 1 ? discovered.first.serial : null;
      }

      if (mounted) {
        setState(() {
          devices = discovered;
          selectedSerial = serial;
        });
      }

      if (discovered.isEmpty) {
        await _showMessage(
          'No Fastboot Device',
          'Connect a device in the bootloader/fastboot interface and refresh.',
        );
        return;
      }
      if (serial == null) {
        _appendOutput('Multiple fastboot devices found. Select a target device.');
        return;
      }
      await _loadDevice(serial);
    } on ProcessException catch (error) {
      _appendOutput('Fastboot not found: $error');
      await _showMessage(
        'Fastboot Not Found',
        'Install Android platform-tools and ensure fastboot is available in PATH.',
      );
    } catch (error) {
      _appendOutput('Fastboot refresh failed: $error');
      await _showMessage('Fastboot Error', error.toString());
    } finally {
      if (mounted) setState(() => operating = false);
    }
  }

  Future<void> _selectDevice(String serial) async {
    if (operating) return;
    setState(() {
      selectedSerial = serial;
      fastbootProduct = 'Unknown';
      fastbootSlot = 'Unknown';
      operating = true;
    });
    try {
      await _loadDevice(serial);
    } catch (error) {
      _appendOutput('Unable to inspect $serial: $error');
      await _showMessage('Fastboot Device Error', error.toString());
    } finally {
      if (mounted) setState(() => operating = false);
    }
  }

  Future<void> _loadDevice(String serial) async {
    final product = await _fastboot.getVar(serial, 'product');
    var slot = 'Unknown';
    try {
      slot = await _fastboot.getVar(serial, 'current-slot');
    } catch (_) {
      // Non-A/B devices may not expose current-slot.
    }
    if (mounted) {
      setState(() {
        fastbootProduct = product;
        fastbootSlot = slot;
      });
    }
    _appendOutput('Fastboot device $serial: product=$product, slot=$slot');
  }

  Future<void> _selectBackupFolder() async {
    if (operating) return;
    final directoryPath = await FilePicker.platform.getDirectoryPath();
    if (directoryPath == null) return;

    final directory = Directory(directoryPath);
    try {
      final loaded = await BackupManifest.readFrom(directory);
      if (loaded == null) {
        await _showMessage(
          'Invalid Backup Folder',
          'This folder does not contain ${BackupManifest.fileName}. Restore is disabled for unverified image folders.',
        );
        return;
      }
      if (loaded.partitions.isEmpty) {
        throw const FormatException('The backup manifest contains no partitions.');
      }
      if (mounted) {
        setState(() {
          backupFolder = directory;
          manifest = loaded;
        });
      }
      _appendOutput(
        'Loaded verified backup manifest for ${loaded.model} (${loaded.serial}) with ${loaded.partitions.length} partitions.',
      );
    } catch (error) {
      await _showMessage('Invalid Backup Manifest', error.toString());
    }
  }

  Future<List<String>> _compatibilityIssues() async {
    final loaded = manifest;
    final serial = selectedSerial;
    final issues = <String>[];
    if (loaded == null || serial == null) return ['Backup or target device is missing.'];

    if (serial != loaded.serial) {
      issues.add('Backup serial ${loaded.serial} does not match target serial $serial.');
    }

    try {
      final product = await _fastboot.getVar(serial, 'product');
      if (mounted) setState(() => fastbootProduct = product);
      final expectedProducts = {loaded.device, loaded.product}.where((value) => value.isNotEmpty).toSet();
      if (expectedProducts.isNotEmpty && !expectedProducts.contains(product)) {
        issues.add(
          'Fastboot product $product does not match backup device/product ${expectedProducts.join(' / ')}.',
        );
      }
    } catch (error) {
      issues.add('Unable to verify fastboot product: $error');
    }
    return issues;
  }

  Future<bool> _verifyEntry(PartitionBackup entry) async {
    final directory = backupFolder;
    if (directory == null) return false;
    _appendOutput('Verifying ${entry.file}...');
    return entry.verify(directory);
  }

  String _compatibilityMessage(List<String> issues) {
    if (issues.isEmpty) {
      return 'The backup manifest matches the selected fastboot device. Flashing raw partitions can still make the device unbootable if interrupted.';
    }
    return 'Compatibility warnings:\n\n${issues.map((issue) => '• $issue').join('\n')}\n\nProceed only if you have independently confirmed that these images belong on this device.';
  }

  Future<void> _flashEntry(PartitionBackup entry) async {
    final directory = backupFolder;
    final serial = selectedSerial;
    if (directory == null || serial == null || operating) return;

    setState(() => operating = true);
    try {
      if (!await _verifyEntry(entry)) {
        throw FileSystemException('Integrity verification failed for ${entry.file}.');
      }
      final issues = await _compatibilityIssues();
      final confirmed = await _confirmDestructive(
        title: 'Flash ${entry.name}',
        message: '${_compatibilityMessage(issues)}\n\nTarget partition: ${entry.name}\nTarget serial: $serial',
        phrase: 'FLASH $serial',
      );
      if (!confirmed) return;

      _appendOutput("Running fastboot flash ${entry.name} ${entry.file}");
      final result = await _fastboot.flash(
        serial,
        entry.name,
        path.join(directory.path, entry.file),
      );
      _logResult(result);
      _appendOutput('${entry.name} flashed successfully.');
    } catch (error) {
      _appendOutput('Flash failed: $error');
      await _showMessage('Flash Failed', error.toString());
    } finally {
      if (mounted) setState(() => operating = false);
    }
  }

  Future<void> _flashAll() async {
    final directory = backupFolder;
    final loaded = manifest;
    final serial = selectedSerial;
    if (directory == null || loaded == null || serial == null || operating) return;

    setState(() => operating = true);
    try {
      for (final entry in loaded.partitions) {
        if (!await _verifyEntry(entry)) {
          throw FileSystemException('Integrity verification failed for ${entry.file}.');
        }
      }

      final issues = await _compatibilityIssues();
      final confirmed = await _confirmDestructive(
        title: 'Flash All Verified Partitions',
        message: '${_compatibilityMessage(issues)}\n\n${loaded.partitions.length} partitions will be flashed to $serial. The operation stops immediately if any fastboot command fails.',
        phrase: 'FLASH $serial',
      );
      if (!confirmed) return;

      for (final entry in loaded.partitions) {
        _appendOutput('Flashing ${entry.name}...');
        final result = await _fastboot.flash(
          serial,
          entry.name,
          path.join(directory.path, entry.file),
        );
        _logResult(result);
      }
      _appendOutput('All manifest partitions flashed successfully.');
    } catch (error) {
      _appendOutput('Flash All stopped: $error');
      await _showMessage('Flash All Stopped', error.toString());
    } finally {
      if (mounted) setState(() => operating = false);
    }
  }

  Future<void> _wipeUserdata() async {
    final serial = selectedSerial;
    if (serial == null || operating) return;
    final confirmed = await _confirmDestructive(
      title: 'Wipe Userdata',
      message: 'This will run fastboot -w on $serial ($fastbootProduct) and permanently erase user data.',
      phrase: 'WIPE $serial',
    );
    if (!confirmed) return;

    setState(() => operating = true);
    try {
      final result = await _fastboot.wipe(serial);
      _logResult(result);
      _appendOutput('Userdata wipe completed successfully.');
    } catch (error) {
      _appendOutput('Userdata wipe failed: $error');
      await _showMessage('Wipe Failed', error.toString());
    } finally {
      if (mounted) setState(() => operating = false);
    }
  }

  Future<void> _lockBootloader() async {
    final serial = selectedSerial;
    if (serial == null || operating) return;
    final confirmed = await _confirmDestructive(
      title: 'Lock Bootloader',
      message: 'Locking a device with non-stock or incompatible partitions can make it unbootable. Target: $serial ($fastbootProduct).',
      phrase: 'LOCK $serial',
    );
    if (!confirmed) return;

    setState(() => operating = true);
    try {
      final result = await _fastboot.lockBootloader(serial);
      _logResult(result);
      _appendOutput('Bootloader lock command completed successfully.');
    } catch (error) {
      _appendOutput('Bootloader lock failed: $error');
      await _showMessage('Lock Failed', error.toString());
    } finally {
      if (mounted) setState(() => operating = false);
    }
  }

  Future<void> _unlockBootloader() async {
    final serial = selectedSerial;
    if (serial == null || operating) return;
    final confirmed = await _confirmDestructive(
      title: 'Unlock Bootloader',
      message: 'Unlocking the bootloader normally wipes all user data and changes device security state. Target: $serial ($fastbootProduct).',
      phrase: 'UNLOCK $serial',
    );
    if (!confirmed) return;

    setState(() => operating = true);
    try {
      final result = await _fastboot.unlockBootloader(serial);
      _logResult(result);
      _appendOutput('Bootloader unlock command completed successfully.');
    } catch (error) {
      _appendOutput('Bootloader unlock failed: $error');
      await _showMessage('Unlock Failed', error.toString());
    } finally {
      if (mounted) setState(() => operating = false);
    }
  }

  Future<void> _rebootFastbootd() async {
    final serial = selectedSerial;
    if (serial == null || operating) return;
    setState(() => operating = true);
    try {
      final result = await _fastboot.rebootFastbootd(serial);
      _logResult(result);
      _appendOutput('Requested reboot to fastbootd.');
    } catch (error) {
      _appendOutput('Reboot to fastbootd failed: $error');
      await _showMessage('Reboot Failed', error.toString());
    } finally {
      if (mounted) setState(() => operating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loaded = manifest;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Restore Partitions${fastbootVersion.isEmpty ? '' : ' - $fastbootVersion'}',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            onPressed: () => _showMessage(
              'Flashing Partitions',
              'Only backups with a valid manifest are accepted. Every image is size/SHA-256 verified before flashing, and all fastboot commands are scoped to the selected serial.',
            ),
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
                  onPressed: operating ? null : _refreshDevices,
                  child: const Text('Refresh Devices'),
                ),
                if (devices.isNotEmpty)
                  DropdownButton<String>(
                    value: selectedSerial,
                    hint: const Text('Select fastboot device'),
                    items: devices
                        .map(
                          (device) => DropdownMenuItem(
                            value: device.serial,
                            child: Text(device.serial),
                          ),
                        )
                        .toList(),
                    onChanged: operating
                        ? null
                        : (value) {
                            if (value != null) _selectDevice(value);
                          },
                  ),
                FilledButton(
                  onPressed: operating ? null : _selectBackupFolder,
                  child: const Text('Select Backup Folder'),
                ),
                FilledButton(
                  onPressed: selectedSerial == null || operating ? null : _wipeUserdata,
                  child: const Text('Wipe Userdata'),
                ),
                FilledButton(
                  onPressed: selectedSerial == null || operating ? null : _lockBootloader,
                  child: const Text('Lock Bootloader'),
                ),
                FilledButton(
                  onPressed: selectedSerial == null || operating ? null : _unlockBootloader,
                  child: const Text('Unlock Bootloader'),
                ),
                FilledButton(
                  onPressed: selectedSerial == null || operating ? null : _rebootFastbootd,
                  child: const Text('Reboot to fastbootd'),
                ),
                if (loaded != null)
                  FilledButton(
                    onPressed: selectedSerial == null || operating ? null : _flashAll,
                    child: const Text('Flash All Verified'),
                  ),
                ElevatedButton(
                  onPressed: outputController.clear,
                  child: const Text('Clear Output'),
                ),
              ],
            ),
          ),
          if (operating) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Target: ${selectedSerial ?? 'none'} | Product: $fastbootProduct | Slot: $fastbootSlot | Backup: ${loaded == null ? 'none' : '${loaded.model} (${loaded.serial})'}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Verified Backup Contents', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Expanded(
                          child: loaded == null
                              ? const Center(child: Text('Select a backup folder containing backup_manifest.json.'))
                              : ListView.builder(
                                  itemCount: loaded.partitions.length,
                                  itemBuilder: (context, index) {
                                    final entry = loaded.partitions[index];
                                    return ListTile(
                                      title: Text(entry.name),
                                      subtitle: Text('${entry.file} • ${entry.size} bytes • SHA-256 ${entry.sha256.substring(0, 12)}…'),
                                      trailing: FilledButton(
                                        onPressed: selectedSerial == null || operating
                                            ? null
                                            : () => _flashEntry(entry),
                                        child: const Text('Verify & Flash'),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: TextField(
                      controller: outputController,
                      readOnly: true,
                      expands: true,
                      minLines: null,
                      maxLines: null,
                      decoration: const InputDecoration(
                        labelText: 'Output',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

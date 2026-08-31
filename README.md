# Android Partition Backup

A Flutter desktop utility for backing up rooted Android partitions with ADB and restoring verified images with Fastboot.

## Safety model

Raw partition operations are inherently risky. The app now scopes ADB/Fastboot commands to an explicitly selected device serial and does not treat a backup as successful until the local image has been verified.

Each successful backup records:

- device identity and serial
- partition name and source layout
- exact partition byte size
- SHA-256 of the local image
- backup timestamp and Android/device metadata

The metadata is written to `backup_manifest.json` in the backup folder. The restore screen only accepts folders containing a valid manifest, verifies every image before flashing, compares the target device with the manifest, and requires typed confirmation for destructive operations.

## Requirements

- Flutter for building the desktop application
- Android SDK Platform Tools (`adb` and `fastboot`) available in `PATH`
- USB debugging enabled for backups
- root access available to the ADB shell for raw partition reads
- an unlocked bootloader / appropriate Fastboot state when restoring images

## Backing up partitions

1. Connect the Android device with USB debugging enabled.
2. Authorize the computer on the device.
3. Open the app and select the target ADB serial if more than one device is connected.
4. Confirm that root access and the partition list are detected.
5. Choose a backup folder.
6. Select the partitions to back up.
7. Click **Backup Selected**.
8. Keep the device connected until each selected image is reported as verified.

`userdata` is intentionally skipped by Select All backups. If a transfer or verification fails after the temporary device image was created, the app retains that temporary file and reports its path rather than deleting the only potentially recoverable copy.

## Restoring partitions

1. Put the target device into the bootloader/Fastboot interface.
2. Open **Flash Partitions**.
3. Select the target Fastboot serial.
4. Select the backup folder containing `backup_manifest.json`.
5. Use **Verify & Flash** for one partition or **Flash All Verified** for the complete manifest set.
6. Review any serial/product mismatch warning carefully and enter the requested confirmation phrase.

Flash All stops on the first Fastboot failure. Wipe, bootloader lock, bootloader unlock, and flashing operations require explicit serial-specific confirmation.

## Build

```bash
flutter pub get
flutter build windows
```

The project also contains automated tests for command construction, device parsing, backup manifests, and basic UI rendering. GitHub Actions runs `flutter analyze` and `flutter test` for pull requests.

## License

MIT

Copyright 2024 Andy Wang

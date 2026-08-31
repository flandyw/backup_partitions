import 'package:backup_partitions/flash_partitions.dart';
import 'package:backup_partitions/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('backup screen renders without starting ADB', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HomeScreen(autoInitialize: false),
      ),
    );

    expect(find.text('Partition Backup'), findsOneWidget);
    expect(find.text('Browse Backup Folder'), findsOneWidget);
    expect(find.text('Available Partitions'), findsOneWidget);
  });

  testWidgets('restore screen renders without starting fastboot', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: FlashPartitions(autoInitialize: false),
      ),
    );

    expect(find.text('Restore Partitions'), findsOneWidget);
    expect(find.text('Select Backup Folder'), findsOneWidget);
    expect(find.text('Wipe Userdata'), findsOneWidget);
  });
}

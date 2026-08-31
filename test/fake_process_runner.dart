import 'dart:io';

import 'package:backup_partitions/services/process_runner.dart';

class RecordedCommand {
  const RecordedCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner(this.results);

  final List<ProcessResult> results;
  final List<RecordedCommand> commands = [];
  int _index = 0;

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) async {
    commands.add(RecordedCommand(executable, List<String>.of(arguments)));
    if (_index >= results.length) {
      throw StateError('No fake result queued for $executable ${arguments.join(' ')}');
    }
    return results[_index++];
  }
}

ProcessResult fakeResult({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
}) {
  return ProcessResult(1, exitCode, stdout, stderr);
}

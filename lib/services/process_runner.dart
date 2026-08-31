import 'dart:io';

abstract interface class ProcessRunner {
  Future<ProcessResult> run(String executable, List<String> arguments);
}

class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) {
    return Process.run(executable, arguments);
  }
}

class CommandFailure implements Exception {
  const CommandFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

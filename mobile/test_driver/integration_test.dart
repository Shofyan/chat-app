import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      final directory = Directory(
        Platform.environment['SCREENSHOT_OUTPUT'] ??
            '../.artifacts/screenshots',
      );
      await directory.create(recursive: true);
      await File('${directory.path}/$name.png').writeAsBytes(bytes);
      stdout.writeln('Saved screenshot: ${directory.path}/$name.png');
      return true;
    },
  );
}

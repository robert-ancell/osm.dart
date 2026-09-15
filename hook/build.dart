import 'dart:convert';
import 'dart:io';

import '../tool/update_version.dart';

/// Keeps `lib/src/version.g.dart` in step with the pubspec, on every
/// `dart run` and `dart test` of this package.
///
/// Not on `dart compile`, which does not run hooks at all: it compiles
/// whatever the file says at the time, and refuses outright in some layouts,
/// telling you to use `dart build`. Only `build.dart` here is run; another
/// file in this directory is something for it to import, not another hook.
/// `link.dart` is the one other name the runner knows, for builds that link.
///
/// The build hook protocol is a file in and a file out: the path of each
/// arrives in `--config=`. Nothing is built here, so the output says it
/// produced no assets.
///
/// This is development only. `.pubignore` keeps it out of the published
/// package, so nothing that depends on `osm` ever runs it: the generated file
/// is committed, a package in the pub cache cannot be written to anyway, and
/// a hook shipped to everyone downstream is a build step imposed on them for
/// a string that was decided when this was published.
void main(List<String> args) {
  final config = args
      .firstWhere((argument) => argument.startsWith('--config='))
      .substring('--config='.length);
  final input =
      jsonDecode(File(config).readAsStringSync()) as Map<String, Object?>;

  final root = Directory(input['package_root']! as String);
  _generate(root);

  File(input['out_file']! as String).writeAsStringSync(
    jsonEncode({
      'version': '1.9.0',
      'timestamp': DateTime.now().toUtc().toIso8601String().split('.').first,
      'assets': <Object>[],
      // What the runner watches to decide this has to happen again. Without
      // the pubspec here the hook runs once and its answer is cached for
      // ever, which is the whole of what it was for.
      'dependencies': ['${root.uri.resolve('pubspec.yaml')}'],
    }),
  );
}

void _generate(Directory root) {
  try {
    final pubspec = File('${root.path}/pubspec.yaml');
    if (!pubspec.existsSync()) return;
    final version = readVersion(pubspec.readAsStringSync());
    if (version == null) return;

    final out = File('${root.path}/lib/src/version.g.dart');
    final now = source(version);
    if (out.existsSync() && out.readAsStringSync() == now) return;
    out.writeAsStringSync(now);
  } on FileSystemException {
    // Nothing here is worth failing a build over, and the file is committed
    // at the version it was published as.
  }
}

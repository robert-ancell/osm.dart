import 'dart:convert';
import 'dart:io';

import 'update/http.dart';

/// Files fetched from one place, kept together on disk, and read back as
/// one thing.
///
/// For data that changes now and then and is wanted at every start: a copy
/// younger than [freshness] is used as it is; an older one is fetched again;
/// and when that cannot be done, the old one is used anyway, because old
/// data beats none. Null comes back only when there is no copy of any age
/// and nothing could be fetched.
///
/// The files are fetched and kept as a set, so that a copy on disk is always
/// one version of all of them rather than parts of several. [parse] turns
/// their contents, in the order of [files], into the thing itself, throwing
/// [FormatException] for anything that is not it; [isEmpty] says whether a
/// parsed copy holds nothing worth keeping.
Future<T?> readCachedFiles<T>({
  required Directory directory,
  required List<String> files,
  required Uri from,
  required OsmFetch fetch,
  required Duration freshness,
  required Future<T> Function(List<String> contents) parse,
  required bool Function(T parsed) isEmpty,
}) async {
  Future<T?> held({required bool however}) async {
    try {
      final kept = [for (final file in files) File('${directory.path}/$file')];
      if (!kept.every((file) => file.existsSync())) return null;
      if (!however) {
        final age = DateTime.now().difference(await kept.first.lastModified());
        if (age > freshness) return null;
      }
      final parsed = await parse([
        for (final file in kept) await file.readAsString(),
      ]);
      return isEmpty(parsed) ? null : parsed;
    } on IOException {
      return null;
    } on FormatException {
      return null;
    }
  }

  final recent = await held(however: false);
  if (recent != null) return recent;

  try {
    final fetched = <String>[];
    for (final file in files) {
      final body = await fetch(from.resolve(file));
      if (body == null) throw const FormatException('missing');
      fetched.add(utf8.decode(body));
    }
    final parsed = await parse(fetched);
    if (!isEmpty(parsed)) {
      await _keep(directory, files, fetched);
      return parsed;
    }
  } on IOException {
    // No network, or the files have moved.
  } on FormatException {
    // A file missing, or something that is not what was asked for at all,
    // such as a portal asking to be logged into. Not worth keeping.
  }

  return held(however: true);
}

/// Keeps a set of files, the first last: it is what says how old the copy
/// is, so it is only written once everything else is there.
Future<void> _keep(
  Directory directory,
  List<String> files,
  List<String> contents,
) async {
  try {
    for (var i = files.length - 1; i >= 0; i--) {
      final file = File('${directory.path}/${files[i]}');
      await file.parent.create(recursive: true);
      await file.writeAsString(contents[i]);
    }
  } on IOException {
    // Being unable to keep it costs a fetch next time, nothing more.
  }
}

import 'dart:convert';
import 'dart:io';

import 'exception.dart';
import '../element.dart';
import 'elements.dart';

/// The two bytes every gzip stream starts with.
const List<int> _gzipMagic = [0x1f, 0x8b];

/// What a change does to an element.
enum OsmChangeAction {
  /// The element is new.
  create,

  /// The element is a new version of one that already existed.
  modify,

  /// The element is gone.
  delete,
}

/// One element's change in an OsmChange (`.osc`) file.
///
/// A replication diff is a list of these: what OpenStreetMap did to the map
/// in a minute, an hour or a day, in the order it was done.
class OsmChange {
  /// What the change does.
  final OsmChangeAction action;

  /// The kind of element changed.
  final OsmElementType type;

  /// The id of the element changed.
  final int id;

  /// The version the change makes, if the file says.
  final int? version;

  /// The element as the file describes it.
  ///
  /// Null only when the file does not give enough to build one, which in
  /// practice means a deleted node with no location on it. The id, type and
  /// version are there either way, which is all it takes to drop the element
  /// a delete is talking about.
  final OsmElement? element;

  /// Creates a change.
  const OsmChange({
    required this.action,
    required this.type,
    required this.id,
    this.version,
    this.element,
  });

  @override
  String toString() => 'OsmChange(${action.name} ${type.name} $id)';
}

/// An OsmChange file, holding what a replication diff did to the map.
///
/// ```dart
/// for (final change in await OsmChangeFile.read('523.osc.gz')) {
///   if (change.action == OsmChangeAction.delete) forget(change.type, change.id);
/// }
/// ```
///
/// The whole file is held in memory. A minute of the planet is a few hundred
/// kilobytes and a day of it tens of megabytes, which is what these are for;
/// anything larger wants the PBF reader.
abstract final class OsmChangeFile {
  /// Reads the changes in the file at [path], gzipped or not.
  static Future<List<OsmChange>> read(String path) => stream(path).toList();

  /// The changes in the file at [path], gzipped or not, read as it is
  /// decompressed.
  ///
  /// The file is never whole in memory, compressed, decompressed or parsed:
  /// the largest hour of the planet is 15 MB of gzip and close to a million
  /// changes, and reading it all at once peaks at 866 MB.
  static Stream<OsmChange> stream(String path) async* {
    final file = File(path);
    // Replication diffs are served gzipped and usually kept that way, so
    // which it is comes from the bytes rather than from the name.
    final start = await file.openRead(0, _gzipMagic.length).fold<List<int>>(
      [],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    final gzipped = start.length == _gzipMagic.length &&
        start[0] == _gzipMagic[0] &&
        start[1] == _gzipMagic[1];

    Stream<List<int>> bytes = file.openRead();
    if (gzipped) bytes = bytes.transform(gzip.decoder);
    // Anything that is not UTF-8 is read as U+FFFD, for the parser to say
    // what is wrong. Damaged gzip comes as a FormatException from dart:io,
    // which is said here as what it means: the file cannot be read.
    yield* parseStream(
      bytes.transform(const Utf8Decoder(allowMalformed: true)).handleError(
            (Object e) => throw OsmXmlException(
              '$path cannot be read: ${(e as FormatException).message}',
            ),
            test: (e) => e is FormatException,
          ),
    );
  }

  /// The changes in XML handed over a piece at a time.
  static Stream<OsmChange> parseStream(Stream<String> pieces) async* {
    final ready = <OsmChange>[];
    final reader = OsmXmlElementReader((read) {
      final change = _changeOf(read);
      if (change != null) ready.add(change);
    });
    await for (final piece in pieces) {
      reader.add(piece);
      yield* Stream.fromIterable(ready);
      ready.clear();
    }
    reader.close();
    yield* Stream.fromIterable(ready);
  }

  /// Reads the changes in [xml].
  static List<OsmChange> parse(String xml) {
    final changes = <OsmChange>[];
    readOsmXmlElements(xml, (read) {
      final change = _changeOf(read);
      if (change != null) changes.add(change);
    });
    return changes;
  }
}

/// The change an element in an `<osmChange>` makes, or null for one outside a
/// create, modify or delete, which is not a change.
OsmChange? _changeOf(XmlElement read) {
  final action = switch (read.action) {
    'create' => OsmChangeAction.create,
    'modify' => OsmChangeAction.modify,
    'delete' => OsmChangeAction.delete,
    _ => null,
  };
  if (action == null) return null;
  return OsmChange(
    action: action,
    type: read.type,
    id: read.id,
    version: read.version,
    element: read.element,
  );
}

import 'dart:io';

import '../element.dart';
import '../filter.dart';
import '../filter_plan.dart';
import 'blob.dart';
import 'block.dart';
import 'decode_ahead.dart';
import 'exception.dart';
import 'header.dart';

/// An OpenStreetMap PBF file, opened for reading.
///
/// ```dart
/// final file = await OsmPbfFile.open('new-zealand-latest.osm.pbf');
/// final courses = file.elements(
///   filter: const OsmFilter.tag('leisure', 'golf_course'),
/// );
/// await for (final course in courses) {
///   print(course.tags['name']);
/// }
/// ```
///
/// Elements are decoded a block at a time as they are asked for, so a file
/// much larger than memory can be processed by streaming through it.
class OsmPbfFile {
  /// The path the file was opened from.
  final String path;

  /// What the file says about itself.
  final OsmPbfHeader header;

  const OsmPbfFile._(this.path, this.header);

  /// Opens the file at [path] and reads its header.
  ///
  /// Throws an [OsmPbfException] if the file is not a PBF file, or if it
  /// requires a feature this package cannot decode.
  static Future<OsmPbfFile> open(String path) async {
    final file = await File(path).open();
    try {
      final blob = await BlobReader(file).next();
      if (blob == null) {
        throw const OsmPbfException('File is empty');
      }
      if (blob.type != 'OSMHeader') {
        throw OsmPbfException(
          'File starts with a ${blob.type} blob, not the OSMHeader a PBF '
          'file starts with',
          offset: blob.offset,
        );
      }
      return OsmPbfFile._(
        path,
        decodeHeaderBlock(
          decodeBlob(blob.body, offset: blob.offset),
          offset: blob.offset,
        ),
      );
    } finally {
      await file.close();
    }
  }

  /// The elements of the file, in the order they are stored.
  ///
  /// Files are normally sorted, so this yields every node, then every way,
  /// then every relation, each in increasing id order. Each listen reads the
  /// file again from the start.
  ///
  /// Pass a [filter] to take only part of the file. Filtering here rather than
  /// on the returned stream is far faster, because the filter is used to skip
  /// work rather than to throw away its results.
  ///
  /// A filtered read decodes blocks on [isolates] worker isolates at once, by
  /// default two per processor. An unfiltered read decodes on the calling
  /// isolate, because when every element is wanted, handing them all back from
  /// a worker costs more than decoding them in parallel saves. Pass [isolates]
  /// to say which to do: 1 decodes here, more decodes there.
  Stream<OsmElement> elements({OsmFilter? filter, int? isolates}) {
    final workers =
        isolates ?? (filter == null ? 1 : Platform.numberOfProcessors * 2);
    if (workers < 1) {
      throw ArgumentError.value(isolates, 'isolates', 'Must be at least 1');
    }
    final plan = OsmFilterPlan.of(filter);
    return workers == 1
        ? _readHere(plan)
        : decodeAhead(_blobs(), plan, workers);
  }

  /// The data blobs of the file, read in order.
  ///
  /// Header blobs may appear again part way through a file that was made by
  /// putting two files end to end, and are skipped.
  Stream<RawBlob> _blobs() async* {
    final file = await File(path).open();
    try {
      final blobs = BlobReader(file);
      for (var blob = await blobs.next();
          blob != null;
          blob = await blobs.next()) {
        if (blob.type == 'OSMData') yield blob;
      }
    } finally {
      await file.close();
    }
  }

  /// Reads and decodes everything on the calling isolate.
  ///
  /// The whole plan goes to the decoder, filter included, so an element that
  /// does not match is never built in the first place.
  Stream<OsmElement> _readHere(OsmFilterPlan plan) async* {
    await for (final blob in _blobs()) {
      final elements = <OsmElement>[];
      decodePrimitiveBlock(
        decodeBlob(blob.body, offset: blob.offset),
        elements.add,
        offset: blob.offset,
        plan: plan,
      );
      for (final element in elements) {
        yield element;
      }
    }
  }

  @override
  String toString() => 'OsmPbfFile($path)';
}

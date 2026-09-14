import 'dart:io';

import '../element.dart';
import 'blob.dart';
import 'block.dart';
import 'exception.dart';
import 'header.dart';

/// An OpenStreetMap PBF file, opened for reading.
///
/// ```dart
/// final file = await OsmPbfFile.open('new-zealand-latest.osm.pbf');
/// await for (final element in file.elements()) {
///   if (element.tags['leisure'] == 'golf_course') print(element);
/// }
/// ```
///
/// Elements are read straight off the disk as they are asked for, so a file
/// much larger than memory can be processed a block at a time.
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
  Stream<OsmElement> elements() async* {
    final file = await File(path).open();
    try {
      final blobs = BlobReader(file);
      for (var blob = await blobs.next();
          blob != null;
          blob = await blobs.next()) {
        // Header blobs may appear again part way through a concatenated file.
        if (blob.type != 'OSMData') continue;
        final elements = <OsmElement>[];
        decodePrimitiveBlock(
          decodeBlob(blob.body, offset: blob.offset),
          elements.add,
          offset: blob.offset,
        );
        for (final element in elements) {
          yield element;
        }
      }
    } finally {
      await file.close();
    }
  }

  @override
  String toString() => 'OsmPbfFile($path)';
}

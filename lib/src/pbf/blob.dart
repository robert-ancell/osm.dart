import 'dart:io';
import 'dart:typed_data';

import 'exception.dart';
import 'fields.dart';
import 'protobuf.dart';

/// The largest header and blob sizes the format allows, used to reject
/// corrupt files before allocating from a bogus length.
const int _maxHeaderSize = 64 * 1024;
const int _maxBodySize = 32 * 1024 * 1024;

/// A blob as it sits in the file, before decompression.
///
/// Decompressing and decoding a blob needs nothing but these bytes, which is
/// what lets the work be handed to another isolate.
class RawBlob {
  /// The kind of block the blob holds, either `OSMHeader` or `OSMData`.
  final String type;

  /// The encoded `Blob` message holding the compressed block.
  final Uint8List body;

  /// The offset of the blob in the file, used to report where errors are.
  final int offset;

  /// Creates a blob read from a file.
  const RawBlob({required this.type, required this.body, required this.offset});
}

/// Reads the blob framing of a PBF file.
///
/// A file is a sequence of blobs, each one a big endian length, a `BlobHeader`
/// giving the type and size of what follows, and then the `Blob` itself.
class BlobReader {
  final RandomAccessFile _file;
  final Uint8List _lengthBuffer = Uint8List(4);
  int _offset = 0;

  /// Creates a reader over an open file, positioned at its start.
  BlobReader(this._file);

  /// Reads the next blob, or returns null at the end of the file.
  Future<RawBlob?> next() async {
    final blobOffset = _offset;
    if (!await _readInto(_lengthBuffer, allowEndOfFile: true)) return null;
    final headerSize = (_lengthBuffer[0] << 24) |
        (_lengthBuffer[1] << 16) |
        (_lengthBuffer[2] << 8) |
        _lengthBuffer[3];
    if (headerSize > _maxHeaderSize) {
      throw OsmPbfException(
        'Blob header of $headerSize bytes is too large to be valid',
        offset: blobOffset,
      );
    }

    final header = Uint8List(headerSize);
    await _readInto(header);
    final (type, bodySize) = _decodeHeader(header, blobOffset);
    if (bodySize < 0 || bodySize > _maxBodySize) {
      throw OsmPbfException(
        'Blob of $bodySize bytes is too large to be valid',
        offset: blobOffset,
      );
    }

    final body = Uint8List(bodySize);
    await _readInto(body);
    return RawBlob(type: type, body: body, offset: blobOffset);
  }

  (String, int) _decodeHeader(Uint8List bytes, int offset) {
    final reader = ProtobufReader(bytes);
    String? type;
    var bodySize = -1;
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      switch (ProtobufReader.fieldOf(tag)) {
        case BlobHeaderField.type:
          type = reader.readString();
        case BlobHeaderField.dataSize:
          bodySize = reader.readVarint();
        default:
          reader.skipField(tag);
      }
    }
    if (type == null || bodySize < 0) {
      throw OsmPbfException('Blob header is missing a type or size',
          offset: offset);
    }
    return (type, bodySize);
  }

  /// Fills [buffer] from the file, returning false only at a clean end of file.
  Future<bool> _readInto(Uint8List buffer,
      {bool allowEndOfFile = false}) async {
    var filled = 0;
    while (filled < buffer.length) {
      final read = await _file.readInto(buffer, filled, buffer.length);
      if (read == 0) {
        if (filled == 0 && allowEndOfFile) return false;
        throw OsmPbfException(
          'File ends in the middle of a blob',
          offset: _offset + filled,
        );
      }
      filled += read;
    }
    _offset += filled;
    return true;
  }
}

/// Decompresses the block held in a blob.
///
/// This is pure computation over [body], so it can run in any isolate.
Uint8List decodeBlob(Uint8List body, {int offset = 0}) {
  final reader = ProtobufReader(body);
  Uint8List? raw;
  Uint8List? zlibData;
  var rawSize = -1;
  String? unsupported;
  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case BlobField.raw:
        raw = reader.readBytes();
      case BlobField.rawSize:
        rawSize = reader.readVarint();
      case BlobField.zlibData:
        zlibData = reader.readBytes();
      case BlobField.lzmaData:
        unsupported = 'lzma';
        reader.skipField(tag);
      case BlobField.lz4Data:
        unsupported = 'lz4';
        reader.skipField(tag);
      case BlobField.zstdData:
        unsupported = 'zstd';
        reader.skipField(tag);
      default:
        reader.skipField(tag);
    }
  }

  final Uint8List block;
  if (raw != null) {
    block = raw;
  } else if (zlibData != null) {
    final decoded = zlib.decode(zlibData);
    block = decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
  } else if (unsupported != null) {
    throw OsmPbfException(
      'Blob is $unsupported compressed, which is not supported. Recompress '
      'the file with zlib, for example with `osmium cat -o out.osm.pbf`.',
      offset: offset,
    );
  } else {
    throw OsmPbfException('Blob holds no data', offset: offset);
  }

  if (rawSize >= 0 && block.length != rawSize) {
    throw OsmPbfException(
      'Blob decompressed to ${block.length} bytes, not the $rawSize it '
      'declares',
      offset: offset,
    );
  }
  return block;
}

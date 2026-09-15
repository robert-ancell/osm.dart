import 'dart:convert';
import 'dart:typed_data';

/// How a field's value is laid out, which is the low three bits of its tag.
///
/// Declared in the order the format numbers them, so the index of each is the
/// number the wire uses for it.
enum ProtobufWireType {
  /// A base 128 variable width integer.
  varint,

  /// Eight bytes.
  fixed64,

  /// A length and then that many bytes.
  lengthDelimited,

  /// The start of a group, which nothing has used since protobuf 2.
  startGroup,

  /// The end of one.
  endGroup,

  /// Four bytes.
  fixed32;

  /// The wire type [tag] carries, or null if it carries none of them.
  static ProtobufWireType? of(int tag) {
    final value = tag & 7;
    return value < values.length ? values[value] : null;
  }
}

/// Thrown when a buffer does not contain well formed protobuf data.
class ProtobufFormatException extends FormatException {
  /// Creates an exception describing why decoding failed.
  ProtobufFormatException(super.message, [super.source, super.offset]);
}

/// A reader for the protobuf binary wire format.
///
/// The OSM PBF messages are decoded directly into their final representation
/// rather than into generated message classes, which avoids allocating an
/// object per field on the hottest paths of the file.
class ProtobufReader {
  final Uint8List _bytes;
  final int _end;
  int _offset;

  /// Creates a reader over [bytes], optionally limited to the range
  /// \[[start], [end]).
  ProtobufReader(Uint8List bytes, {int start = 0, int? end})
      : _bytes = bytes,
        _offset = start,
        _end = end ?? bytes.length;

  /// Whether every byte in range has been consumed.
  bool get isAtEnd => _offset >= _end;

  /// Reads the tag of the next field, combining its number and wire type.
  ///
  /// Use [fieldOf] and [wireTypeOf] to take the tag apart.
  int readTag() {
    final tag = readVarint();
    if (tag == 0 || wireTypeOf(tag) == ProtobufWireType.endGroup) {
      throw ProtobufFormatException('Invalid field tag $tag', _bytes, _offset);
    }
    return tag;
  }

  /// The field number encoded in [tag].
  static int fieldOf(int tag) => tag >> 3;

  /// The wire type encoded in [tag], or null if it is not one of them.
  static ProtobufWireType? wireTypeOf(int tag) => ProtobufWireType.of(tag);

  /// Reads a base 128 variable width integer.
  int readVarint() {
    // Fast path for the single byte values that dominate real files.
    if (_offset < _end) {
      final b = _bytes[_offset];
      if (b < 0x80) {
        _offset++;
        return b;
      }
    }
    var result = 0;
    var shift = 0;
    while (shift < 64) {
      if (_offset >= _end) {
        throw ProtobufFormatException('Truncated varint', _bytes, _offset);
      }
      final byte = _bytes[_offset++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
    throw ProtobufFormatException('Varint too long', _bytes, _offset);
  }

  /// Reads a zigzag encoded signed integer (protobuf `sint32`/`sint64`).
  int readSignedVarint() {
    final value = readVarint();
    return (value >> 1) ^ -(value & 1);
  }

  /// Reads a length delimited field as a UTF-8 string.
  String readString() {
    final length = readVarint();
    final start = _checkedAdvance(length);
    return utf8.decode(Uint8List.sublistView(_bytes, start, _offset));
  }

  /// Reads a length delimited field as a copy of its bytes.
  Uint8List readBytes() {
    final length = readVarint();
    final start = _checkedAdvance(length);
    return Uint8List.sublistView(_bytes, start, _offset);
  }

  /// Reads a length delimited field as a reader over its contents.
  ProtobufReader readMessage() {
    final length = readVarint();
    final start = _checkedAdvance(length);
    return ProtobufReader(_bytes, start: start, end: _offset);
  }

  /// Reads a packed repeated varint field, appending to [into].
  void readPackedVarints(List<int> into) {
    final length = readVarint();
    final start = _checkedAdvance(length);
    final end = _offset;
    _offset = start;
    while (_offset < end) {
      into.add(readVarint());
    }
  }

  /// Reads a packed repeated zigzag varint field, appending to [into].
  void readPackedSignedVarints(List<int> into) {
    final length = readVarint();
    final start = _checkedAdvance(length);
    final end = _offset;
    _offset = start;
    while (_offset < end) {
      into.add(readSignedVarint());
    }
  }

  /// Reads a packed repeated zigzag varint field encoded as deltas, appending
  /// the running totals to [into].
  void readPackedDeltas(List<int> into) {
    final length = readVarint();
    final start = _checkedAdvance(length);
    final end = _offset;
    _offset = start;
    var value = 0;
    while (_offset < end) {
      value += readSignedVarint();
      into.add(value);
    }
  }

  /// Skips the value of a field with the given [tag].
  void skipField(int tag) {
    switch (wireTypeOf(tag)) {
      case ProtobufWireType.varint:
        readVarint();
      case ProtobufWireType.fixed64:
        _checkedAdvance(8);
      case ProtobufWireType.lengthDelimited:
        _checkedAdvance(readVarint());
      case ProtobufWireType.fixed32:
        _checkedAdvance(4);
      case ProtobufWireType.startGroup:
        _skipGroup(fieldOf(tag));
      case ProtobufWireType.endGroup || null:
        throw ProtobufFormatException(
          'Unsupported wire type in tag $tag',
          _bytes,
          _offset,
        );
    }
  }

  void _skipGroup(int field) {
    while (true) {
      if (isAtEnd) {
        throw ProtobufFormatException('Unterminated group', _bytes, _offset);
      }
      final tag = readVarint();
      if (wireTypeOf(tag) == ProtobufWireType.endGroup) {
        if (fieldOf(tag) != field) {
          throw ProtobufFormatException(
              'Mismatched group end', _bytes, _offset);
        }
        return;
      }
      skipField(tag);
    }
  }

  int _checkedAdvance(int length) {
    if (length < 0 || _offset + length > _end) {
      throw ProtobufFormatException(
        'Field of $length bytes overruns the message',
        _bytes,
        _offset,
      );
    }
    final start = _offset;
    _offset += length;
    return start;
  }
}

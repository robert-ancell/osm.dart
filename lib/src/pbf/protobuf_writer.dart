import 'dart:convert';
import 'dart:typed_data';

import 'protobuf.dart';

/// Writes the protobuf binary wire format.
///
/// The mirror of [ProtobufReader], and written the same way: straight from
/// the values, with no message objects in between.
class ProtobufWriter {
  // Copying, not holding: the varint scratch below is written again for
  // every value, so a builder keeping a view of it would see the last one
  // everywhere.
  final BytesBuilder _bytes = BytesBuilder();
  final Uint8List _scratch = Uint8List(10);

  /// How many bytes have been written.
  int get length => _bytes.length;

  /// Everything written so far.
  Uint8List takeBytes() => _bytes.takeBytes();

  /// Writes a base 128 variable width integer.
  ///
  /// A negative value takes the full ten bytes, which is what the format says
  /// for a signed field that was not zigzag encoded.
  void writeVarint(int value) {
    var at = 0;
    var rest = value;
    while (true) {
      final part = rest & 0x7f;
      rest = rest >>> 7;
      if (rest == 0) {
        _scratch[at++] = part;
        break;
      }
      _scratch[at++] = part | 0x80;
    }
    _bytes.add(Uint8List.sublistView(_scratch, 0, at));
  }

  /// Writes the tag introducing a field.
  void writeTag(int field, ProtobufWireType wireType) =>
      writeVarint(field << 3 | wireType.index);

  /// Writes an unsigned or non-negative field.
  void writeUint(int field, int value) {
    writeTag(field, ProtobufWireType.varint);
    writeVarint(value);
  }

  /// Writes a zigzag encoded signed field.
  void writeSigned(int field, int value) {
    writeTag(field, ProtobufWireType.varint);
    writeVarint(_zigzag(value));
  }

  /// Writes a boolean field.
  void writeBool(int field, {required bool value}) =>
      writeUint(field, value ? 1 : 0);

  /// Writes a length delimited field holding UTF-8.
  void writeString(int field, String value) =>
      writeBytes(field, utf8.encode(value));

  /// Writes a length delimited field holding bytes.
  void writeBytes(int field, Uint8List value) {
    writeTag(field, ProtobufWireType.lengthDelimited);
    writeVarint(value.length);
    _bytes.add(value);
  }

  /// Writes a nested message, which has to be built before its length can be
  /// written in front of it.
  void writeMessage(int field, void Function(ProtobufWriter into) build) {
    final nested = ProtobufWriter();
    build(nested);
    writeBytes(field, nested.takeBytes());
  }

  /// Writes a packed repeated field of plain varints.
  void writePackedVarints(int field, List<int> values) {
    if (values.isEmpty) return;
    final packed = ProtobufWriter();
    for (final value in values) {
      packed.writeVarint(value);
    }
    writeBytes(field, packed.takeBytes());
  }

  /// Writes a packed repeated field of zigzag encoded varints.
  void writePackedSigned(int field, List<int> values) {
    if (values.isEmpty) return;
    final packed = ProtobufWriter();
    for (final value in values) {
      packed.writeVarint(_zigzag(value));
    }
    writeBytes(field, packed.takeBytes());
  }

  /// Writes a packed repeated field as the steps between the values.
  void writePackedDeltas(int field, List<int> values) {
    if (values.isEmpty) return;
    final packed = ProtobufWriter();
    var last = 0;
    for (final value in values) {
      packed.writeVarint(_zigzag(value - last));
      last = value;
    }
    writeBytes(field, packed.takeBytes());
  }

  static int _zigzag(int value) => (value << 1) ^ (value >> 63);
}

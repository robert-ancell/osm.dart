import 'dart:typed_data';

import 'package:osm/src/pbf/protobuf.dart';
import 'package:test/test.dart';

ProtobufReader _reader(List<int> bytes) =>
    ProtobufReader(Uint8List.fromList(bytes));

void main() {
  test('reads varints', () {
    expect(_reader([0x00]).readVarint(), 0);
    expect(_reader([0x7f]).readVarint(), 127);
    expect(_reader([0x80, 0x01]).readVarint(), 128);
    expect(
      _reader([0xff, 0xff, 0xff, 0xff, 0x0f]).readVarint(),
      0xffffffff,
    );
  });

  test('reads zigzag encoded varints', () {
    expect(_reader([0x00]).readSignedVarint(), 0);
    expect(_reader([0x01]).readSignedVarint(), -1);
    expect(_reader([0x02]).readSignedVarint(), 1);
    expect(_reader([0x81, 0x01]).readSignedVarint(), -65);
  });

  test('takes a tag apart', () {
    // Field 3, wire type 2.
    final tag = _reader([0x1a]).readTag();
    expect(ProtobufReader.fieldOf(tag), 3);
    expect(ProtobufReader.wireTypeOf(tag), ProtobufWireType.lengthDelimited);
  });

  test('reads a length delimited string', () {
    expect(_reader([0x02, 0x68, 0x69]).readString(), 'hi');
  });

  test('reads packed deltas as running totals', () {
    // Three bytes holding the zigzag values 1, 1 and -1.
    final reader = _reader([0x03, 0x02, 0x02, 0x01]);
    final values = <int>[];
    reader.readPackedDeltas(values);
    expect(values, [1, 2, 1]);
    expect(reader.isAtEnd, isTrue);
  });

  test('gives no wire type for one the format does not define', () {
    expect(ProtobufWireType.of(6), isNull);
    expect(ProtobufWireType.of(7), isNull);
    expect(ProtobufWireType.of(0), ProtobufWireType.varint);
    expect(ProtobufWireType.of(5), ProtobufWireType.fixed32);
  });

  test('skips fields it does not know', () {
    final reader = _reader([0x08, 0x2a, 0x12, 0x02, 0x68, 0x69, 0x18, 0x01]);
    final fields = <int>[];
    while (!reader.isAtEnd) {
      final tag = reader.readTag();
      fields.add(ProtobufReader.fieldOf(tag));
      reader.skipField(tag);
    }
    expect(fields, [1, 2, 3]);
  });

  test('rejects a truncated varint', () {
    expect(_reader([0x80]).readVarint, throwsA(isA<FormatException>()));
  });

  test('rejects a field that runs past the end', () {
    expect(_reader([0x10, 0x01]).readString, throwsA(isA<FormatException>()));
  });
}

import 'dart:io';
import 'dart:typed_data';

import '../element.dart';
import 'exception.dart';
import 'fields.dart';
import '../version.g.dart';
import 'header.dart';
import 'protobuf_writer.dart';

/// How many elements go in one block.
///
/// The format asks for blocks under 16 MB uncompressed and the usual answer
/// is eight thousand elements, which lands far inside that.
const int _blockElements = 8000;

/// Nanodegrees per unit of stored coordinate, and milliseconds per unit of
/// stored time. Both are what every file in the wild uses.
const int _granularity = 100;
const int _dateGranularity = 1000;

/// Writes an OpenStreetMap PBF file.
///
/// ```dart
/// final writer = await OsmPbfWriter.create('out.osm.pbf', header: file.header);
/// await for (final element in file.elements()) {
///   writer.add(element);
/// }
/// await writer.close();
/// ```
///
/// Elements are gathered into blocks and written as they fill, so a file far
/// larger than memory can be written by streaming through it.
class OsmPbfWriter {
  final IOSink _sink;

  /// Whether the header promised the elements would be in order, in which
  /// case they are checked as they arrive.
  final bool _sorted;

  final List<OsmElement> _block = [];
  OsmElementType? _blockType;
  OsmElementType? _lastType;
  int _lastId = 0;

  OsmPbfWriter._(this._sink, {required bool sorted}) : _sorted = sorted;

  /// Creates a file at [path], writing [header] into it.
  ///
  /// The header carries what the file says about itself, the replication
  /// state most of all: an extract that loses it can never be brought up to
  /// date again, so an update reads the header of what it is updating and
  /// hands it back here.
  ///
  /// The features the header declares are taken as promises and checked. A
  /// file saying `Sort.Type_then_ID` whose elements arrive out of order is a
  /// file that lies about itself, so that throws rather than being written.
  static Future<OsmPbfWriter> create(
    String path, {
    OsmPbfHeader header = const OsmPbfHeader(),
  }) async {
    final sink = File(path).openWrite();
    final writer = OsmPbfWriter._(sink, sorted: header.isSorted);
    sink.add(_blob('OSMHeader', _headerBlock(header)));
    return writer;
  }

  /// Adds an element to the file.
  void add(OsmElement element) {
    if (_sorted) _checkOrder(element);
    // A block holds one kind of element: nodes are written densely, which
    // only works if nothing else is in with them.
    if (_blockType != null &&
        (element.type != _blockType || _block.length >= _blockElements)) {
      _flush();
    }
    _blockType = element.type;
    _block.add(element);
  }

  /// Adds every element of [elements].
  Future<void> addAll(Stream<OsmElement> elements) async {
    await for (final element in elements) {
      add(element);
    }
  }

  /// Finishes the file.
  Future<void> close() async {
    _flush();
    await _sink.flush();
    await _sink.close();
  }

  void _checkOrder(OsmElement element) {
    final last = _lastType;
    if (last != null) {
      if (element.type.index < last.index ||
          (element.type == last && element.id <= _lastId)) {
        throw OsmPbfException(
          'The header says the file is sorted, but ${element.type.name} '
          '${element.id} comes after ${last.name} $_lastId',
        );
      }
    }
    _lastType = element.type;
    _lastId = element.id;
  }

  void _flush() {
    if (_block.isEmpty) return;
    _sink.add(_blob('OSMData', _primitiveBlock(_block)));
    _block.clear();
    _blockType = null;
  }
}

/// The strings of one block, and where each one sits in its table.
///
/// Index zero is left empty. Nothing may use it: a zero in the run of keys
/// and values of a dense node is what ends that node's tags.
class _StringTable {
  final Map<String, int> _indexes = {'': 0};
  final List<String> _strings = [''];

  int indexOf(String value) => _indexes.putIfAbsent(value, () {
        _strings.add(value);
        return _strings.length - 1;
      });

  void writeTo(ProtobufWriter block) =>
      block.writeMessage(PrimitiveBlockField.stringTable, (table) {
        for (final string in _strings) {
          table.writeString(StringTableField.strings, string);
        }
      });
}

Uint8List _headerBlock(OsmPbfHeader header) {
  final block = ProtobufWriter();

  final bounds = header.bounds;
  if (bounds != null) {
    block.writeMessage(HeaderBlockField.bbox, (box) {
      box
        ..writeSigned(HeaderBBoxField.left, _nanodegrees(bounds.minLongitude))
        ..writeSigned(HeaderBBoxField.right, _nanodegrees(bounds.maxLongitude))
        ..writeSigned(HeaderBBoxField.top, _nanodegrees(bounds.maxLatitude))
        ..writeSigned(HeaderBBoxField.bottom, _nanodegrees(bounds.minLatitude));
    });
  }

  // Dense nodes are how this writes them, so the file has to say so whatever
  // the header it was handed said.
  final required = {'OsmSchema-V0.6', 'DenseNodes', ...header.requiredFeatures};
  for (final feature in required) {
    block.writeString(HeaderBlockField.requiredFeatures, feature);
  }
  for (final feature in header.optionalFeatures) {
    block.writeString(HeaderBlockField.optionalFeatures, feature);
  }

  // What wrote the file, in the shape everything else states it: osmium
  // writes `osmium/1.19.0`, and a file should say which version of what made
  // it rather than only what kind of thing did.
  block.writeString(HeaderBlockField.writingProgram,
      header.writingProgram ?? 'osm/$packageVersion');
  final source = header.source;
  if (source != null) block.writeString(HeaderBlockField.source, source);

  final timestamp = header.replicationTimestamp;
  if (timestamp != null) {
    block.writeUint(HeaderBlockField.replicationTimestamp,
        timestamp.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond);
  }
  final sequence = header.replicationSequenceNumber;
  if (sequence != null) {
    block.writeUint(HeaderBlockField.replicationSequenceNumber, sequence);
  }
  final baseUrl = header.replicationBaseUrl;
  if (baseUrl != null) {
    block.writeString(HeaderBlockField.replicationBaseUrl, baseUrl);
  }

  return block.takeBytes();
}

int _nanodegrees(double degrees) => (degrees * 1e9).round();

Uint8List _primitiveBlock(List<OsmElement> elements) {
  final strings = _StringTable();
  // The groups reference the table, so they are built first and the table
  // written once it knows every string they used.
  final group = ProtobufWriter();

  switch (elements.first) {
    case OsmNode():
      _writeDenseNodes(group, elements.cast<OsmNode>(), strings);
    case OsmWay():
      for (final way in elements.cast<OsmWay>()) {
        group.writeMessage(
            PrimitiveGroupField.ways, (into) => _writeWay(into, way, strings));
      }
    case OsmRelation():
      for (final relation in elements.cast<OsmRelation>()) {
        group.writeMessage(PrimitiveGroupField.relations,
            (into) => _writeRelation(into, relation, strings));
      }
  }

  final block = ProtobufWriter();
  strings.writeTo(block);
  block.writeBytes(PrimitiveBlockField.primitiveGroup, group.takeBytes());
  block
    ..writeUint(PrimitiveBlockField.granularity, _granularity)
    ..writeUint(PrimitiveBlockField.dateGranularity, _dateGranularity);
  return block.takeBytes();
}

void _writeDenseNodes(
  ProtobufWriter group,
  List<OsmNode> nodes,
  _StringTable strings,
) {
  final ids = <int>[];
  final latitudes = <int>[];
  final longitudes = <int>[];
  final keysValues = <int>[];
  var tagged = false;

  for (final node in nodes) {
    ids.add(node.id);
    latitudes.add((node.latitude * 1e7).round());
    longitudes.add((node.longitude * 1e7).round());
    for (final tag in node.tags.entries) {
      keysValues
        ..add(strings.indexOf(tag.key))
        ..add(strings.indexOf(tag.value));
      tagged = true;
    }
    keysValues.add(0);
  }

  // A block of nodes with no tags at all leaves the run out rather than
  // writing a zero for every one of them.
  final withInfo = nodes.where((n) => n.info != null).isNotEmpty;

  group.writeMessage(PrimitiveGroupField.dense, (dense) {
    dense
      ..writePackedDeltas(DenseNodesField.ids, ids)
      ..writePackedDeltas(DenseNodesField.latitudes, latitudes)
      ..writePackedDeltas(DenseNodesField.longitudes, longitudes);
    if (tagged) {
      dense.writePackedVarints(DenseNodesField.keysValues, keysValues);
    }
    if (withInfo) {
      dense.writeMessage(DenseNodesField.denseInfo, (info) {
        info
          ..writePackedVarints(InfoField.version, [
            for (final node in nodes) node.info?.version ?? 0,
          ])
          ..writePackedDeltas(InfoField.timestamp, [
            for (final node in nodes) _seconds(node.info?.timestamp),
          ])
          ..writePackedDeltas(InfoField.changeset, [
            for (final node in nodes) node.info?.changeset ?? 0,
          ])
          ..writePackedDeltas(InfoField.uid, [
            for (final node in nodes) node.info?.uid ?? 0,
          ])
          ..writePackedDeltas(InfoField.userStringId, [
            for (final node in nodes) strings.indexOf(node.info?.user ?? ''),
          ]);
      });
    }
  });
}

void _writeWay(ProtobufWriter into, OsmWay way, _StringTable strings) {
  into.writeUint(WayField.id, way.id);
  _writeTags(into, way.tags, strings, WayField.keys, WayField.values);
  _writeInfo(into, way.info, strings, WayField.info);
  into.writePackedDeltas(WayField.refs, way.nodeIds);
}

void _writeRelation(
  ProtobufWriter into,
  OsmRelation relation,
  _StringTable strings,
) {
  into.writeUint(RelationField.id, relation.id);
  _writeTags(
      into, relation.tags, strings, RelationField.keys, RelationField.values);
  _writeInfo(into, relation.info, strings, RelationField.info);
  into
    ..writePackedVarints(RelationField.roleStringIds, [
      for (final member in relation.members) strings.indexOf(member.role),
    ])
    ..writePackedDeltas(RelationField.memberIds, [
      for (final member in relation.members) member.ref,
    ])
    // MemberType in the .proto is NODE, WAY then RELATION, which is the
    // order OsmElementType declares them in.
    ..writePackedVarints(RelationField.types, [
      for (final member in relation.members) member.type.index,
    ]);
}

void _writeTags(
  ProtobufWriter into,
  Map<String, String> tags,
  _StringTable strings,
  int keysField,
  int valuesField,
) {
  if (tags.isEmpty) return;
  into
    ..writePackedVarints(keysField, [
      for (final key in tags.keys) strings.indexOf(key),
    ])
    ..writePackedVarints(valuesField, [
      for (final value in tags.values) strings.indexOf(value),
    ]);
}

void _writeInfo(
    ProtobufWriter into, OsmInfo? info, _StringTable strings, int field) {
  if (info == null) return;
  into.writeMessage(field, (message) {
    if (info.version != null) {
      message.writeUint(InfoField.version, info.version!);
    }
    if (info.timestamp != null) {
      message.writeUint(InfoField.timestamp, _seconds(info.timestamp));
    }
    if (info.changeset != null) {
      message.writeUint(InfoField.changeset, info.changeset!);
    }
    if (info.uid != null) message.writeUint(InfoField.uid, info.uid!);
    if (info.user != null) {
      message.writeUint(InfoField.userStringId, strings.indexOf(info.user!));
    }
    if (!info.visible) message.writeBool(InfoField.visible, value: false);
  });
}

int _seconds(DateTime? timestamp) => timestamp == null
    ? 0
    : timestamp.millisecondsSinceEpoch ~/ _dateGranularity;

/// Wraps a block in the framing the file is a sequence of: a big endian
/// length, a header saying what and how big, and then the block itself.
Uint8List _blob(String type, Uint8List block) {
  final compressed = Uint8List.fromList(zlib.encode(block));

  final blob = ProtobufWriter()
    ..writeUint(BlobField.rawSize, block.length)
    ..writeBytes(BlobField.zlibData, compressed);
  final body = blob.takeBytes();

  final header = ProtobufWriter()
    ..writeString(BlobHeaderField.type, type)
    ..writeUint(BlobHeaderField.dataSize, body.length);
  final headerBytes = header.takeBytes();

  // The length in front of every blob: four bytes, most significant first.
  final length = ByteData(4)..setUint32(0, headerBytes.length);

  final out = BytesBuilder(copy: false)
    ..add(length.buffer.asUint8List())
    ..add(headerBytes)
    ..add(body);
  return out.takeBytes();
}

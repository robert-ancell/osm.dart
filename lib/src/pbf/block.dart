import 'dart:convert';
import 'dart:typed_data';

import '../bounds.dart';
import '../element.dart';
import '../filter_plan.dart';
import 'exception.dart';
import 'header.dart';
import 'protobuf.dart';

/// The features this package knows how to decode.
const Set<String> _knownFeatures = {
  'OsmSchema-V0.6',
  'DenseNodes',
  'HistoricalInformation',
  'Sort.Type_then_ID',
};

const double _nanoDegrees = 1e-9;

/// Decodes an `OSMHeader` block.
OsmPbfHeader decodeHeaderBlock(Uint8List block, {int offset = 0}) {
  final reader = ProtobufReader(block);
  OsmBounds? bounds;
  final required = <String>[];
  final optional = <String>[];
  String? writingProgram;
  String? source;
  int? replicationTimestamp;
  int? replicationSequenceNumber;
  String? replicationBaseUrl;

  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case 1:
        bounds = _decodeBoundingBox(reader.readMessage());
      case 4:
        required.add(reader.readString());
      case 5:
        optional.add(reader.readString());
      case 16:
        writingProgram = reader.readString();
      case 17:
        source = reader.readString();
      case 32:
        replicationTimestamp = reader.readVarint();
      case 33:
        replicationSequenceNumber = reader.readVarint();
      case 34:
        replicationBaseUrl = reader.readString();
      default:
        reader.skipField(tag);
    }
  }

  final unknown = required.where((f) => !_knownFeatures.contains(f)).toList();
  if (unknown.isNotEmpty) {
    throw OsmPbfException(
      'File requires features this package cannot decode: '
      '${unknown.join(', ')}',
      offset: offset,
    );
  }

  return OsmPbfHeader(
    bounds: bounds,
    requiredFeatures: List.unmodifiable(required),
    optionalFeatures: List.unmodifiable(optional),
    writingProgram: writingProgram,
    source: source,
    replicationTimestamp: replicationTimestamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            replicationTimestamp * 1000,
            isUtc: true,
          ),
    replicationSequenceNumber: replicationSequenceNumber,
    replicationBaseUrl: replicationBaseUrl,
  );
}

OsmBounds _decodeBoundingBox(ProtobufReader reader) {
  var left = 0, right = 0, top = 0, bottom = 0;
  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case 1:
        left = reader.readSignedVarint();
      case 2:
        right = reader.readSignedVarint();
      case 3:
        top = reader.readSignedVarint();
      case 4:
        bottom = reader.readSignedVarint();
      default:
        reader.skipField(tag);
    }
  }
  return OsmBounds(
    minLatitude: bottom * _nanoDegrees,
    minLongitude: left * _nanoDegrees,
    maxLatitude: top * _nanoDegrees,
    maxLongitude: right * _nanoDegrees,
  );
}

/// Decodes an `OSMData` block, passing each element it holds to [emit].
///
/// Elements are emitted in the order they appear in the block, which for a
/// file sorted the usual way means nodes, then ways, then relations.
void decodePrimitiveBlock(
  Uint8List block,
  void Function(OsmElement element) emit, {
  int offset = 0,
  OsmFilterPlan? plan,
}) {
  plan ??= OsmFilterPlan.of(null);
  final reader = ProtobufReader(block);
  // The groups reference the string table, which the format does not
  // guarantee comes first, so the groups are decoded in a second pass.
  var strings = _StringTable.empty;
  final groups = <ProtobufReader>[];
  var granularity = 100;
  var dateGranularity = 1000;
  var latitudeOffset = 0;
  var longitudeOffset = 0;

  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case 1:
        strings = _decodeStringTable(reader.readMessage());
      case 2:
        groups.add(reader.readMessage());
      case 17:
        granularity = reader.readVarint();
      case 18:
        dateGranularity = reader.readVarint();
      case 19:
        latitudeOffset = reader.readVarint();
      case 20:
        longitudeOffset = reader.readVarint();
      default:
        reader.skipField(tag);
    }
  }

  // If the filter needs a tag key that this block's string table does not
  // hold, nothing in the block can match and none of it is worth decoding.
  final keyIndexes = strings.indexesOf(plan.encodedKeys);
  if (keyIndexes != null && keyIndexes.isEmpty) return;

  final context = _BlockContext(
    strings: strings,
    granularity: granularity,
    dateGranularity: dateGranularity,
    latitudeOffset: latitudeOffset,
    longitudeOffset: longitudeOffset,
    offset: offset,
    plan: plan,
    keyIndexes: keyIndexes,
  );
  for (final group in groups) {
    _decodeGroup(group, context, emit);
  }
}

/// The strings a block's elements are built from.
///
/// Held as the raw UTF-8 of the block and decoded one entry at a time, the
/// first time something asks for it. A block that the filter drops is never
/// decoded at all, and a block it keeps only pays for the strings the matching
/// elements actually use.
class _StringTable {
  final List<Uint8List> _bytes;
  final List<String?> _decoded;

  _StringTable(this._bytes)
      : _decoded = List<String?>.filled(_bytes.length, null);

  static final _StringTable empty = _StringTable(const []);

  int get length => _bytes.length;

  String operator [](int index) =>
      _decoded[index] ??= utf8.decode(_bytes[index]);

  /// The indexes of the entries equal to one of [wanted], or null if there is
  /// nothing to look for.
  ///
  /// Compares bytes, so looking for a key costs no decoding.
  Set<int>? indexesOf(List<Uint8List>? wanted) {
    if (wanted == null) return null;
    final indexes = <int>{};
    for (var i = 0; i < _bytes.length; i++) {
      final entry = _bytes[i];
      for (final key in wanted) {
        if (_sameBytes(entry, key)) {
          indexes.add(i);
          break;
        }
      }
    }
    return indexes;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

_StringTable _decodeStringTable(ProtobufReader reader) {
  final strings = <Uint8List>[];
  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    if (ProtobufReader.fieldOf(tag) == 1) {
      strings.add(reader.readBytes());
    } else {
      reader.skipField(tag);
    }
  }
  return _StringTable(strings);
}

/// The parts of a primitive block its groups are decoded against.
class _BlockContext {
  final _StringTable strings;
  final int granularity;
  final int dateGranularity;
  final int latitudeOffset;
  final int longitudeOffset;
  final int offset;
  final OsmFilterPlan plan;

  /// The string table indexes of the keys [plan] needs, or null if it needs
  /// no particular key.
  final Set<int>? keyIndexes;

  const _BlockContext({
    required this.strings,
    required this.granularity,
    required this.dateGranularity,
    required this.latitudeOffset,
    required this.longitudeOffset,
    required this.offset,
    required this.plan,
    required this.keyIndexes,
  });

  /// Whether an element with these tag key indexes could match the filter.
  ///
  /// Cheap, and wrong only in the safe direction: it lets through elements
  /// the filter then turns away, and never holds one back that would have
  /// matched.
  bool couldMatchKeys(List<int> keys) {
    if (keys.isEmpty) return plan.wantsUntagged;
    final wanted = keyIndexes;
    if (wanted == null) return true;
    for (final key in keys) {
      if (wanted.contains(key)) return true;
    }
    return false;
  }

  /// Whether an element of [type] with this [id] could match the filter.
  bool couldMatchId(OsmElementType type, int id) {
    final wanted = plan.ids;
    if (wanted == null) return true;
    final forType = wanted[type];
    return forType != null && forType.contains(id);
  }

  /// Whether a dense node whose tags run from [start] to [end] in the shared
  /// key and value list could match the filter.
  bool couldMatchDenseKeys(List<int> keysValues, int start, int end) {
    if (start >= end) return plan.wantsUntagged;
    final wanted = keyIndexes;
    if (wanted == null) return true;
    for (var i = start; i < end; i += 2) {
      if (wanted.contains(keysValues[i])) return true;
    }
    return false;
  }

  /// Whether [element] is wanted, once it is built.
  bool wants(OsmElement element) => plan.filter?.matches(element) ?? true;

  double latitude(int value) =>
      _nanoDegrees * (latitudeOffset + granularity * value);

  double longitude(int value) =>
      _nanoDegrees * (longitudeOffset + granularity * value);

  DateTime timestamp(int value) => DateTime.fromMillisecondsSinceEpoch(
        value * dateGranularity,
        isUtc: true,
      );

  String string(int index) {
    if (index < 0 || index >= strings.length) {
      throw OsmPbfException(
        'String index $index is outside the block string table',
        offset: offset,
      );
    }
    return strings[index];
  }
}

void _decodeGroup(
  ProtobufReader reader,
  _BlockContext context,
  void Function(OsmElement element) emit,
) {
  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case 1 when context.plan.wantsType(OsmElementType.node):
        final node = _decodeNode(reader.readMessage(), context);
        if (node != null) emit(node);
      case 2 when context.plan.wantsType(OsmElementType.node):
        _decodeDenseNodes(reader.readMessage(), context, emit);
      case 3 when context.plan.wantsType(OsmElementType.way):
        final way = _decodeWay(reader.readMessage(), context);
        if (way != null) emit(way);
      case 4 when context.plan.wantsType(OsmElementType.relation):
        final relation = _decodeRelation(reader.readMessage(), context);
        if (relation != null) emit(relation);
      default:
        // Either an element type the filter has ruled out, or field 5, which
        // holds changesets that no file in the wild carries.
        reader.skipField(tag);
    }
  }
}

Map<String, String> _tags(
  List<int> keys,
  List<int> values,
  _BlockContext context,
) {
  if (keys.isEmpty) return const {};
  if (keys.length != values.length) {
    throw OsmPbfException(
      'Element has ${keys.length} tag keys but ${values.length} values',
      offset: context.offset,
    );
  }
  final tags = <String, String>{};
  for (var i = 0; i < keys.length; i++) {
    tags[context.string(keys[i])] = context.string(values[i]);
  }
  return tags;
}

OsmNode? _decodeNode(ProtobufReader reader, _BlockContext context) {
  var id = 0;
  var latitude = 0;
  var longitude = 0;
  final keys = <int>[];
  final values = <int>[];
  OsmInfo? info;

  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case 1:
        id = reader.readSignedVarint();
      case 2:
        reader.readPackedVarints(keys);
      case 3:
        reader.readPackedVarints(values);
      case 4:
        info = _decodeInfo(reader.readMessage(), context);
      case 8:
        latitude = reader.readSignedVarint();
      case 9:
        longitude = reader.readSignedVarint();
      default:
        reader.skipField(tag);
    }
  }

  if (!context.couldMatchId(OsmElementType.node, id) ||
      !context.couldMatchKeys(keys)) {
    return null;
  }

  final node = OsmNode(
    id: id,
    latitude: context.latitude(latitude),
    longitude: context.longitude(longitude),
    tags: _tags(keys, values, context),
    info: info,
  );
  return context.wants(node) ? node : null;
}

OsmInfo _decodeInfo(ProtobufReader reader, _BlockContext context) {
  int? version;
  int? timestamp;
  int? changeset;
  int? uid;
  int? userIndex;
  var visible = true;

  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case 1:
        version = reader.readVarint();
      case 2:
        timestamp = reader.readVarint();
      case 3:
        changeset = reader.readVarint();
      case 4:
        uid = reader.readVarint();
      case 5:
        userIndex = reader.readVarint();
      case 6:
        visible = reader.readVarint() != 0;
      default:
        reader.skipField(tag);
    }
  }

  // An empty user string means the edit was made anonymously.
  final user = userIndex == null ? null : context.string(userIndex);

  return OsmInfo(
    version: version,
    timestamp: timestamp == null ? null : context.timestamp(timestamp),
    changeset: changeset,
    uid: uid,
    user: user == null || user.isEmpty ? null : user,
    visible: visible,
  );
}

void _decodeDenseNodes(
  ProtobufReader reader,
  _BlockContext context,
  void Function(OsmElement element) emit,
) {
  final ids = <int>[];
  final latitudes = <int>[];
  final longitudes = <int>[];
  final keysValues = <int>[];
  _DenseInfo? denseInfo;

  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case 1:
        reader.readPackedDeltas(ids);
      case 5:
        denseInfo = _decodeDenseInfo(reader.readMessage());
      case 8:
        reader.readPackedDeltas(latitudes);
      case 9:
        reader.readPackedDeltas(longitudes);
      case 10:
        reader.readPackedVarints(keysValues);
      default:
        reader.skipField(tag);
    }
  }

  if (latitudes.length != ids.length || longitudes.length != ids.length) {
    throw OsmPbfException(
      'Dense nodes have ${ids.length} ids but ${latitudes.length} latitudes '
      'and ${longitudes.length} longitudes',
      offset: context.offset,
    );
  }

  var index = 0;
  for (var i = 0; i < ids.length; i++) {
    // Each node takes key and value pairs from the shared list until a zero
    // ends its run. Walking the run is a handful of integer comparisons, so
    // it happens for every node, before anything is allocated for one.
    final start = index;
    if (index < keysValues.length) {
      while (keysValues[index] != 0) {
        if (index + 2 >= keysValues.length) {
          throw OsmPbfException(
            'Dense node tags end in the middle of a key and value pair',
            offset: context.offset,
          );
        }
        index += 2;
      }
      index++;
    }
    final end = index == start ? start : index - 1;

    if (!context.couldMatchId(OsmElementType.node, ids[i]) ||
        !context.couldMatchDenseKeys(keysValues, start, end)) {
      continue;
    }

    var tags = const <String, String>{};
    if (start < end) {
      final decoded = <String, String>{};
      for (var pair = start; pair < end; pair += 2) {
        decoded[context.string(keysValues[pair])] = context.string(
          keysValues[pair + 1],
        );
      }
      tags = decoded;
    }

    final node = OsmNode(
      id: ids[i],
      latitude: context.latitude(latitudes[i]),
      longitude: context.longitude(longitudes[i]),
      tags: tags,
      info: denseInfo?.at(i, context),
    );
    if (context.wants(node)) emit(node);
  }
}

/// The parallel arrays of [_decodeDenseNodes] metadata.
class _DenseInfo {
  final List<int> versions;
  final List<int> timestamps;
  final List<int> changesets;
  final List<int> uids;
  final List<int> userIndexes;
  final List<bool> visibles;

  const _DenseInfo({
    required this.versions,
    required this.timestamps,
    required this.changesets,
    required this.uids,
    required this.userIndexes,
    required this.visibles,
  });

  OsmInfo at(int i, _BlockContext context) {
    final userIndex = i < userIndexes.length ? userIndexes[i] : null;
    final user = userIndex == null ? null : context.string(userIndex);
    return OsmInfo(
      version: i < versions.length ? versions[i] : null,
      timestamp:
          i < timestamps.length ? context.timestamp(timestamps[i]) : null,
      changeset: i < changesets.length ? changesets[i] : null,
      uid: i < uids.length ? uids[i] : null,
      user: user == null || user.isEmpty ? null : user,
      visible: i < visibles.length ? visibles[i] : true,
    );
  }
}

_DenseInfo _decodeDenseInfo(ProtobufReader reader) {
  final versions = <int>[];
  final timestamps = <int>[];
  final changesets = <int>[];
  final uids = <int>[];
  final userIndexes = <int>[];
  final visibles = <bool>[];

  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case 1:
        reader.readPackedVarints(versions);
      case 2:
        reader.readPackedDeltas(timestamps);
      case 3:
        reader.readPackedDeltas(changesets);
      case 4:
        reader.readPackedDeltas(uids);
      case 5:
        reader.readPackedDeltas(userIndexes);
      case 6:
        final flags = <int>[];
        reader.readPackedVarints(flags);
        visibles.addAll(flags.map((f) => f != 0));
      default:
        reader.skipField(tag);
    }
  }

  return _DenseInfo(
    versions: versions,
    timestamps: timestamps,
    changesets: changesets,
    uids: uids,
    userIndexes: userIndexes,
    visibles: visibles,
  );
}

OsmWay? _decodeWay(ProtobufReader reader, _BlockContext context) {
  var id = 0;
  final keys = <int>[];
  final values = <int>[];
  final nodeIds = <int>[];
  OsmInfo? info;

  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case 1:
        id = reader.readVarint();
      case 2:
        reader.readPackedVarints(keys);
      case 3:
        reader.readPackedVarints(values);
      case 4:
        info = _decodeInfo(reader.readMessage(), context);
      case 8:
        reader.readPackedDeltas(nodeIds);
      default:
        reader.skipField(tag);
    }
  }

  if (!context.couldMatchId(OsmElementType.way, id) ||
      !context.couldMatchKeys(keys)) {
    return null;
  }

  final way = OsmWay(
    id: id,
    nodeIds: nodeIds,
    tags: _tags(keys, values, context),
    info: info,
  );
  return context.wants(way) ? way : null;
}

OsmRelation? _decodeRelation(ProtobufReader reader, _BlockContext context) {
  var id = 0;
  final keys = <int>[];
  final values = <int>[];
  final roles = <int>[];
  final refs = <int>[];
  final types = <int>[];
  OsmInfo? info;

  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    switch (ProtobufReader.fieldOf(tag)) {
      case 1:
        id = reader.readVarint();
      case 2:
        reader.readPackedVarints(keys);
      case 3:
        reader.readPackedVarints(values);
      case 4:
        info = _decodeInfo(reader.readMessage(), context);
      case 8:
        reader.readPackedVarints(roles);
      case 9:
        reader.readPackedDeltas(refs);
      case 10:
        reader.readPackedVarints(types);
      default:
        reader.skipField(tag);
    }
  }

  if (!context.couldMatchId(OsmElementType.relation, id) ||
      !context.couldMatchKeys(keys)) {
    return null;
  }

  if (roles.length != refs.length || types.length != refs.length) {
    throw OsmPbfException(
      'Relation $id has ${refs.length} members but ${roles.length} roles and '
      '${types.length} types',
      offset: context.offset,
    );
  }

  final members = <OsmMember>[];
  for (var i = 0; i < refs.length; i++) {
    if (types[i] < 0 || types[i] >= OsmElementType.values.length) {
      throw OsmPbfException(
        'Relation $id has a member of unknown type ${types[i]}',
        offset: context.offset,
      );
    }
    members.add(
      OsmMember(
        type: OsmElementType.values[types[i]],
        ref: refs[i],
        role: context.string(roles[i]),
      ),
    );
  }

  final relation = OsmRelation(
    id: id,
    members: members,
    tags: _tags(keys, values, context),
    info: info,
  );
  return context.wants(relation) ? relation : null;
}

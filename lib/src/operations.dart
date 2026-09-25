/// Things done to what is selected, each as one change: deleting it,
/// reversing it, pulling a point out of it, knowing what line it would
/// continue, copying and pasting it, and moving it.
///
/// As iD does them, rule for rule, so that an edit made here is the edit
/// someone who knows iD expects. Each works on an [OsmEditView] — what was
/// read with what has been changed laid over it — and records what it does
/// in its [OsmEditView.edits], gathered into one change to undo.
library;

import 'dart:math' as math;

import 'edit.dart';
import 'element.dart';
import 'mercator.dart';
import 'presets.dart';

/// The data being edited, as it now stands.
///
/// What was read, with what has been changed laid over it and what has been
/// taken off the map left out.
abstract interface class OsmEditView {
  /// Where changes are recorded.
  OsmEdits get edits;

  /// The node with [id] as it now stands, or null if it is not held or has
  /// been taken off the map.
  OsmNode? node(int id);

  /// The way with [id] as it now stands, or null.
  OsmWay? way(int id);

  /// The relation with [id] as it now stands, or null.
  OsmRelation? relation(int id);

  /// The ways that now run through the node with [id].
  List<OsmWay> waysUsing(int nodeId);

  /// The relations that now list the element.
  List<OsmRelation> relationsUsing(OsmElementType type, int id);

  /// The shape [element] now takes.
  OsmGeometry geometryOf(OsmElement element);
}

/// Keys that say nothing about what a thing is: where the data came from,
/// and ids in other databases.
const _uninterestingKeys = {
  'attribution',
  'created_by',
  'import_uuid',
  'lat',
  'latitude',
  'lon',
  'longitude',
  'source',
  'source_ref',
  'odbl',
  'odbl:note',
};

final _uninterestingKey = RegExp(
  r'^(source(_ref)?|at_bev|geobase|hcpaogis|KSJ2|mvdgis|nvdb|nysgissam|tiger):'
  r'|:(identifier|ref|ref_id|id)$',
);

/// Whether [tags] say something about what a thing is, rather than only
/// where the data came from. As iD judges it.
bool osmHasInterestingTags(Map<String, String> tags) => tags.keys.any(
      (key) =>
          !_uninterestingKeys.contains(key) && !_uninterestingKey.hasMatch(key),
    );

/// Whether [way] has too few nodes left to be a way at all.
bool osmIsDegenerate(OsmWay way) =>
    way.nodeIds.toSet().length < (way.isClosed ? 3 : 2);

/// Records whatever [change] does as one change to undo.
void _asOne(OsmEdits edits, void Function() change) {
  final mark = edits.length;
  change();
  edits.combineSince(mark);
}

/// Deleting what is selected.
class OsmDelete {
  final OsmEditView _view;

  /// What is to be deleted, as it now stands.
  final List<OsmElement> selected;

  /// Creates the operation.
  OsmDelete(this._view, this.selected);

  /// Whether it can be done: anything can be deleted.
  bool get available => selected.isNotEmpty;

  /// Why it cannot be done, in iD's words for the reason, or null if it can.
  ///
  /// A way that is part of a route or a boundary, or an outer edge of a
  /// multipolygon, would leave a hole in something larger, and has to be
  /// taken out of it first. Something with a Wikidata tag is somebody's
  /// careful work, linked from elsewhere, and is not deleted by accident.
  String? get disabled {
    if (selected.any(_protected)) return 'part_of_relation';
    if (selected.any((e) => (e.tags['wikidata'] ?? '').trim().isNotEmpty)) {
      return 'has_wikidata_tag';
    }
    return null;
  }

  bool _protected(OsmElement element) {
    if (element is! OsmWay) return false;
    for (final relation
        in _view.relationsUsing(OsmElementType.way, element.id)) {
      final type = relation.tags['type'];
      for (final member in relation.members) {
        if (member.type != OsmElementType.way || member.ref != element.id) {
          continue;
        }
        final role = member.role.isEmpty ? 'outer' : member.role;
        if (type == 'route' ||
            type == 'boundary' ||
            (type == 'multipolygon' && role == 'outer')) {
          return true;
        }
      }
    }
    return false;
  }

  /// Deletes it all, as one change.
  ///
  /// A way left with too few nodes by a node going goes too, as does a
  /// relation left with no members. A way takes with it those of its nodes
  /// that nothing else uses and that say nothing of their own.
  void apply() => _asOne(_view.edits, () {
        for (final element in selected) {
          switch (element) {
            case OsmNode():
              if (_view.node(element.id) case final node?) _deleteNode(node);
            case OsmWay():
              if (_view.way(element.id) case final way?) _deleteWay(way);
            case OsmRelation():
              if (_view.relation(element.id) case final r?) _deleteRelation(r);
          }
        }
      });

  void _deleteNode(OsmNode node) {
    final ways = _view.waysUsing(node.id);
    final relations = _view.relationsUsing(OsmElementType.node, node.id);
    _view.edits.deleteNode(node, from: ways, relations: relations);
    for (final way in ways) {
      final now = _view.way(way.id);
      if (now != null && osmIsDegenerate(now)) _deleteWay(now);
    }
    _deleteEmpty(relations);
  }

  void _deleteWay(OsmWay way) {
    final relations = _view.relationsUsing(OsmElementType.way, way.id);
    _view.edits.deleteWay(way, relations: relations);
    _deleteEmpty(relations);
    for (final id in way.nodeIds.toSet()) {
      final node = _view.node(id);
      if (node == null) continue;
      if (_view.waysUsing(id).isNotEmpty) continue;
      if (_view.relationsUsing(OsmElementType.node, id).isNotEmpty) continue;
      if (osmHasInterestingTags(node.tags)) continue;
      _view.edits.deleteNode(node);
    }
  }

  void _deleteRelation(OsmRelation relation) {
    final parents = _view.relationsUsing(OsmElementType.relation, relation.id);
    _view.edits.deleteRelation(relation, relations: parents);
    _deleteEmpty(parents);
  }

  void _deleteEmpty(List<OsmRelation> relations) {
    for (final relation in relations) {
      final now = _view.relation(relation.id);
      if (now != null && now.members.isEmpty) _deleteRelation(now);
    }
  }
}

/// Reversing what is selected: the direction of a line, and of anything
/// tagged with a direction.
class OsmReverse {
  final OsmEditView _view;

  /// What is to be reversed, as it now stands.
  final List<OsmElement> selected;

  /// Creates the operation.
  OsmReverse(this._view, this.selected);

  /// What of the selection reverses: its lines, and the nodes that say
  /// which way they face. Areas have no direction.
  List<OsmElement> get _reversible => [
        for (final element in selected)
          if (element is OsmWay &&
              _view.geometryOf(element) == OsmGeometry.line)
            element
          else if (element is OsmNode && _hasDirection(element.tags))
            element,
      ];

  /// Whether it can be done.
  bool get available => _reversible.isNotEmpty;

  /// What kind of thing is reversed, for choosing how to describe it: a
  /// `line` or `lines`, a `point` or `points`, or `features` for both.
  String get kind {
    final reversible = _reversible;
    final nodes = reversible.whereType<OsmNode>().length;
    final many = reversible.length > 1;
    if (nodes == 0) return many ? 'lines' : 'line';
    if (nodes == reversible.length) return many ? 'points' : 'point';
    return 'features';
  }

  /// Reverses it all, as one change.
  ///
  /// A line runs the other way, and its tags and those of its nodes that
  /// say which way something faces are turned round with it: left and
  /// right, forward and backward, up and down, and an incline's sign. Its
  /// part in a route going forward or backward is turned round too. Its
  /// `oneway` is left alone: a oneway drawn the wrong way round is what
  /// reversing is usually for. A node on its own also has its compass
  /// direction turned round.
  void apply() => _asOne(_view.edits, () {
        for (final element in _reversible) {
          switch (element) {
            case OsmWay():
              osmReverseWay(_view, element);
            case OsmNode():
              _reverseNode(element.id, absolute: true);
            case OsmRelation():
              break;
          }
        }
      });

  void _reverseNode(int id, {required bool absolute}) {
    final node = _view.node(id);
    if (node == null || node.tags.isEmpty) return;
    _view.edits.setTags(node, osmReversedTags(node.tags, absolute: absolute));
  }

  static bool _hasDirection(Map<String, String> tags) {
    final reversed = osmReversedTags(tags, absolute: true);
    if (reversed.length != tags.length) return true;
    return tags.entries.any((e) => reversed[e.key] != e.value);
  }
}

/// Turns [way] round in [view]'s edits: its nodes run the other way, and
/// its tags, its nodes' tags and its part in any route going forward or
/// backward turn round with it.
///
/// Its `oneway` only turns round with [oneway]: reversing a way on its own
/// is usually done to put right a oneway drawn backwards, and turning the
/// tag round too would undo the point of it; reversing one to join it to
/// another has to keep traffic going the way it went.
void osmReverseWay(OsmEditView view, OsmWay way, {bool oneway = false}) {
  for (final relation in view.relationsUsing(OsmElementType.way, way.id)) {
    var changed = false;
    final members = [
      for (final member in relation.members)
        if (member.type == OsmElementType.way &&
            member.ref == way.id &&
            _roles[member.role] != null)
          OsmMember(
              type: member.type, ref: member.ref, role: _roles[member.role]!)
        else
          member,
    ];
    for (var i = 0; i < members.length; i++) {
      if (!identical(members[i], relation.members[i])) changed = true;
    }
    if (changed) view.edits.setRelationMembers(relation, members);
  }
  final nodes = way.nodeIds.reversed.toList();
  for (final id in nodes.toSet()) {
    final node = view.node(id);
    if (node == null || node.tags.isEmpty) continue;
    view.edits.setTags(node, osmReversedTags(node.tags, absolute: false));
  }
  view.edits.setWayNodes(way, nodes);
  view.edits.setTags(
    view.way(way.id) ?? way,
    osmReversedTags(way.tags, absolute: false, oneway: oneway),
  );
}

const _roles = {
  'forward': 'backward',
  'backward': 'forward',
  'forwards': 'backward',
  'backwards': 'forward',
};

/// [tags] turned round for something that now faces the other way, as iD
/// turns them.
///
/// Keys ending or containing `:left`, `:right`, `:forward` and `:backward`
/// swap, as do those words as values, and `up` and `down`. A numeric
/// `incline` changes sign. With [absolute], a key ending in `direction` has
/// its compass point or bearing turned half way round as well, which is
/// right for a node standing on its own and wrong for one along a line.
/// Names, notes and the like are left as they are whatever words are in
/// them, as are turn lanes, which are left and right of the lane.
Map<String, String> osmReversedTags(
  Map<String, String> tags, {
  required bool absolute,
  bool oneway = false,
}) =>
    {
      for (final MapEntry(:key, :value) in tags.entries)
        _reverseKey(key): oneway && key == 'oneway'
            ? (_onewayReplacements[value] ?? value)
            : _reverseValue(key, value, absolute, tags),
    };

const _onewayReplacements = {'yes': '-1', '1': '-1', '-1': 'yes'};

final _keyReplacements = [
  (RegExp(r':right$'), ':left'),
  (RegExp(r':left$'), ':right'),
  (RegExp(r':forward$'), ':backward'),
  (RegExp(r':backward$'), ':forward'),
  (RegExp(r':right:'), ':left:'),
  (RegExp(r':left:'), ':right:'),
  (RegExp(r':forward:'), ':backward:'),
  (RegExp(r':backward:'), ':forward:'),
];

final _keysToKeep = [RegExp(r'^red_turn:(right|left):?')];

final _valuesToKeep = [
  (
    RegExp(
      r'^.*(_|:)?(description|name|note|website|ref|source|comment|watch|attribution)(_|:)?',
    ),
    const <Map<String, String>>[{}],
  ),
  (RegExp(r'^turn:lanes:?'), const <Map<String, String>>[{}]),
  (
    RegExp(r'^side$'),
    const <Map<String, String>>[
      {'highway': 'cyclist_waiting_aid'},
    ],
  ),
  (RegExp(r'^railway:turnout_side$'), const <Map<String, String>>[{}]),
];

const _valueReplacements = {
  'left': 'right',
  'right': 'left',
  'up': 'down',
  'down': 'up',
  'forward': 'backward',
  'backward': 'forward',
  'forwards': 'backward',
  'backwards': 'forward',
};

const _compass = {
  'N': 'S',
  'NNE': 'SSW',
  'NE': 'SW',
  'ENE': 'WSW',
  'E': 'W',
  'ESE': 'WNW',
  'SE': 'NW',
  'SSE': 'NNW',
  'S': 'N',
  'SSW': 'NNE',
  'SW': 'NE',
  'WSW': 'ENE',
  'W': 'E',
  'WNW': 'ESE',
  'NW': 'SE',
  'NNW': 'SSE',
};

final _numeric = RegExp(r'^([+\-]?)(?=[\d.])');

String _reverseKey(String key) {
  if (_keysToKeep.any((keep) => keep.hasMatch(key))) return key;
  for (final (pattern, replacement) in _keyReplacements) {
    if (pattern.hasMatch(key)) return key.replaceFirst(pattern, replacement);
  }
  return key;
}

String _reverseValue(
  String key,
  String value,
  bool absolute,
  Map<String, String> tags,
) {
  for (final (pattern, contexts) in _valuesToKeep) {
    if (pattern.hasMatch(key) &&
        contexts.any(
          (needed) => needed.entries.every(
            (e) =>
                tags[e.key] != null &&
                (e.value == '*' || tags[e.key] == e.value),
          ),
        )) {
      return value;
    }
  }
  if (key == 'incline' && _numeric.hasMatch(value)) {
    return value.replaceFirstMapped(
      _numeric,
      (match) => match[1] == '-' ? '' : '-',
    );
  }
  if (absolute && key.endsWith('direction')) {
    return value.split(';').map((part) {
      final compass = _compass[part];
      if (compass != null) return compass;
      final degrees = num.tryParse(part);
      if (degrees != null && degrees.isFinite) {
        final turned = degrees < 180 ? degrees + 180 : degrees - 180;
        return _number(turned);
      }
      return _valueReplacements[part] ?? part;
    }).join(';');
  }
  return _valueReplacements[value] ?? value;
}

/// [value] as JavaScript writes a number, which is how iD writes a turned
/// bearing: no `.0` on a whole number.
String _number(num value) =>
    value == value.truncate() ? value.truncate().toString() : value.toString();

/// Pulling a point out of what is selected.
class OsmExtract {
  final OsmEditView _view;

  /// What points are to be pulled out of, as it now stands.
  final List<OsmElement> selected;

  /// The kinds of thing there are, which say whether what a way is could
  /// also be a point. Without them, nothing is pulled out of a way.
  final OsmPresets? presets;

  /// Where it is, for choosing among kinds that only exist in some places.
  final Set<String> here;

  /// Creates the operation.
  OsmExtract(this._view, this.selected, {this.presets, this.here = const {}});

  bool _extractable(OsmElement element) {
    if (!osmHasInterestingTags(element.tags)) return false;
    if (element is OsmNode) return _view.waysUsing(element.id).isNotEmpty;
    final presets = this.presets;
    if (presets == null) return false;
    final preset = presets.match(
      element.tags,
      _view.geometryOf(element),
      here: here,
    );
    return preset.geometry.contains(OsmGeometry.point);
  }

  /// Whether it can be done: everything selected has a point in it to pull
  /// out.
  bool get available => selected.isNotEmpty && selected.every(_extractable);

  /// Pulls the points out, as one change, and gives back the points.
  ///
  /// A node that is part of lines and areas and says something of its own
  /// is taken out of them and left where it was, and an untagged node takes
  /// its place in them. What a line or an area is — a shop in a building, a
  /// cafe drawn as its outline — moves onto a new point in the middle of
  /// it, and what makes it the shape it is stays: a building keeps its
  /// building tags, anything keeps its address, and an area that would no
  /// longer be one is told it is.
  List<OsmNode> apply() {
    final points = <OsmNode>[];
    _asOne(_view.edits, () {
      for (final element in selected) {
        switch (element) {
          case OsmNode():
            points.add(_fromNode(element));
          case OsmWay():
            points.add(_fromWay(element));
          case OsmRelation():
            break;
        }
      }
    });
    return points;
  }

  OsmNode _fromNode(OsmNode node) {
    final edits = _view.edits;
    final replacement = edits.createNode(
      latitude: node.latitude,
      longitude: node.longitude,
    );
    for (final way in _view.waysUsing(node.id)) {
      edits.setWayNodes(way, [
        for (final id in way.nodeIds) id == node.id ? replacement.id : id,
      ]);
    }
    return _view.node(node.id) ?? node;
  }

  OsmNode _fromWay(OsmWay way) {
    final geometry = _view.geometryOf(way);
    final tags = Map.of(way.tags);
    final point = <String, String>{};
    final building = _isYes(tags['building']) || _isYes(tags['building:part']);
    final indoor =
        geometry == OsmGeometry.area && _indoorAreas.contains(tags['indoor']);
    for (final MapEntry(:key, :value) in way.tags.entries) {
      if (key == 'area') continue;
      if (building &&
          (_buildingKeys.contains(key) ||
              key.startsWith('building:') ||
              key.startsWith('roof:'))) {
        continue;
      }
      if (indoor && key == 'indoor') continue;
      point[key] = value;
      final shared = key == 'source' ||
          key == 'wheelchair' ||
          key.startsWith('addr:') ||
          (indoor && key == 'level');
      if (!shared) tags.remove(key);
    }
    if (!building && !indoor && geometry == OsmGeometry.area) {
      tags['area'] = 'yes';
    }
    final (latitude, longitude) = _middleOf(way, geometry);
    final extracted = _view.edits.createNode(
      latitude: latitude,
      longitude: longitude,
      tags: point,
    );
    _view.edits.setTags(way, tags);
    return extracted;
  }

  static bool _isYes(String? value) => value != null && value != 'no';

  static const _indoorAreas = {'area', 'corridor', 'elevator', 'level', 'room'};

  static const _buildingKeys = {
    'architect',
    'building',
    'height',
    'layer',
    'nycdoitt:bin',
    'ref:GB:uprn',
    'ref:linz:building_id',
  };

  /// The middle of [way]: the centre of the area it encloses, or the point
  /// half way along it by length. Worked out on the map, as iD does, and
  /// the middle of its nodes if that comes to nothing.
  (double, double) _middleOf(OsmWay way, OsmGeometry geometry) {
    final xs = <double>[];
    final ys = <double>[];
    for (final id in way.nodeIds) {
      final node = _view.node(id);
      if (node == null) continue;
      // Each brought round beside the one before, so that a way across the
      // antimeridian is measured across it rather than round the world.
      final x = Mercator.x(node.longitude);
      xs.add(xs.isEmpty ? x : Mercator.nearest(x, xs.last));
      ys.add(Mercator.y(node.latitude));
    }
    if (xs.isEmpty) return (0, 0);

    double? x, y;
    if (geometry == OsmGeometry.area && xs.length >= 3) {
      // Worked out from the first corner rather than from the corner of the
      // world. A building is a few millionths of the world across, and the
      // products the area is made of, taken from half the world away, are
      // so much larger than it that most of it is lost in the rounding.
      final ox = xs.first, oy = ys.first;
      var twiceArea = 0.0, cx = 0.0, cy = 0.0;
      for (var i = 0; i < xs.length; i++) {
        final j = (i + 1) % xs.length;
        final xi = xs[i] - ox, yi = ys[i] - oy;
        final xj = xs[j] - ox, yj = ys[j] - oy;
        final cross = xi * yj - xj * yi;
        twiceArea += cross;
        cx += (xi + xj) * cross;
        cy += (yi + yj) * cross;
      }
      if (twiceArea != 0) {
        x = ox + cx / (3 * twiceArea);
        y = oy + cy / (3 * twiceArea);
      }
    } else if (xs.length >= 2) {
      var length = 0.0, cx = 0.0, cy = 0.0;
      for (var i = 0; i + 1 < xs.length; i++) {
        final dx = xs[i + 1] - xs[i], dy = ys[i + 1] - ys[i];
        final segment = math.sqrt(dx * dx + dy * dy);
        length += segment;
        cx += (xs[i] + xs[i + 1]) / 2 * segment;
        cy += (ys[i] + ys[i + 1]) / 2 * segment;
      }
      if (length > 0) {
        x = cx / length;
        y = cy / length;
      }
    }
    x ??= xs.reduce((a, b) => a + b) / xs.length;
    y ??= ys.reduce((a, b) => a + b) / ys.length;
    return (Mercator.latitude(y), Mercator.wrappedLongitude(x));
  }
}

/// The lines that selecting [selected] would continue drawing, or null if
/// the selection is not one a line is continued from.
///
/// One vertex has to be selected, and at most one line with it. The lines
/// are those not yet closed that start or stop at the vertex, and if a line
/// is selected, only that one: there has to be exactly one to continue, and
/// selecting the line is how one is chosen from several.
List<OsmWay>? osmContinuable(OsmEditView view, List<OsmElement> selected) {
  final vertices = [
    for (final element in selected)
      if (element is OsmNode && view.geometryOf(element) == OsmGeometry.vertex)
        element,
  ];
  if (vertices.length != 1) return null;
  final vertex = vertices.single;
  final lines = [
    for (final element in selected)
      if (element is OsmWay && view.geometryOf(element) == OsmGeometry.line)
        element,
  ];
  if (lines.length > 1) return null;
  return [
    for (final way in view.waysUsing(vertex.id))
      if (!way.isClosed &&
          (way.nodeIds.first == vertex.id || way.nodeIds.last == vertex.id) &&
          (lines.isEmpty || lines.single.id == way.id))
        way,
  ];
}

/// What was copied: the elements as they stood when they were, and the
/// nodes of any ways among them, to make new ones from however they have
/// changed since.
class OsmCopied {
  /// The elements copied, without the nodes of copied ways.
  final List<OsmElement> elements;

  /// Every node needed to copy them, by id: the nodes copied, and the nodes
  /// of the ways copied.
  final Map<int, OsmNode> nodes;

  /// Where on the map the copies are to be anchored: the point the pointer
  /// was at when they were copied, so that pasting puts them the same way
  /// round the pointer. Null to anchor them by their middle instead.
  final (double, double)? anchor;

  const OsmCopied._(this.elements, this.nodes, this.anchor);

  /// How many things were copied.
  int get length => elements.length;

  /// The middle of what was copied, in world coordinates.
  (double, double) get middle {
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    double? first;
    for (final node in nodes.values) {
      // All on the same side of the antimeridian as the first.
      final raw = Mercator.x(node.longitude);
      final x = first == null ? raw : Mercator.nearest(raw, first);
      first ??= x;
      final y = Mercator.y(node.latitude);
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
    }
    return ((left + right) / 2, (top + bottom) / 2);
  }
}

/// Copies [selected], as iD copies it, or null if there is nothing in it to
/// copy.
///
/// A node along a way that says nothing of its own is part of the way, not
/// something to copy on its own; a way is copied with its nodes. [anchor]
/// is where on the map, in world coordinates, the pointer was; a single
/// node needs none, being its own anchor.
OsmCopied? osmCopy(
  OsmEditView view,
  List<OsmElement> selected, {
  (double, double)? anchor,
}) {
  final chosen = [
    for (final element in selected)
      if (osmHasInterestingTags(element.tags) ||
          view.geometryOf(element) != OsmGeometry.vertex)
        element,
  ];
  final elements = <OsmElement>[];
  final nodes = <int, OsmNode>{};
  for (final way in chosen.whereType<OsmWay>()) {
    final now = view.way(way.id);
    if (now == null) continue;
    elements.add(now);
    for (final id in now.nodeIds) {
      if (view.node(id) case final node?) nodes[id] = node;
    }
  }
  for (final node in chosen.whereType<OsmNode>()) {
    if (nodes.containsKey(node.id)) continue;
    final now = view.node(node.id);
    if (now == null) continue;
    elements.add(now);
    nodes[now.id] = now;
  }
  if (elements.isEmpty) return null;
  final single = elements.length == 1 && elements.single is OsmNode;
  return OsmCopied._(elements, nodes, single ? null : anchor);
}

/// Adds a copy of [copied] to [edits], [dx] and [dy] across the world from
/// where it was, as one change, and gives back the copies of what was
/// copied — not the nodes of copied ways, which come with them.
///
/// Everything is new: new nodes, new ways through them, and the same tags.
List<OsmElement> osmPaste(
  OsmEdits edits,
  OsmCopied copied, {
  required double dx,
  required double dy,
}) {
  final made = <OsmElement>[];
  _asOne(edits, () {
    final newNodes = <int, OsmNode>{};
    OsmNode copyOf(int id) => newNodes[id] ??= () {
          final node = copied.nodes[id]!;
          return edits.createNode(
            latitude: Mercator.latitude(
              (Mercator.y(node.latitude) + dy).clamp(0.0, 1.0),
            ),
            longitude:
                Mercator.wrappedLongitude(Mercator.x(node.longitude) + dx),
            tags: node.tags,
          );
        }();
    for (final element in copied.elements) {
      switch (element) {
        case OsmNode():
          made.add(copyOf(element.id));
        case OsmWay():
          made.add(
            edits.createWay(
              nodeIds: [for (final id in element.nodeIds) copyOf(id).id],
              tags: element.tags,
            ),
          );
        case OsmRelation():
          break;
      }
    }
  });
  return made;
}

/// Moves [selected] [dx] and [dy] across the world, as one change: every
/// node selected, and every node of every way selected, once.
///
/// Ways joined to them but not selected stretch to follow.
void osmMove(
  OsmEditView view,
  List<OsmElement> selected, {
  required double dx,
  required double dy,
}) {
  final ids = <int>{
    for (final element in selected)
      ...switch (element) {
        OsmNode() => [element.id],
        OsmWay() => view.way(element.id)?.nodeIds ?? element.nodeIds,
        OsmRelation() => const <int>[],
      },
  };
  _asOne(view.edits, () {
    for (final id in ids) {
      final node = view.node(id);
      if (node == null) continue;
      view.edits.moveNode(
        node,
        latitude: Mercator.latitude(
          (Mercator.y(node.latitude) + dy).clamp(0.0, 1.0),
        ),
        longitude: Mercator.wrappedLongitude(Mercator.x(node.longitude) + dx),
      );
    }
  });
}

/// The rules for tags that OpenStreetMap's editors commonly follow, so that
/// an edit made with them is the edit somebody who knows those editors
/// expects.
library;

import 'country_coder.dart';
import 'edit.dart';
import 'element.dart';
import 'presets.dart';
import 'tag_rules.dart';

/// The rules for what tags mean when editing that OpenStreetMap is commonly
/// edited by.
///
/// Which closed ways are areas, and which kinds of thing a way could also be
/// drawn as a point, come from the tagging schema, [presets], once it is
/// known; until then [isArea] asks [isAreaWithoutPresets]. Kinds of thing
/// that only exist in some places are chosen by where the element is, which
/// [countryCoder] says once it is known.
class OsmStandardTagRules extends OsmPlainTagRules {
  /// A way that is part of a route or a boundary, or the outside of a
  /// multipolygon, which deleting would leave a hole in.
  static const partOfRelation = OsmDisabledReason('part_of_relation');

  /// Something linked from Wikidata, which is not deleted by accident.
  static const hasWikidataTag = OsmDisabledReason('has_wikidata_tag');

  /// The tagging schema, if it is known yet.
  OsmPresets? presets;

  /// Which country and regions a place is in, if that is known yet.
  OsmCountryCoder? countryCoder;

  /// Whether a closed way with these tags is an area while there are no
  /// [presets] to say.
  final bool Function(Map<String, String> tags) isAreaWithoutPresets;

  /// Creates the rules, with whatever of [presets] and [countryCoder] is
  /// known so far.
  ///
  /// [isAreaWithoutPresets] by default takes a building, or anything saying
  /// `area=yes`, to be an area, and nothing saying `area=no`.
  OsmStandardTagRules({
    this.presets,
    this.countryCoder,
    bool Function(Map<String, String> tags)? isAreaWithoutPresets,
  }) : isAreaWithoutPresets = isAreaWithoutPresets ?? _isArea;

  static bool _isArea(Map<String, String> tags) =>
      tags['area'] != 'no' &&
      (tags.containsKey('building') || tags['area'] == 'yes');

  /// Every code of every region [element] is in, by where it now is in
  /// [editor]: a node where it stands, and a way where it starts. What
  /// [OsmPresets.match] and [OsmPreset.appliesAt] take as `here`.
  ///
  /// Empty while [countryCoder] is not known, or for something with nowhere
  /// to stand, which leaves only what is meant for everywhere.
  Set<String> regionsOf(OsmElement element, OsmEditor editor) {
    final coder = countryCoder;
    if (coder == null) return const {};
    final standing = switch (element) {
      OsmNode() => editor.node(element.id) ?? element,
      OsmWay() when element.nodeIds.isNotEmpty =>
        editor.node(element.nodeIds.first),
      _ => null,
    };
    if (standing == null) return const {};
    return coder.codesAt(standing.latitude, standing.longitude);
  }

  @override
  bool isArea(Map<String, String> tags) =>
      presets?.isArea(tags) ?? isAreaWithoutPresets(tags);

  /// Whether [tags] say something about what a thing is, rather than only
  /// where the data came from: anything but `source`, `created_by` and the
  /// like, and ids in other databases.
  @override
  bool isDescriptive(Map<String, String> tags) => _isInteresting(tags);

  /// A way that is part of a route or a boundary, or an outer edge of a
  /// multipolygon, would leave a hole in something larger, and has to be
  /// taken out of it first. Something with a Wikidata tag is somebody's
  /// careful work, linked from elsewhere, and is not deleted by accident.
  @override
  OsmDisabledReason? whyProtected(OsmElement element, OsmEditor editor) {
    if (element is OsmWay) {
      for (final relation
          in editor.relationsUsing(OsmElementType.way, element.id)) {
        final kind = kindOf(relation);
        for (final member in relation.members) {
          if (member.type != OsmElementType.way || member.ref != element.id) {
            continue;
          }
          final role = member.role.isEmpty ? 'outer' : member.role;
          if (kind == OsmRelationKind.route ||
              kind == OsmRelationKind.boundary ||
              (kind == OsmRelationKind.multipolygon && role == 'outer')) {
            return partOfRelation;
          }
        }
      }
    }
    if ((element.tags['wikidata'] ?? '').trim().isNotEmpty) {
      return hasWikidataTag;
    }
    return null;
  }

  /// Keys ending or containing `:left`, `:right`, `:forward` and
  /// `:backward` swap, as do those words as values, and `up` and `down`. A
  /// numeric `incline` changes sign. Standing alone, a key ending in
  /// `direction` has its compass point or bearing turned half way round as
  /// well. Names, notes and the like are left as they are whatever words
  /// are in them, as are turn lanes, which are left and right of the lane.
  @override
  Map<String, String> reversed(
    Map<String, String> tags, {
    required bool standalone,
    bool oneway = false,
  }) =>
      _reversedTags(tags, absolute: standalone, oneway: oneway);

  @override
  String reversedRole(String role) => _roles[role] ?? role;

  /// A cliff, a kerb, a coast and the like, whose direction says which side
  /// is which, unless it says `two_sided=yes`.
  @override
  bool isSided(Map<String, String> tags) => _isSided(tags);

  /// Two descriptive values for the same key that differ, except where they
  /// are counts that add up.
  @override
  bool conflicts(Map<String, String> a, Map<String, String> b) {
    for (final MapEntry(:key, :value) in b.entries) {
      final had = a[key];
      if (had == null || had.isEmpty || had == value) continue;
      if (_canSum(key, a, b)) continue;
      if (_isInteresting({key: had})) return true;
    }
    return false;
  }

  /// Counts add up; otherwise as [combined].
  @override
  Map<String, String> joined(
    Map<String, String> into,
    Map<String, String> b,
  ) =>
      _mergeTags(into, b, set: {
        for (final key in b.keys)
          if (_canSum(key, b, into))
            key: '${num.parse(b[key]!) + num.parse(into[key]!)}',
      });

  /// A key only one has is kept, and two different values become both,
  /// separated by semicolons.
  @override
  Map<String, String> combined(
    Map<String, String> into,
    Map<String, String> b,
  ) =>
      _mergeTags(into, b);

  /// Counts along the way, such as `step_count`, are shared out by length.
  @override
  (Map<String, String>, Map<String, String>) divided(
    Map<String, String> tags,
    double share,
  ) {
    final a = Map.of(tags), b = Map.of(tags);
    for (final key in tags.keys) {
      if (!_summable.contains(key)) continue;
      final count = num.tryParse(tags[key]!);
      if (count == null || count <= 0 || count != count.round()) continue;
      final countA = (count * share).round();
      a[key] = '$countA';
      b[key] = '${count.round() - countA}';
    }
    return (a, b);
  }

  /// What a line or an area is — a shop in a building, a cafe drawn as its
  /// outline — goes to the point when the kind of thing it is can be a
  /// point, and what makes it the shape it is stays: a building keeps its
  /// building tags, anything keeps its address, and an area that would no
  /// longer be one is told it is. Nothing is pulled out while the [presets]
  /// are not known.
  @override
  ({Map<String, String> point, Map<String, String> way})? extracted(
    OsmWay way,
    OsmEditor editor,
  ) {
    final presets = this.presets;
    if (presets == null || !isDescriptive(way.tags)) return null;
    final geometry = editor.geometryOf(way);
    final preset = presets.match(
      way.tags,
      geometry,
      here: regionsOf(way, editor),
    );
    if (!preset.geometry.contains(OsmGeometry.point)) return null;

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
    return (point: point, way: tags);
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

  /// A coastline stays on the way; everything else goes to the relation.
  @override
  ({Map<String, String> relation, Map<String, String> way}) intoMultipolygon(
    Map<String, String> tags,
  ) {
    final relation = Map.of(tags)..remove('area');
    final way = <String, String>{};
    for (final MapEntry(:key, :value) in tags.entries) {
      if (_wayOnly[key]?.contains(value) ?? false) {
        way[key] = value;
        relation.remove(key);
      }
    }
    return (relation: relation, way: way);
  }
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
/// where the data came from.
bool _isInteresting(Map<String, String> tags) => tags.keys.any(
      (key) =>
          !_uninterestingKeys.contains(key) && !_uninterestingKey.hasMatch(key),
    );

/// [tags] turned round for something that now faces the other way.
///
/// Keys ending or containing `:left`, `:right`, `:forward` and `:backward`
/// swap, as do those words as values, and `up` and `down`. A numeric
/// `incline` changes sign. With [absolute], a key ending in `direction` has
/// its compass point or bearing turned half way round as well, which is
/// right for a node standing on its own and wrong for one along a line.
/// Names, notes and the like are left as they are whatever words are in
/// them, as are turn lanes, which are left and right of the lane.
Map<String, String> _reversedTags(
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

/// [value] as a bearing is written: no `.0` on a whole number.
String _number(num value) =>
    value == value.truncate() ? value.truncate().toString() : value.toString();

const _roles = {
  'forward': 'backward',
  'backward': 'forward',
  'forwards': 'backward',
  'backwards': 'forward',
};

/// [into] with [tags] merged in: a key only one has is
/// kept, and two different values become both, separated by semicolons.
/// Keys in [set] are set outright.
Map<String, String> _mergeTags(
  Map<String, String> into,
  Map<String, String> tags, {
  Map<String, String> set = const {},
}) {
  final merged = Map.of(into);
  for (final MapEntry(:key, :value) in tags.entries) {
    if (set.containsKey(key)) continue;
    final had = into[key];
    if (had == null || had.isEmpty) {
      merged[key] = value;
    } else if (had != value) {
      final parts = <String>[
        ...had.split(RegExp(r';\s*')),
        for (final part in value.split(RegExp(r';\s*')))
          if (!had.split(RegExp(r';\s*')).contains(part)) part,
      ];
      final joined = parts.join(';');
      merged[key] = joined.length > 255 ? joined.substring(0, 255) : joined;
    }
  }
  merged.addAll(set);
  return merged;
}

/// Keys whose values add up when two ways become one, and split between
/// them when one becomes two.
const _summable = {
  'step_count',
  'parking:both:capacity',
  'parking:left:capacity',
  'parking:right:capacity',
};

bool _canSum(String key, Map<String, String> a, Map<String, String> b) =>
    _summable.contains(key) &&
    num.tryParse(a[key] ?? '') != null &&
    num.tryParse(b[key] ?? '') != null;

/// Tags that stay on a way rather than going to the multipolygon it
/// becomes part of.
const _wayOnly = {
  'natural': {'coastline'},
};

/// Features with a right side and a wrong side — a cliff, a kerb, a coast —
/// whose direction says which is which.
const _sided = {
  'natural': {'cliff', 'coastline'},
  'barrier': {'retaining_wall', 'kerb', 'guard_rail', 'city_wall'},
  'man_made': {'embankment', 'quay'},
  'waterway': {'weir'},
  'cutting': {'yes', 'both', 'left', 'right'},
  'embankment': {'yes', 'dyke', 'both', 'left', 'right'},
};

const _lifecycle = {
  'proposed',
  'planned',
  'construction',
  'disused',
  'abandoned',
  'was',
  'dismantled',
  'razed',
  'demolished',
  'destroyed',
  'removed',
  'intermittent',
};

bool _isSided(Map<String, String> tags) {
  if (tags['two_sided'] == 'yes') return false;
  for (final MapEntry(key: raw, :value) in tags.entries) {
    final colon = raw.indexOf(':');
    final key = colon > 0 && _lifecycle.contains(raw.substring(0, colon))
        ? raw.substring(colon + 1)
        : raw;
    if (_sided[key]?.contains(value) ?? false) return true;
  }
  return false;
}

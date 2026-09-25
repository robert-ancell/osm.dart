/// What kinds of thing there are on the map, and which kind an element is.
///
/// Read from the OpenStreetMap tagging schema,
/// <https://github.com/openstreetmap/id-tagging-schema>, which a good many
/// editors describe OpenStreetMap's tagging with. A preset is one kind of thing
/// — a cafe, a residential road, a house — with the tags that say an element is
/// one, the shapes it can take, and the words it goes by. Matching an element
/// to its preset is scored as the schema's own editor scores it, so an element
/// is called the same thing here as it is there.
///
/// The schema is © its contributors, under the ISC licence.
library;

import 'element.dart';
import 'json_exception.dart';

/// Where a preset applies, by the codes of the places it is meant for.
///
/// Countries by their ISO codes and larger regions by their Wikidata ids,
/// as the schema writes them. The whole world is `001`, or `planet`.
class OsmLocationSet {
  /// What it applies to.
  final Set<String> include;

  /// What it does not, even inside what it applies to.
  final Set<String> exclude;

  /// Creates a set of places.
  const OsmLocationSet({required this.include, this.exclude = const {}});

  static const _world = {'001', 'planet'};

  /// Whether it applies at a place that is inside every region in [here].
  ///
  /// Everywhere is always inside the world, so an empty [here] is a place
  /// nothing more is known about: what is meant for the whole world applies
  /// there, and what is meant for one country does not.
  bool appliesAt(Set<String> here) {
    final at = {..._world, for (final code in here) code.toLowerCase()};
    return include.any(at.contains) && !exclude.any(at.contains);
  }

  static OsmLocationSet? _parse(Object? json) {
    if (json is! Map) return null;
    Set<String> codes(Object? list) => {
          if (list is List)
            for (final code in list)
              // A point and a radius, or a shape in a file of its own, is a
              // place this cannot place anything in; it is left out, so a
              // preset only for one never applies and one excluding one still
              // applies everywhere else.
              if (code is String) code.toLowerCase(),
        };
    return OsmLocationSet(
      include: codes(json['include']),
      exclude: codes(json['exclude']),
    );
  }
}

/// One kind of thing on the map.
class OsmPreset {
  /// Its id in the schema, such as `amenity/cafe`.
  final String id;

  /// What it is called, such as `Cafe`.
  final String name;

  /// The tags that say an element is one. A value of `*` means any value.
  final Map<String, String> tags;

  /// The tags an element is given when it is made one.
  final Map<String, String> addTags;

  /// The tags taken off an element when it stops being one.
  final Map<String, String> removeTags;

  /// The shapes it can take.
  final Set<OsmGeometry> geometry;

  /// How strongly matching its tags says an element is one of these.
  final double matchScore;

  /// Whether it is offered when searching. Some exist only to put a name to
  /// something already on the map.
  final bool searchable;

  /// Other words it can be found by.
  final List<String> terms;

  /// Other names it goes by.
  final List<String> aliases;

  /// The id of the preset this one has been replaced by, if it has been.
  final String? replacement;

  /// Where it applies, or null for everywhere.
  final OsmLocationSet? locationSet;

  /// The name of its icon in the schema's icon sets, such as `maki-cafe`.
  final String? icon;

  /// Creates a preset.
  const OsmPreset({
    required this.id,
    required this.name,
    required this.tags,
    required this.addTags,
    required this.removeTags,
    required this.geometry,
    this.matchScore = 1,
    this.searchable = true,
    this.terms = const [],
    this.aliases = const [],
    this.replacement,
    this.locationSet,
    this.icon,
  });

  /// Whether it applies at a place inside the regions in [here]; see
  /// [OsmLocationSet.appliesAt].
  bool appliesAt(Set<String> here) => locationSet?.appliesAt(here) ?? true;

  /// How well [elementTags] say an element is one of these, or a negative
  /// number if they say it is not.
  ///
  /// Every tag of the preset has to be there: its own value scores in full,
  /// and any value for a `*` scores half. The tags it would add score as
  /// well, so the preset that says most about an element wins.
  double score(Map<String, String> elementTags) {
    var score = 0.0;
    for (final MapEntry(:key, :value) in tags.entries) {
      final has = elementTags[key];
      if (has == value) {
        score += matchScore;
      } else if (value == '*' && has != null) {
        score += matchScore / 2;
      } else {
        return -1;
      }
    }
    for (final MapEntry(:key, :value) in addTags.entries) {
      if (!tags.containsKey(key) && elementTags[key] == value) {
        score += matchScore;
      }
    }
    // A preset that is not offered loses a tie to one that is.
    return searchable ? score : score * 0.999;
  }

  /// [elementTags] with this preset's tags taken off, as they are when an
  /// element stops being one of these: its own tags go, and so does any
  /// `area` tag, which belonged to what it was.
  Map<String, String> removeFrom(Map<String, String> elementTags) => {
        for (final MapEntry(:key, :value) in elementTags.entries)
          if (!removeTags.containsKey(key) && key != 'area') key: value,
      };

  /// [elementTags] with this preset's tags added, as they are when an
  /// element of [geometry] is made one of these.
  ///
  /// A tag the preset gives as `*` is set to `yes`, unless it is only there
  /// to go with the preset and the element already has a value for it. An
  /// area that would not be taken for one by its tags alone is given
  /// `area=yes`, so that it stays one.
  Map<String, String> applyTo(
    Map<String, String> elementTags,
    OsmGeometry geometry,
    OsmPresets presets,
  ) {
    final out = Map<String, String>.of(elementTags);
    for (final MapEntry(:key, :value) in addTags.entries) {
      if (value == '*') {
        if (tags.containsKey(key) || !out.containsKey(key)) out[key] = 'yes';
      } else {
        out[key] = value;
      }
    }
    if (!addTags.containsKey('area')) {
      out.remove('area');
      if (geometry == OsmGeometry.area && !_saysArea(presets)) {
        out['area'] = 'yes';
      }
    }
    return out;
  }

  /// Whether this preset's own tags are enough to say a closed way is an
  /// area.
  bool _saysArea(OsmPresets presets) {
    for (final MapEntry(:key, :value) in addTags.entries) {
      if (!geometry.contains(OsmGeometry.line) &&
          presets._areaKeys.containsKey(key)) {
        return true;
      }
      // Any value it lists, either way.
      if (_areaExceptions[key]?.containsKey(value) ?? false) return true;
    }
    return false;
  }

  @override
  String toString() => 'OsmPreset($id)';
}

/// A group of presets offered together, such as buildings or roads.
class OsmPresetCategory {
  /// Its id in the schema, such as `category-building`.
  final String id;

  /// What it is called, such as `Buildings`.
  final String name;

  /// The ids of the presets in it, in the order they are offered.
  final List<String> members;

  /// Creates a category.
  const OsmPresetCategory({
    required this.id,
    required this.name,
    required this.members,
  });

  @override
  String toString() => 'OsmPresetCategory($id)';
}

/// Keys whose tags usually make a line but make an area with these values,
/// and values of `emergency` that are not an emergency feature at all.
const _areaExceptions = <String, Map<String, bool>>{
  'highway': {'elevator': true, 'rest_area': true, 'services': true},
  'public_transport': {'platform': true},
  'railway': {
    'platform': true,
    'roundhouse': true,
    'station': true,
    'traverser': true,
    'turntable': true,
    'wash': true,
    'ventilation_shaft': true,
  },
  'waterway': {'dam': true},
  'amenity': {'bicycle_parking': true},
  'emergency': {
    'yes': false,
    'no': false,
    'private': false,
    'designated': false,
    'destination': false,
    'official': false,
  },
};

/// Prefixes that say a feature is not there in the ordinary way — planned,
/// disused, demolished — and leave what it is the same.
const _lifecyclePrefixes = {
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

/// Keys that say what a line is, never what an area is, whatever presets
/// there are for them as areas.
const _lineKeys = {
  'barrier',
  'highway',
  'footway',
  'railway',
  'junction',
  'type',
};

/// Every preset, and what is needed to find the right one.
class OsmPresets {
  /// Every preset, by id.
  final Map<String, OsmPreset> byId;

  /// Every category, by id.
  final Map<String, OsmPresetCategory> categories;

  /// What to offer for each shape before anything has been searched for:
  /// the ids of presets and categories, in order.
  final Map<OsmGeometry, List<String>> defaults;

  /// The presets that can be each shape, indexed by the first key of their
  /// tags, which every element they match has to have.
  final Map<OsmGeometry, Map<String, List<OsmPreset>>> _byKey;

  /// Keys that make a closed way an area, each with the values that make it
  /// a line after all.
  final Map<String, Set<String>> _areaKeys;

  OsmPresets._(this.byId, this.categories, this.defaults)
      : _byKey = _index(byId.values),
        _areaKeys = _findAreaKeys(byId.values);

  /// No presets at all: what there is before the schema has been read.
  ///
  /// Everything matches only a [fallback], and no closed way is an area by
  /// its tags, so a program that decides that some other way until the
  /// schema is in should go on doing so while [byId] is empty.
  OsmPresets.empty() : this._(const {}, const {}, const {});

  /// Presets read from the schema's own files.
  ///
  /// [presets] is `presets.json`; [translations] is the language's file,
  /// such as `translations/en.json`, which is where every name and search
  /// word is. [categories] and [defaults] are `preset_categories.json` and
  /// `preset_defaults.json`, and can be left out.
  ///
  /// Throws an [OsmJsonException] if any of them is not JSON.
  factory OsmPresets.parse({
    required String presets,
    required String translations,
    String? categories,
    String? defaults,
  }) {
    final words = _wordsOf(decodeJson(translations, 'The translations'));
    final presetWords = _map(words['presets']);
    final categoryWords = _map(words['categories']);

    final raw = _map(decodeJson(presets, 'The presets'));

    /// The words for [id]. A preset can borrow another's by being named
    /// `{other/id}` — the same thing drawn another way, or found in another
    /// place — and has none of its own.
    Map<String, Object?> wordsFor(String id, [int depth = 0]) {
      final own = _map(presetWords[id]);
      if (own.isNotEmpty || depth > 4) return own;
      final named = _string(_map(raw[id])['name']);
      if (named == null || !named.startsWith('{') || !named.endsWith('}')) {
        return own;
      }
      return wordsFor(named.substring(1, named.length - 1), depth + 1);
    }

    final byId = <String, OsmPreset>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      if (value is! Map) continue;
      final said = wordsFor(key);
      byId[key] = OsmPreset(
        id: key,
        name: _string(said['name']) ?? key,
        tags: _tags(value['tags']),
        addTags: _tags(value['addTags'] ?? value['tags']),
        removeTags: _tags(
          value['removeTags'] ?? value['addTags'] ?? value['tags'],
        ),
        geometry: {
          for (final shape in _list(value['geometry']))
            if (OsmGeometry.values.asNameMap()[shape] case final known?) known,
        },
        matchScore: (value['matchScore'] as num?)?.toDouble() ?? 1,
        searchable: value['searchable'] != false,
        terms: _split(said['terms'], ','),
        aliases: _split(said['aliases'], '\n'),
        replacement: _string(value['replacement']),
        locationSet: OsmLocationSet._parse(value['locationSet']),
        icon: _string(value['icon']),
      );
    }

    final groups = <String, OsmPresetCategory>{};
    if (categories != null) {
      for (final MapEntry(:key, :value)
          in _map(decodeJson(categories, 'The categories')).entries) {
        if (value is! Map) continue;
        groups[key] = OsmPresetCategory(
          id: key,
          name: _string(_map(categoryWords[key])['name']) ?? key,
          members: [
            for (final member in _list(value['members']))
              if (member is String && byId.containsKey(member)) member,
          ],
        );
      }
    }

    final offered = <OsmGeometry, List<String>>{};
    if (defaults != null) {
      for (final MapEntry(:key, :value)
          in _map(decodeJson(defaults, 'The defaults')).entries) {
        final shape = OsmGeometry.values.asNameMap()[key];
        if (shape == null) continue;
        offered[shape] = [
          for (final id in _list(value))
            if (id is String &&
                (byId.containsKey(id) || groups.containsKey(id)))
              id,
        ];
      }
    }

    return OsmPresets._(byId, groups, offered);
  }

  /// The preset [tags] on something of [geometry] say it is, at a place in
  /// the regions [here].
  ///
  /// The best scoring preset that can be that shape and applies there, and
  /// failing any, the plain point, line or area — so there is always an
  /// answer, even for something the schema has never heard of.
  OsmPreset match(
    Map<String, String> tags,
    OsmGeometry geometry, {
    Set<String> here = const {},
  }) {
    final index = _byKey[geometry] ?? const {};
    OsmPreset? best;
    var bestScore = -1.0;
    void consider(Iterable<OsmPreset> candidates) {
      for (final preset in candidates) {
        if (!preset.appliesAt(here)) continue;
        final score = preset.score(tags);
        if (score > bestScore) {
          bestScore = score;
          best = preset;
        }
      }
    }

    for (final key in tags.keys) {
      consider(index[key] ?? const []);
    }
    // And the ones with no tags of their own, which match anything.
    consider(index[''] ?? const []);
    return best ?? fallback(geometry);
  }

  /// The plain preset for something of [geometry] that is nothing more
  /// particular.
  OsmPreset fallback(OsmGeometry geometry) {
    final id = switch (geometry) {
      OsmGeometry.point || OsmGeometry.vertex => 'point',
      OsmGeometry.line => 'line',
      OsmGeometry.area => 'area',
      OsmGeometry.relation => 'relation',
    };
    return byId[id] ??
        OsmPreset(
          id: id,
          name: id[0].toUpperCase() + id.substring(1),
          tags: const {},
          addTags: const {},
          removeTags: const {},
          geometry: {geometry},
          matchScore: 0.1,
        );
  }

  /// Whether a closed way tagged [tags] encloses an area rather than being a
  /// line that happens to come back to where it started.
  ///
  /// `area=yes` and `area=no` say so outright; otherwise
  /// it is an area if any of its keys is one there are area presets for and
  /// its value is not one that makes that key a line. A key with a
  /// lifecycle prefix, such as `disused:amenity`, counts as the key.
  bool isArea(Map<String, String> tags) {
    final area = tags['area'];
    if (area == 'yes') return true;
    if (area == 'no') return false;
    for (final MapEntry(key: raw, :value) in tags.entries) {
      final key = _withoutLifecycle(raw);
      final exception = _areaExceptions[key]?[value];
      if (exception == false) continue;
      final lines = _areaKeys[key];
      if (lines != null && !lines.contains(value)) return true;
      if (exception == true) return true;
    }
    return false;
  }

  /// The presets of [geometry] that [query] finds, best first, at a place in
  /// the regions [here].
  ///
  /// By name first — the whole of it, then its start, then the start of a
  /// word in it — then by the other names and words it goes by, then
  /// anywhere in its name. Only presets that are offered and have not been
  /// replaced are found.
  List<OsmPreset> search(
    String query,
    OsmGeometry geometry, {
    Set<String> here = const {},
    int limit = 50,
  }) {
    final wanted = query.trim().toLowerCase();
    if (wanted.isEmpty) return const [];
    final ranked = <(int, OsmPreset)>[];
    for (final preset in byId.values) {
      if (!preset.searchable || preset.replacement != null) continue;
      if (!preset.geometry.contains(geometry)) continue;
      if (!preset.appliesAt(here)) continue;
      final rank = _rank(preset, wanted);
      if (rank != null) ranked.add((rank, preset));
    }
    ranked.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);
      if (byRank != 0) return byRank;
      final byLength = a.$2.name.length.compareTo(b.$2.name.length);
      if (byLength != 0) return byLength;
      return a.$2.name.compareTo(b.$2.name);
    });
    return [for (final (_, preset) in ranked.take(limit)) preset];
  }

  /// How well [preset] answers [query], lower being better, or null if it
  /// does not.
  static int? _rank(OsmPreset preset, String query) {
    final name = preset.name.toLowerCase();
    if (name == query) return 0;
    if (name.startsWith(query)) return 1;
    if (name.split(RegExp(r'[\s\-/]+')).any((w) => w.startsWith(query))) {
      return 2;
    }
    for (final other in [...preset.aliases, ...preset.terms]) {
      if (other.toLowerCase().startsWith(query)) return 3;
    }
    if (name.contains(query)) return 4;
    return null;
  }

  static Map<OsmGeometry, Map<String, List<OsmPreset>>> _index(
    Iterable<OsmPreset> presets,
  ) {
    final index = <OsmGeometry, Map<String, List<OsmPreset>>>{};
    for (final preset in presets) {
      final key = preset.tags.keys.firstOrNull ?? '';
      for (final shape in preset.geometry) {
        ((index[shape] ??= {})[key] ??= []).add(preset);
      }
    }
    return index;
  }

  /// The keys that make a closed way an area, and for each the values that
  /// make it a line after all, worked out from the presets.
  static Map<String, Set<String>> _findAreaKeys(Iterable<OsmPreset> presets) {
    final keys = <String, Set<String>>{};
    final current = [
      for (final preset in presets)
        if (preset.replacement == null) preset,
    ];
    for (final preset in current) {
      final key = preset.tags.keys.firstOrNull;
      if (key == null || _lineKeys.contains(key)) continue;
      if (preset.geometry.contains(OsmGeometry.area)) keys[key] ??= {};
    }
    for (final preset in current) {
      if (!preset.geometry.contains(OsmGeometry.line)) continue;
      for (final MapEntry(:key, :value) in preset.addTags.entries) {
        if (value != '*') keys[key]?.add(value);
      }
    }
    return keys;
  }

  static String _withoutLifecycle(String key) {
    final colon = key.indexOf(':');
    if (colon < 0) return key;
    return _lifecyclePrefixes.contains(key.substring(0, colon))
        ? key.substring(colon + 1)
        : key;
  }

  /// The part of a translation file under its language, whatever the
  /// language is called.
  static Map<String, Object?> _wordsOf(Object? json) {
    final byLanguage = _map(json);
    if (byLanguage.length != 1) return const {};
    return _map(_map(byLanguage.values.single)['presets']);
  }

  static Map<String, Object?> _map(Object? json) =>
      json is Map ? json.cast<String, Object?>() : const {};

  static List<Object?> _list(Object? json) => json is List ? json : const [];

  static String? _string(Object? json) => json is String ? json : null;

  static Map<String, String> _tags(Object? json) => {
        for (final MapEntry(:key, :value) in _map(json).entries)
          if (value is String) key: value,
      };

  static List<String> _split(Object? json, String by) => [
        if (json is String)
          for (final part in json.split(by))
            if (part.trim().isNotEmpty) part.trim(),
      ];
}

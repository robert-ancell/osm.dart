import 'dart:convert';
import 'dart:typed_data';

import 'element.dart';
import 'filter.dart';

/// What a filter needs of an element, worked out before any decoding.
///
/// These are necessary conditions, never sufficient ones: an element that
/// fails one cannot match the filter, but one that passes them all still has
/// to be handed to [OsmFilter.matches]. That is what makes them safe to use
/// for skipping work.
class OsmFilterPlan {
  /// The filter the plan was made for, or null to take everything.
  final OsmFilter? filter;

  /// The element types that can match.
  final Set<OsmElementType> types;

  /// The tag keys, at least one of which a matching element must carry, or
  /// null if no such set could be worked out.
  final Set<String>? keys;

  /// Whether a matching element must carry at least one tag.
  final bool tagged;

  /// [keys] as UTF-8, so a block's string table can be searched without
  /// decoding any of it.
  final List<Uint8List>? encodedKeys;

  OsmFilterPlan._({
    required this.filter,
    required this.types,
    required this.keys,
    required this.tagged,
  }) : encodedKeys = keys?.map(utf8.encode).toList(growable: false);

  /// Works out what [filter] needs. A null filter takes every element.
  factory OsmFilterPlan.of(OsmFilter? filter) {
    if (filter == null) {
      return OsmFilterPlan._(
        filter: null,
        types: _allTypes,
        keys: null,
        tagged: false,
      );
    }
    final need = _needsOf(filter);
    return OsmFilterPlan._(
      filter: filter,
      types: need.types,
      keys: need.keys,
      tagged: need.tagged,
    );
  }

  /// The plan with the filter itself left out.
  ///
  /// A filter may hold a closure, which cannot cross an isolate boundary. The
  /// screening conditions are plain data and can, and since they are only ever
  /// necessary conditions the filter still has to be applied to whatever comes
  /// back.
  OsmFilterPlan get screening => OsmFilterPlan._(
        filter: null,
        types: types,
        keys: keys,
        tagged: tagged,
      );

  /// Whether elements of [type] are worth decoding.
  bool wantsType(OsmElementType type) => types.contains(type);

  /// Whether an element with no tags at all can match.
  bool get wantsUntagged => !tagged;
}

const Set<OsmElementType> _allTypes = {
  OsmElementType.node,
  OsmElementType.way,
  OsmElementType.relation,
};

/// The necessary conditions gathered from one filter.
class _Needs {
  final Set<OsmElementType> types;
  final Set<String>? keys;
  final bool tagged;

  const _Needs({required this.types, this.keys, this.tagged = false});

  static const _Needs unknown = _Needs(types: _allTypes);
}

_Needs _needsOf(OsmFilter filter) {
  switch (filter) {
    case OsmTypeFilter(:final type):
      return _Needs(types: {type});
    case OsmTagFilter(:final key):
      return _Needs(types: _allTypes, keys: {key}, tagged: true);
    case OsmTagInFilter(:final key):
      return _Needs(types: _allTypes, keys: {key}, tagged: true);
    case OsmTaggedFilter():
      return const _Needs(types: _allTypes, tagged: true);
    case OsmAllFilter(:final filters):
      return _needsOfAll(filters);
    case OsmAnyFilter(:final filters):
      return _needsOfAny(filters);
    case OsmNotFilter():
      // Whatever the inner filter needs, its negation does not.
      return _Needs.unknown;
    case OsmWhereFilter():
      return _Needs.unknown;
  }
}

_Needs _needsOfAll(List<OsmFilter> filters) {
  if (filters.isEmpty) return _Needs.unknown;
  final needs = filters.map(_needsOf).toList();

  // Every part must match, so every part's conditions hold.
  var types = _allTypes;
  for (final need in needs) {
    types = types.intersection(need.types);
  }

  // Any one part's key requirement is on its own a necessary condition, so
  // take the one that rules out the most.
  Set<String>? keys;
  for (final need in needs) {
    final candidate = need.keys;
    if (candidate != null && (keys == null || candidate.length < keys.length)) {
      keys = candidate;
    }
  }

  return _Needs(
    types: types,
    keys: keys,
    tagged: needs.any((need) => need.tagged),
  );
}

_Needs _needsOfAny(List<OsmFilter> filters) {
  if (filters.isEmpty) return _Needs.unknown;
  final needs = filters.map(_needsOf).toList();

  // Any part may be the one that matches, so only what they all agree on
  // holds.
  final types = <OsmElementType>{};
  for (final need in needs) {
    types.addAll(need.types);
  }

  final union = <String>{};
  var screenable = true;
  for (final need in needs) {
    final candidate = need.keys;
    if (candidate == null) {
      screenable = false;
      break;
    }
    union.addAll(candidate);
  }
  final keys = screenable ? union : null;

  return _Needs(
    types: types,
    keys: keys,
    tagged: needs.every((need) => need.tagged),
  );
}

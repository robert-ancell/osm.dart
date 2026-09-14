import 'element.dart';

/// Chooses which elements of a file are wanted.
///
/// A filter is a description of what to match rather than a plain function,
/// which lets a reader work out what it can skip before it decodes it. Asking
/// for one tag out of a country sized file costs far less than reading all of
/// it: a block whose string table does not hold the key is dropped without
/// looking at a single element, elements of a type that cannot match are never
/// decoded, and an element without the key is never built into an object.
///
/// ```dart
/// final courses = OsmFilter.tag('leisure', 'golf_course');
/// final namedWays = OsmFilter.type(OsmElementType.way) & OsmFilter.tag('name');
/// ```
sealed class OsmFilter {
  const OsmFilter();

  /// Matches elements of the given [type].
  const factory OsmFilter.type(OsmElementType type) = OsmTypeFilter;

  /// Matches elements carrying [key], set to [value] if one is given.
  const factory OsmFilter.tag(String key, [String? value]) = OsmTagFilter;

  /// Matches elements carrying [key] set to any of [values].
  const factory OsmFilter.tagIn(String key, Set<String> values) =
      OsmTagInFilter;

  /// Matches elements carrying at least one tag.
  const factory OsmFilter.tagged() = OsmTaggedFilter;

  /// Matches the elements of [type] with one of [ids].
  const factory OsmFilter.ids(OsmElementType type, Set<int> ids) = OsmIdFilter;

  /// Matches elements matching every one of [filters].
  const factory OsmFilter.all(List<OsmFilter> filters) = OsmAllFilter;

  /// Matches elements matching any one of [filters].
  const factory OsmFilter.any(List<OsmFilter> filters) = OsmAnyFilter;

  /// Matches elements that [filter] does not match.
  const factory OsmFilter.not(OsmFilter filter) = OsmNotFilter;

  /// Matches elements that [test] accepts.
  ///
  /// Nothing can be skipped ahead of a test written as code, so every element
  /// is decoded to run it. Prefer the other filters where they say the same
  /// thing, and use this for what they cannot express.
  const factory OsmFilter.where(bool Function(OsmElement element) test) =
      OsmWhereFilter;

  /// Whether [element] is wanted.
  bool matches(OsmElement element);

  /// A filter matching what both this and [other] match.
  OsmFilter operator &(OsmFilter other) => OsmAllFilter([this, other]);

  /// A filter matching what either this or [other] matches.
  OsmFilter operator |(OsmFilter other) => OsmAnyFilter([this, other]);
}

/// Matches elements of one type. See [OsmFilter.type].
class OsmTypeFilter extends OsmFilter {
  /// The type to match.
  final OsmElementType type;

  /// Creates a filter matching elements of [type].
  const OsmTypeFilter(this.type);

  @override
  bool matches(OsmElement element) => element.type == type;
}

/// Matches elements by id. See [OsmFilter.ids].
class OsmIdFilter extends OsmFilter {
  /// The type to match.
  final OsmElementType type;

  /// The ids to match.
  final Set<int> ids;

  /// Creates a filter matching the elements of [type] with one of [ids].
  const OsmIdFilter(this.type, this.ids);

  @override
  bool matches(OsmElement element) =>
      element.type == type && ids.contains(element.id);
}

/// Matches elements by tag. See [OsmFilter.tag].
class OsmTagFilter extends OsmFilter {
  /// The tag key to match.
  final String key;

  /// The value to match, or null to match any value.
  final String? value;

  /// Creates a filter matching elements carrying [key].
  const OsmTagFilter(this.key, [this.value]);

  @override
  bool matches(OsmElement element) {
    final tag = element.tags[key];
    if (tag == null) return false;
    return value == null || tag == value;
  }
}

/// Matches elements by tag against a set of values. See [OsmFilter.tagIn].
class OsmTagInFilter extends OsmFilter {
  /// The tag key to match.
  final String key;

  /// The values to match.
  final Set<String> values;

  /// Creates a filter matching elements whose [key] is one of [values].
  const OsmTagInFilter(this.key, this.values);

  @override
  bool matches(OsmElement element) {
    final tag = element.tags[key];
    return tag != null && values.contains(tag);
  }
}

/// Matches elements carrying at least one tag. See [OsmFilter.tagged].
class OsmTaggedFilter extends OsmFilter {
  /// Creates a filter matching elements carrying at least one tag.
  const OsmTaggedFilter();

  @override
  bool matches(OsmElement element) => element.tags.isNotEmpty;
}

/// Matches elements matching every part. See [OsmFilter.all].
class OsmAllFilter extends OsmFilter {
  /// The filters that must all match.
  final List<OsmFilter> filters;

  /// Creates a filter matching elements matching every one of [filters].
  const OsmAllFilter(this.filters);

  @override
  bool matches(OsmElement element) => filters.every((f) => f.matches(element));
}

/// Matches elements matching any part. See [OsmFilter.any].
class OsmAnyFilter extends OsmFilter {
  /// The filters, any of which may match.
  final List<OsmFilter> filters;

  /// Creates a filter matching elements matching any one of [filters].
  const OsmAnyFilter(this.filters);

  @override
  bool matches(OsmElement element) => filters.any((f) => f.matches(element));
}

/// Matches what another filter does not. See [OsmFilter.not].
class OsmNotFilter extends OsmFilter {
  /// The filter to invert.
  final OsmFilter filter;

  /// Creates a filter matching elements [filter] does not match.
  const OsmNotFilter(this.filter);

  @override
  bool matches(OsmElement element) => !filter.matches(element);
}

/// Matches elements a function accepts. See [OsmFilter.where].
class OsmWhereFilter extends OsmFilter {
  /// The test to run against each element.
  final bool Function(OsmElement element) test;

  /// Creates a filter matching elements [test] accepts.
  const OsmWhereFilter(this.test);

  @override
  bool matches(OsmElement element) => test(element);
}

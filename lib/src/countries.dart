/// Which country a place is in, and every larger region it is in as well.
///
/// Read from country-coder's borders, <https://github.com/rapideditor/country-coder>,
/// which is what iD finds out where it is with. The borders are coarse on
/// purpose — a few hundred kilobytes for the whole world — and are for
/// saying which country a place is in, not for drawing: close to a border
/// the answer can be the neighbour's.
///
/// A place's regions are named every way the borders name them, so that
/// whatever a caller holds — `NZ`, `NZL`, `554`, `Q664`, or `Q538` for
/// Oceania — can be looked for among them. That is the form iD's tagging
/// schema says where a preset applies in.
///
/// The borders are © country-coder contributors, under the ISC licence.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One country, territory or larger region.
class OsmCountry {
  /// Every code it goes by, lower case: its ISO 3166-1 codes, its Wikidata
  /// id, its UN M49 code and any others the borders give it.
  final Set<String> codes;

  /// Its name in English.
  final String name;

  /// Its two letter ISO 3166-1 code, if it has one of its own.
  final String? iso;

  /// The code of the country it is a part of, if it is part of one.
  final String? partOf;

  /// The codes of the larger regions it is in.
  final List<String> groups;

  /// The side of the road traffic keeps to, `left` or `right`, if the
  /// borders say.
  final String? driveSide;

  /// Its land, as rings of alternating longitude and latitude. The first of
  /// each polygon's rings is its outside and any others are holes in it.
  final List<List<Float64List>> polygons;

  final double _west, _south, _east, _north;

  OsmCountry._({
    required this.codes,
    required this.name,
    required this.iso,
    required this.partOf,
    required this.groups,
    required this.driveSide,
    required this.polygons,
  })  : _west = _extreme(polygons, 0, (a, b) => a < b),
        _south = _extreme(polygons, 1, (a, b) => a < b),
        _east = _extreme(polygons, 0, (a, b) => a > b),
        _north = _extreme(polygons, 1, (a, b) => a > b);

  static double _extreme(
    List<List<Float64List>> polygons,
    int axis,
    bool Function(double, double) beyond,
  ) {
    double? best;
    for (final polygon in polygons) {
      final outside = polygon.first;
      for (var i = axis; i < outside.length; i += 2) {
        if (best == null || beyond(outside[i], best)) best = outside[i];
      }
    }
    return best ?? double.nan;
  }

  /// Whether its land takes in the point at ([latitude], [longitude]).
  bool holds(double latitude, double longitude) {
    // Outside the box around it is outside it, which rules out nearly every
    // country before any of their edges are looked at.
    if (!(latitude >= _south &&
        latitude <= _north &&
        longitude >= _west &&
        longitude <= _east)) {
      return false;
    }
    for (final polygon in polygons) {
      // Counting crossings over every ring of the polygon at once: a point in
      // a hole crosses the hole's edge as well, and comes out outside.
      var inside = false;
      for (final ring in polygon) {
        for (var i = 0, j = ring.length - 2; i < ring.length; j = i, i += 2) {
          final xi = ring[i], yi = ring[i + 1];
          final xj = ring[j], yj = ring[j + 1];
          if ((yi > latitude) != (yj > latitude) &&
              longitude < (xj - xi) * (latitude - yi) / (yj - yi) + xi) {
            inside = !inside;
          }
        }
      }
      if (inside) return true;
    }
    return false;
  }

  @override
  String toString() => 'OsmCountry($name)';
}

/// The world's countries and regions, and a way to ask which a place is in.
class OsmCountries {
  /// Every country, territory and region, whether or not it has land of its
  /// own. A country made of several pieces has its land in the pieces.
  final List<OsmCountry> all;

  final Map<String, OsmCountry> _byCode;
  final List<OsmCountry> _withLand;

  OsmCountries._(this.all)
      : _byCode = {
          for (final country in all)
            for (final code in country.codes) code: country,
        },
        _withLand = [
          for (final country in all)
            if (country.polygons.isNotEmpty) country,
        ];

  /// The countries and regions in country-coder's `borders.json`.
  factory OsmCountries.parse(String json) {
    final features = _list(_map(jsonDecode(json))['features']);
    return OsmCountries._([
      for (final feature in features)
        if (_country(_map(feature)) case final country?) country,
    ]);
  }

  /// The country or region going by [code], in any of the ways it goes by.
  OsmCountry? byCode(String code) => _byCode[code.toLowerCase()];

  /// The smallest pieces of land that take in the point at ([latitude],
  /// [longitude]): usually one, and none out at sea.
  List<OsmCountry> landAt(double latitude, double longitude) => [
        for (final country in _withLand)
          if (country.holds(latitude, longitude)) country,
      ];

  /// The country the point at ([latitude], [longitude]) is in, if it is in
  /// one: the country a territory or a constituent part belongs to rather
  /// than the part.
  OsmCountry? countryAt(double latitude, double longitude) {
    for (var place in landAt(latitude, longitude)) {
      for (var steps = 0; steps < 4; steps++) {
        final up = place.partOf == null ? null : byCode(place.partOf!);
        if (up == null) break;
        place = up;
      }
      return place;
    }
    return null;
  }

  /// Every code of every region the point at ([latitude], [longitude]) is
  /// in, from the piece of land it stands on up to the continent and the
  /// unions it is part of.
  ///
  /// Lower case, the form [OsmLocationSet.appliesAt] takes them in. Empty
  /// out at sea, where nothing is known but that it is in the world.
  Set<String> codesAt(double latitude, double longitude) {
    final codes = <String>{};
    final seen = <OsmCountry>{};
    final waiting = [...landAt(latitude, longitude)];
    while (waiting.isNotEmpty) {
      final place = waiting.removeLast();
      if (!seen.add(place)) continue;
      codes.addAll(place.codes);
      for (final code in [
        if (place.partOf case final country?) country,
        ...place.groups,
      ]) {
        final up = byCode(code);
        if (up != null) waiting.add(up);
      }
    }
    return codes;
  }

  static OsmCountry? _country(Map<String, Object?> feature) {
    final properties = _map(feature['properties']);
    String? string(String key) =>
        properties[key] is String ? properties[key] as String : null;

    final codes = <String>{
      for (final key in ['iso1A2', 'iso1A3', 'iso1N3', 'wikidata', 'm49'])
        if (string(key) case final code?) code.toLowerCase(),
      for (final alias in _list(properties['aliases']))
        if (alias is String) alias.toLowerCase(),
    };
    if (codes.isEmpty) return null;

    final geometry = _map(feature['geometry']);
    final polygons = switch (geometry['type']) {
      'Polygon' => [_polygon(geometry['coordinates'])],
      'MultiPolygon' => [
          for (final polygon in _list(geometry['coordinates']))
            _polygon(polygon),
        ],
      _ => <List<Float64List>>[],
    };

    return OsmCountry._(
      codes: codes,
      name: string('nameEn') ?? codes.first,
      iso: string('iso1A2'),
      partOf: string('country'),
      groups: [
        for (final group in _list(properties['groups']))
          if (group is String) group,
      ],
      driveSide: string('driveSide'),
      polygons: [
        for (final polygon in polygons)
          if (polygon.isNotEmpty) polygon,
      ],
    );
  }

  static List<Float64List> _polygon(Object? rings) => [
        for (final ring in _list(rings))
          Float64List.fromList([
            for (final point in _list(ring))
              if (point is List && point.length >= 2) ...[
                (point[0] as num).toDouble(),
                (point[1] as num).toDouble(),
              ],
          ]),
      ];

  static Map<String, Object?> _map(Object? json) =>
      json is Map ? json.cast<String, Object?>() : const {};

  static List<Object?> _list(Object? json) => json is List ? json : const [];
}

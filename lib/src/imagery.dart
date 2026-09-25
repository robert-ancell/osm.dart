import 'bounds.dart';
import 'json_exception.dart';
import 'tile.dart';

/// What a layer of imagery is for.
enum OsmImageryCategory {
  /// Aerial or satellite photography.
  photo,

  /// Photography kept for what it showed at the time.
  historicPhoto,

  /// A drawn map.
  map,

  /// A drawn map kept for what it showed at the time.
  historicMap,

  /// A map made from OpenStreetMap itself.
  osmBasedMap,

  /// Heights rather than pictures.
  elevation,

  /// Something to check data against.
  qa,

  /// Anything else, including layers that say nothing about themselves.
  other;

  /// The category the index calls [name].
  static OsmImageryCategory of(String? name) => switch (name) {
        'photo' => photo,
        'historicphoto' => historicPhoto,
        'map' => map,
        'historicmap' => historicMap,
        'osmbasedmap' => osmBasedMap,
        'elevation' => elevation,
        'qa' => qa,
        _ => other,
      };
}

/// A layer of imagery that may be traced over, as the editor layer index
/// describes it.
///
/// The index is the list editors share, so that they offer the same imagery,
/// credit it the same way, and agree on what there is permission to trace.
class OsmImagery {
  /// The index's identifier for the layer.
  final String id;

  /// What the layer is called.
  final String name;

  /// Where a tile is, with `{zoom}`, `{x}` and `{y}` to fill in.
  final String url;

  /// What the layer is for.
  final OsmImageryCategory category;

  /// The furthest out it has tiles for.
  final int minimumZoom;

  /// The closest in it has tiles for.
  final int maximumZoom;

  /// The credit its licence asks for, if it asks for one.
  final String? attribution;

  /// Where the licence terms are.
  final String? attributionUrl;

  /// Whether the index marks this the one to prefer where several cover the
  /// same ground.
  final bool best;

  /// Whether it is drawn over another layer rather than on its own.
  final bool overlay;

  /// The ground it covers, or null if it covers the world.
  final OsmImageryCoverage? coverage;

  /// Creates a layer.
  const OsmImagery({
    required this.id,
    required this.name,
    required this.url,
    this.category = OsmImageryCategory.other,
    this.minimumZoom = 0,
    this.maximumZoom = 22,
    this.attribution,
    this.attributionUrl,
    this.best = false,
    this.overlay = false,
    this.coverage,
  });

  /// Whether the layer has tiles over ([latitude], [longitude]).
  bool contains(double latitude, double longitude) =>
      coverage?.contains(latitude, longitude) ?? true;

  /// Where [tile] is.
  ///
  /// Fills in the placeholders the index uses: the tile's numbers, `{-y}` for
  /// the servers that count rows from the south, and `{switch:a,b}` for the
  /// ones spread over several names, of which the first is taken.
  String tileUrl(OsmTile tile) {
    final OsmTile(:zoom, :x, :y) = tile;
    final flipped = (1 << zoom) - 1 - y;
    return url
        .replaceAll('{zoom}', '$zoom')
        .replaceAll('{z}', '$zoom')
        .replaceAll('{x}', '$x')
        .replaceAll('{-y}', '$flipped')
        .replaceAll('{y}', '$y')
        .replaceAllMapped(
          RegExp(r'\{switch:([^}]*)\}'),
          (match) => match.group(1)!.split(',').first.trim(),
        );
  }

  @override
  String toString() => 'OsmImagery($id)';
}

/// The ground a layer covers, as the index draws it.
class OsmImageryCoverage {
  /// The shapes covered, each an outer ring followed by any holes, and each
  /// ring a flat list of longitude and latitude in turn.
  final List<List<List<double>>> polygons;

  /// The box around all of them, which rules most places out at a glance.
  final OsmBounds bounds;

  /// Creates a coverage.
  OsmImageryCoverage(this.polygons) : bounds = _boundsOf(polygons);

  /// Whether ([latitude], [longitude]) falls inside.
  bool contains(double latitude, double longitude) {
    if (!bounds.contains(latitude, longitude)) return false;
    for (final polygon in polygons) {
      if (polygon.isEmpty) continue;
      if (!_inRing(polygon.first, latitude, longitude)) continue;
      // Inside the outline, unless it falls in a hole in it.
      var holed = false;
      for (var i = 1; i < polygon.length; i++) {
        if (_inRing(polygon[i], latitude, longitude)) {
          holed = true;
          break;
        }
      }
      if (!holed) return true;
    }
    return false;
  }

  /// Whether a point falls inside a ring, by counting the crossings of a line
  /// drawn east from it: an odd number means inside.
  static bool _inRing(List<double> ring, double latitude, double longitude) {
    var inside = false;
    final points = ring.length ~/ 2;
    for (var i = 0, j = points - 1; i < points; j = i++) {
      final xi = ring[i * 2], yi = ring[i * 2 + 1];
      final xj = ring[j * 2], yj = ring[j * 2 + 1];
      if ((yi > latitude) != (yj > latitude) &&
          longitude < (xj - xi) * (latitude - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  static OsmBounds _boundsOf(List<List<List<double>>> polygons) {
    var minLatitude = 90.0, maxLatitude = -90.0;
    var minLongitude = 180.0, maxLongitude = -180.0;
    for (final polygon in polygons) {
      for (final ring in polygon) {
        for (var i = 0; i + 1 < ring.length; i += 2) {
          final longitude = ring[i], latitude = ring[i + 1];
          if (latitude < minLatitude) minLatitude = latitude;
          if (latitude > maxLatitude) maxLatitude = latitude;
          if (longitude < minLongitude) minLongitude = longitude;
          if (longitude > maxLongitude) maxLongitude = longitude;
        }
      }
    }
    return OsmBounds(
      minLatitude: minLatitude,
      minLongitude: minLongitude,
      maxLatitude: maxLatitude,
      maxLongitude: maxLongitude,
    );
  }
}

/// The editor layer index: every layer editors know how to offer.
///
/// Read it from the index's own `imagery.geojson`. Layers it describes in
/// ways this cannot serve, such as the ones reached over WMS, are left out
/// rather than offered and then found not to work.
class OsmImageryIndex {
  /// The layers, in the order the index gave them.
  final List<OsmImagery> layers;

  /// Creates an index.
  const OsmImageryIndex(this.layers);

  /// Reads an index from the JSON the editor layer index publishes.
  ///
  /// Throws an [OsmJsonException] if [json] is not JSON.
  factory OsmImageryIndex.parse(String json) => OsmImageryIndex.of(
        decodeJson(json, 'The imagery index'),
      );

  /// Reads an index from already decoded JSON.
  factory OsmImageryIndex.of(Object? json) {
    if (json is! Map<String, dynamic>) return const OsmImageryIndex([]);
    final features = json['features'];
    if (features is! List) return const OsmImageryIndex([]);
    return OsmImageryIndex([
      for (final feature in features)
        if (_layerOf(feature) case final layer?) layer,
    ]);
  }

  /// The layers covering ([latitude], [longitude]), the ones to prefer first.
  ///
  /// Ordered as an editor would offer them: those the index marks best, then
  /// whichever has tiles closest in, which is usually the most detailed.
  List<OsmImagery> layersAt(
    double latitude,
    double longitude, {
    OsmImageryCategory? category,
    bool overlays = false,
  }) {
    final found = [
      for (final layer in layers)
        if (layer.overlay == overlays &&
            (category == null || layer.category == category) &&
            layer.contains(latitude, longitude))
          layer,
    ];
    found.sort((a, b) {
      if (a.best != b.best) return a.best ? -1 : 1;
      return b.maximumZoom.compareTo(a.maximumZoom);
    });
    return found;
  }

  static OsmImagery? _layerOf(Object? feature) {
    if (feature is! Map<String, dynamic>) return null;
    final properties = feature['properties'];
    if (properties is! Map<String, dynamic>) return null;

    // Only layers whose tiles can be asked for by number. The index also
    // holds WMS and its relatives, which are a different kind of request.
    if (properties['type'] != 'tms') return null;
    final id = properties['id'];
    final name = properties['name'];
    final url = properties['url'];
    if (id is! String || name is! String || url is! String) return null;

    final attribution = properties['attribution'];
    return OsmImagery(
      id: id,
      name: name,
      url: url,
      category: OsmImageryCategory.of(properties['category'] as String?),
      minimumZoom: properties['min_zoom'] as int? ?? 0,
      maximumZoom: properties['max_zoom'] as int? ?? 22,
      attribution: attribution is Map<String, dynamic>
          ? attribution['text'] as String?
          : null,
      attributionUrl: attribution is Map<String, dynamic>
          ? attribution['url'] as String?
          : null,
      best: properties['best'] == true,
      overlay: properties['overlay'] == true,
      coverage: _coverageOf(feature['geometry']),
    );
  }

  static OsmImageryCoverage? _coverageOf(Object? geometry) {
    if (geometry is! Map<String, dynamic>) return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List) return null;
    final polygons = switch (geometry['type']) {
      'Polygon' => [_polygonOf(coordinates)],
      'MultiPolygon' => [
          for (final polygon in coordinates) _polygonOf(polygon)
        ],
      _ => const <List<List<double>>>[],
    };
    final kept = [
      for (final polygon in polygons)
        if (polygon.isNotEmpty) polygon
    ];
    return kept.isEmpty ? null : OsmImageryCoverage(kept);
  }

  static List<List<double>> _polygonOf(Object? polygon) {
    if (polygon is! List) return const [];
    return [
      for (final ring in polygon)
        if (_ringOf(ring) case final flat when flat.length >= 6) flat,
    ];
  }

  static List<double> _ringOf(Object? ring) {
    if (ring is! List) return const [];
    final flat = <double>[];
    for (final point in ring) {
      if (point is! List || point.length < 2) continue;
      final longitude = point[0], latitude = point[1];
      if (longitude is! num || latitude is! num) continue;
      flat.add(longitude.toDouble());
      flat.add(latitude.toDouble());
    }
    return flat;
  }
}

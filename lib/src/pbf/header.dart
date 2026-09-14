import '../bounds.dart';

/// The header of a PBF file, describing what it holds.
class OsmPbfHeader {
  /// The area the file covers, if it declares one.
  final OsmBounds? bounds;

  /// The features a reader must understand to decode the file.
  final List<String> requiredFeatures;

  /// The features a reader may use, but can ignore.
  final List<String> optionalFeatures;

  /// The program that wrote the file, if it named itself.
  final String? writingProgram;

  /// The source of the data, if the file names one.
  final String? source;

  /// The moment the data was current, if the file says.
  final DateTime? replicationTimestamp;

  /// The replication sequence number the file was made from, if it says.
  final int? replicationSequenceNumber;

  /// The replication server the file was made from, if it says.
  final String? replicationBaseUrl;

  /// Creates a header.
  const OsmPbfHeader({
    this.bounds,
    this.requiredFeatures = const [],
    this.optionalFeatures = const [],
    this.writingProgram,
    this.source,
    this.replicationTimestamp,
    this.replicationSequenceNumber,
    this.replicationBaseUrl,
  });

  /// Whether the file carries the full edit history, and so may contain
  /// elements that have been deleted.
  bool get hasHistory => requiredFeatures.contains('HistoricalInformation');

  @override
  String toString() =>
      'OsmPbfHeader(${writingProgram ?? 'unknown writer'}, $bounds)';
}

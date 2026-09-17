import '../element.dart';
import '../xml/change.dart';
import 'exception.dart';
import 'file.dart';
import 'header.dart';
import 'writer.dart';

/// What applying a set of changes did.
class OsmChangeCounts {
  /// Elements the changes added.
  final int created;

  /// Elements the changes replaced.
  final int modified;

  /// Elements the changes removed.
  final int deleted;

  /// Elements no change touched.
  final int unchanged;

  /// Changes that named an element the file does not hold, and so did
  /// nothing: a delete for something already gone, most often.
  final int missed;

  /// Changes no newer than the element the file already holds, and so
  /// ignored.
  ///
  /// Diffs of different lengths overlap: a day's diff and the hour diffs
  /// after it can both carry an edit. Skipping what the file is already past
  /// is what makes applying them over each other safe.
  final int stale;

  /// Creates a count of what happened.
  const OsmChangeCounts({
    required this.created,
    required this.modified,
    required this.deleted,
    required this.unchanged,
    required this.missed,
    this.stale = 0,
  });

  @override
  String toString() =>
      'OsmChangeCounts($created created, $modified modified, $deleted '
      'deleted, $unchanged unchanged, $missed missed, $stale stale)';
}

/// Writes [input] to [output] with [changes] applied.
///
/// The equivalent of `osmium apply-changes`. When one element is changed more
/// than once, the change with the highest version wins, and a change no newer
/// than the version the file already holds is ignored — a delete only when it
/// is older, since a delete can carry the version it deletes — so diffs that overlap
/// can be applied over each other. Changes with no version are taken in the
/// order given, the last one winning.
///
/// A change that creates an element the file does not hold puts it in its
/// place in the order; one that modifies an element the file does hold
/// replaces it; one that deletes leaves it out. A change naming an element
/// the file has never heard of is counted and otherwise ignored, which is
/// what a diff touching ground outside an extract looks like.
///
/// [header] is what the new file says about itself, and defaults to what the
/// old one said. An update should move the replication state on and hand that
/// back, because a file that loses it can never be brought up to date again.
/// Whatever it says about sorting, the file written is sorted and says so.
///
/// The changes are held in memory; the file is not.
Future<OsmChangeCounts> applyOsmChanges({
  required String input,
  required Iterable<OsmChange> changes,
  required String output,
  OsmPbfHeader? header,
}) async {
  final source = await OsmPbfFile.open(input);
  if (!source.header.isSorted) {
    throw OsmPbfException(
      'Changes can only be applied to a file whose elements are in order, '
      'and $input does not say its are',
    );
  }

  // The last word on each element, and the ids of each type in order so that
  // what the file does not hold can be put in the right place.
  final wanted = {
    for (final type in OsmElementType.values) type: <int, OsmChange>{},
  };
  for (final change in changes) {
    final held = wanted[change.type]![change.id];
    if (held != null && _isOlder(change, than: held)) continue;
    wanted[change.type]![change.id] = change;
  }
  final pending = {
    for (final type in OsmElementType.values)
      type: wanted[type]!.keys.toList()..sort(),
  };

  var created = 0, modified = 0, deleted = 0, unchanged = 0, missed = 0;
  var stale = 0;

  final writer = await OsmPbfWriter.create(
    output,
    header: (header ?? source.header).copyWith(
      optionalFeatures: {
        ...(header ?? source.header).optionalFeatures,
        'Sort.Type_then_ID',
      }.toList(),
    ),
  );

  /// Writes the elements a change adds, up to but not including [before].
  void insertBefore(OsmElementType type, int? before) {
    final ids = pending[type]!;
    while (ids.isNotEmpty && (before == null || ids.first < before)) {
      final change = wanted[type]!.remove(ids.removeAt(0))!;
      final element = change.element;
      if (change.action == OsmChangeAction.delete || element == null) {
        missed++;
        continue;
      }
      writer.add(element);
      created++;
    }
  }

  var reached = 0;
  await for (final element in source.elements()) {
    // Everything of an earlier type that the file did not hold goes in
    // before this one does.
    while (reached < element.type.index) {
      insertBefore(OsmElementType.values[reached], null);
      reached++;
    }
    insertBefore(element.type, element.id);

    final change = wanted[element.type]!.remove(element.id);
    if (change == null) {
      writer.add(element);
      unchanged++;
      continue;
    }
    pending[element.type]!.remove(element.id);

    final version = element.info?.version;
    final changed = change.version;
    // A delete can carry the version of what it deletes rather than the one
    // after it: an extract's own diffs, made by comparing one day's extract
    // with the next, say it that way. Only a delete older than what the file
    // holds is behind it.
    if (version != null &&
        changed != null &&
        (change.action == OsmChangeAction.delete
            ? changed < version
            : changed <= version)) {
      writer.add(element);
      stale++;
      continue;
    }

    switch (change.action) {
      case OsmChangeAction.delete:
        deleted++;
      case OsmChangeAction.create || OsmChangeAction.modify:
        final replacement = change.element;
        if (replacement == null) {
          // Nothing to put in its place, so the element stays as it was.
          writer.add(element);
          missed++;
        } else {
          writer.add(replacement);
          modified++;
        }
    }
  }

  while (reached < OsmElementType.values.length) {
    insertBefore(OsmElementType.values[reached], null);
    reached++;
  }

  await writer.close();
  return OsmChangeCounts(
    created: created,
    modified: modified,
    deleted: deleted,
    unchanged: unchanged,
    missed: missed,
    stale: stale,
  );
}

/// Whether [change] is behind [than], both being changes to one element.
bool _isOlder(OsmChange change, {required OsmChange than}) {
  final version = change.version, other = than.version;
  if (version == null || other == null) return false;
  return version < other;
}

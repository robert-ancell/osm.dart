import 'dart:io';

import '../element.dart';
import '../xml/change.dart';
import 'blob.dart';
import 'block.dart';
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

/// Applies a set of changes to `.osm.pbf` files: the equivalent of
/// `osmium apply-changes`.
///
/// When one element is changed more than once, the change with the highest
/// version wins, and a change no newer than the version the file already
/// holds is ignored — a delete only when it is older, since a delete can
/// carry the version it deletes — so diffs that overlap can be applied over
/// each other. Changes with no version are taken in the order given, the
/// last one winning.
///
/// A change that creates an element the file does not hold puts it in its
/// place in the order; one that modifies an element the file does hold
/// replaces it; one that deletes leaves it out. A change naming an element
/// the file has never heard of is counted and otherwise ignored, which is
/// what a diff touching ground outside an extract looks like.
///
/// The changes are held in memory; the files are not.
class OsmPbfTransformer {
  /// The last word on each element, by type and then id.
  final Map<OsmElementType, Map<int, OsmChange>> _latest;

  /// Creates a transformer applying [changes], worked out once however many
  /// files it transforms.
  OsmPbfTransformer(Iterable<OsmChange> changes) : _latest = _latestOf(changes);

  static Map<OsmElementType, Map<int, OsmChange>> _latestOf(
    Iterable<OsmChange> changes,
  ) {
    final latest = {
      for (final type in OsmElementType.values) type: <int, OsmChange>{},
    };
    for (final change in changes) {
      final held = latest[change.type]![change.id];
      if (held != null && _isOlder(change, than: held)) continue;
      latest[change.type]![change.id] = change;
    }
    return latest;
  }

  /// Writes [input] to [output] with the changes applied, and says what
  /// they did.
  ///
  /// [input] has to be sorted, as a file that says `Sort.Type_then_ID`
  /// promises to be.
  ///
  /// [header] is what the new file says about itself, and defaults to what
  /// the old one said. An update should move the replication state on and
  /// hand that back, because a file that loses it can never be brought up
  /// to date again. Whatever it says about sorting, the file written is
  /// sorted and says so.
  Future<OsmChangeCounts> transform({
    required String input,
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

    // What is left to apply, taken off as it is, and the ids of each type in
    // order so that what the file does not hold can be put in the right place.
    final wanted = {
      for (final type in OsmElementType.values) type: Map.of(_latest[type]!),
    };
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

    // Where elements go: the writer, or a block being held until it is known
    // whether anything in it changed.
    void Function(OsmElement element) emit = writer.add;

    // How far through each type's pending ids the file has got.
    final next = {for (final type in OsmElementType.values) type: 0};

    /// Writes the elements a change adds, up to but not including [before].
    void insertBefore(OsmElementType type, int? before) {
      final ids = pending[type]!;
      var at = next[type]!;
      while (at < ids.length && (before == null || ids[at] < before)) {
        final change = wanted[type]!.remove(ids[at++]);
        if (change == null) continue;
        final element = change.element;
        if (change.action == OsmChangeAction.delete || element == null) {
          missed++;
          continue;
        }
        emit(element);
        created++;
      }
      next[type] = at;
    }

    var reached = 0;

    /// Everything of a type before [type] that the file did not hold, and
    /// everything of [type] before [id].
    void catchUp(OsmElementType type, int id) {
      while (reached < type.index) {
        insertBefore(OsmElementType.values[reached], null);
        reached++;
      }
      insertBefore(type, id);
    }

    void apply(OsmElement element) {
      catchUp(element.type, element.id);

      final change = wanted[element.type]!.remove(element.id);
      if (change == null) {
        emit(element);
        unchanged++;
        return;
      }
      final ids = pending[element.type]!;
      final at = next[element.type]!;
      if (at < ids.length && ids[at] == element.id) {
        next[element.type] = at + 1;
      }

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
        emit(element);
        stale++;
        return;
      }

      switch (change.action) {
        case OsmChangeAction.delete:
          deleted++;
        case OsmChangeAction.create || OsmChangeAction.modify:
          final replacement = change.element;
          if (replacement == null) {
            // Nothing to put in its place, so the element stays as it was.
            emit(element);
            missed++;
          } else {
            emit(replacement);
            modified++;
          }
      }
    }

    // Block by block. A block no change falls inside is copied as it is,
    // still compressed: an update of a few thousand elements is otherwise
    // every element of the file decoded, encoded and compressed again.
    final file = await File(input).open();
    try {
      final blobs = BlobReader(file);
      for (var blob = await blobs.next();
          blob != null;
          blob = await blobs.next()) {
        if (blob.type != 'OSMData') continue;
        final block = decodeBlob(blob.body, offset: blob.offset);
        final span = blockSpan(block);
        if (span != null) {
          catchUp(span.type, span.first);
          final ids = pending[span.type]!;
          final at = next[span.type]!;
          if (at >= ids.length || ids[at] > span.last) {
            writer.addBlock(blob.body, span);
            unchanged += span.count;
            await writer.flush();
            continue;
          }
        }
        // Decoded to see what the changes do, and written again only if they
        // do something: a block whose changes are all ones the file already
        // has — which is most of them, when diffs overlap — is copied too.
        final held = <OsmElement>[];
        final before = created + modified + deleted;
        emit = held.add;
        try {
          decodePrimitiveBlock(block, apply, offset: blob.offset);
        } finally {
          emit = writer.add;
        }
        if (span != null && created + modified + deleted == before) {
          writer.addBlock(blob.body, span);
        } else {
          held.forEach(writer.add);
        }
        await writer.flush();
      }
    } finally {
      await file.close();
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
}

/// Whether [change] is behind [than], both being changes to one element.
bool _isOlder(OsmChange change, {required OsmChange than}) {
  final version = change.version, other = than.version;
  if (version == null || other == null) return false;
  return version < other;
}

import 'dart:collection';
import 'dart:typed_data';
import 'dart:isolate';

import '../element.dart';
import '../filter_plan.dart';
import 'blob.dart';
import 'block.dart';

/// Decompresses and decodes one blob. Runs on a worker isolate.
///
/// Everything it needs is in its arguments, which is what lets it move: the
/// bytes of the blob, where they came from, and the screening conditions.
List<OsmElement> decodeBlobElements(
  Uint8List body,
  int offset,
  OsmFilterPlan plan,
) {
  final elements = <OsmElement>[];
  decodePrimitiveBlock(
    decodeBlob(body, offset: offset),
    elements.add,
    offset: offset,
    plan: plan,
  );
  return elements;
}

/// Decodes blobs from [blobs] on worker isolates, [concurrency] at a time.
///
/// Blobs go out in file order and their elements come back in the same order,
/// so what is yielded does not depend on which worker finished first. No more
/// than [concurrency] blobs are in flight at once, which is what keeps a whole
/// file out of memory.
///
/// Each blob is decoded by [Isolate.run], which hands its result back by
/// transferring it rather than copying it. That is what makes this worth doing
/// at all: a pool of long lived workers has to copy every element it sends,
/// and for anything but a very selective read the copying costs more than the
/// parallelism saves.
Stream<OsmElement> decodeAhead(
  Stream<RawBlob> blobs,
  OsmFilterPlan plan,
  int concurrency,
) async* {
  final screening = plan.screening;
  final pending = Queue<Future<List<OsmElement>>>();
  try {
    await for (final blob in blobs) {
      final body = blob.body;
      final offset = blob.offset;
      pending
          .add(Isolate.run(() => decodeBlobElements(body, offset, screening)));
      if (pending.length >= concurrency) {
        yield* _wanted(await pending.removeFirst(), plan);
      }
    }
    while (pending.isNotEmpty) {
      yield* _wanted(await pending.removeFirst(), plan);
    }
  } finally {
    // Anything still in flight is now unwanted. Saying so keeps a failure in
    // one of those isolates from being reported a second time.
    for (final decode in pending) {
      decode.ignore();
    }
  }
}

/// Applies the filter itself to what a worker screened and sent back.
///
/// The workers are given the screening conditions rather than the filter,
/// because a filter may hold a closure and closures cannot cross an isolate
/// boundary. Screening only ever lets through a superset of what matches, so
/// the filter still has the last word here.
Stream<OsmElement> _wanted(
  List<OsmElement> elements,
  OsmFilterPlan plan,
) async* {
  final filter = plan.filter;
  for (final element in elements) {
    if (filter == null || filter.matches(element)) yield element;
  }
}

import 'dart:collection';
import 'dart:typed_data';
import 'dart:isolate';

import '../element.dart';
import '../filter_plan.dart';
import 'blob.dart';
import 'block.dart';

/// How many blobs one worker is given at a time, for a read naming ids.
///
/// The screening conditions are copied to a worker with every job, so a job
/// per blob copies them once per blob: for a read naming eight hundred
/// thousand node ids that is eight hundred thousand integers seven thousand
/// times over, which costs more than the parallelism saves and is why such
/// reads used to be decoded on the calling isolate instead. A batch divides
/// that by its size.
///
/// **Only for a read naming ids**, because a batch holds what it decodes
/// until the whole batch is done. A read that names ids can only name ones
/// the caller already has, so it takes a small part of the file and a batch
/// of it is small. A read that takes most of the file is the opposite: at
/// sixty-four blobs a job and thirty-two jobs in flight, reading the area
/// around a few hundred places in a country extract held two thousand blocks
/// of elements at once and went from 36s to 184s.
const int _blobsPerJob = 64;

/// How many blobs to give a worker for [plan].
int blobsPerJob(OsmFilterPlan plan) => plan.ids == null ? 1 : _blobsPerJob;

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

/// Decodes a batch of blobs in file order. Runs on a worker isolate.
List<OsmElement> decodeBlobBatch(
  List<Uint8List> bodies,
  List<int> offsets,
  OsmFilterPlan plan,
) {
  final elements = <OsmElement>[];
  for (var i = 0; i < bodies.length; i++) {
    decodePrimitiveBlock(
      decodeBlob(bodies[i], offset: offsets[i]),
      elements.add,
      offset: offsets[i],
      plan: plan,
    );
  }
  return elements;
}

/// Hands one batch to a worker.
///
/// A function of its own, and a top level one, because of what a closure
/// captures: not the variables it names but the scope holding them. Written
/// inline in [decodeAhead], the closure given to [Isolate.run] carries that
/// function's whole context — the queue of batches already in flight
/// included — and a `Future` cannot cross to another isolate.
///
/// It fails on the second batch of any read that still has one pending, which
/// is every file of more than a few blobs and no fixture small enough to be a
/// test. See `test/decode_ahead_test.dart`.
Future<List<OsmElement>> _decodeOnAWorker(
  List<Uint8List> bodies,
  List<int> offsets,
  OsmFilterPlan plan,
) =>
    Isolate.run(() => decodeBlobBatch(bodies, offsets, plan));

/// Decodes blobs from [blobs] on worker isolates, [concurrency] at a time.
///
/// Blobs go out in file order and their elements come back in the same order,
/// so what is yielded does not depend on which worker finished first. No more
/// than [concurrency] batches are in flight at once, which is what keeps a
/// whole file out of memory.
///
/// Each batch is decoded by [Isolate.run], which hands its result back by
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
  final perJob = blobsPerJob(plan);
  final pending = Queue<Future<List<OsmElement>>>();
  var bodies = <Uint8List>[];
  var offsets = <int>[];

  void send() {
    pending.add(_decodeOnAWorker(bodies, offsets, screening));
    bodies = <Uint8List>[];
    offsets = <int>[];
  }

  try {
    await for (final blob in blobs) {
      bodies.add(blob.body);
      offsets.add(blob.offset);
      if (bodies.length < perJob) continue;
      send();
      if (pending.length >= concurrency) {
        yield* _wanted(await pending.removeFirst(), plan);
      }
    }
    if (bodies.isNotEmpty) send();
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

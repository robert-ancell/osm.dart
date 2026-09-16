import 'dart:math';

import 'package:osm/src/id_set.dart';
import 'package:test/test.dart';

void main() {
  test('holds what it is given, and says so', () {
    final ids = IdSet();
    ids.add(7);
    ids.add(1000000000000);

    expect(ids.contains(7), isTrue);
    expect(ids.contains(1000000000000), isTrue);
    expect(ids.contains(8), isFalse);
    expect(ids.length, 2);
  });

  test('and an id twice is one id', () {
    final ids = IdSet();
    ids.add(42);
    ids.add(42);

    expect(ids.length, 1);
  });

  test('and an empty set contains nothing', () {
    expect(IdSet().contains(1), isFalse);
    expect(IdSet().length, 0);
  });

  test('zero is an id like any other, not an empty slot', () {
    // Zero marks a free slot in the table, so a set that looked for it
    // there would find it in every set ever made.
    final ids = IdSet();
    expect(ids.contains(0), isFalse);
    ids.add(5);
    expect(ids.contains(0), isFalse);
    ids.add(0);
    ids.add(0);
    expect(ids.contains(0), isTrue);
    expect(ids.length, 2);
  });

  test('and negative ids are held too', () {
    // What an editor gives the objects nobody has uploaded yet.
    final ids = IdSet()
      ..add(-1)
      ..add(-9000000000);
    expect(ids.contains(-1), isTrue);
    expect(ids.contains(-9000000000), isTrue);
    expect(ids.contains(-2), isFalse);
  });

  test('grows past the size it was made at, keeping everything', () {
    // Sized for sixteen and given ten thousand, so it grows several times
    // over. Sequential ids, which is what a file is full of and what a hash
    // that did not spread them would leave in one run of the table.
    final ids = IdSet(16);
    for (var id = 1; id <= 10000; id++) {
      ids.add(id);
    }

    expect(ids.length, 10000);
    for (var id = 1; id <= 10000; id++) {
      expect(ids.contains(id), isTrue, reason: '$id went missing');
    }
    expect(ids.contains(10001), isFalse);
  });

  test('and agrees with a Set over a long run of adds and asks', () {
    // The probing, the growth and the hash together, against the answer
    // Dart's own set gives.
    final random = Random(4);
    final ids = IdSet();
    final theirs = <int>{};
    for (var i = 0; i < 20000; i++) {
      // Ids up to a real OpenStreetMap node id, so the high bits the hash
      // folds down are in play.
      final id = 1 + random.nextInt(1 << 32);
      ids.add(id);
      theirs.add(id);
    }

    expect(ids.length, theirs.length);
    for (final id in theirs) {
      expect(ids.contains(id), isTrue, reason: '$id went missing');
    }
    var wrong = 0;
    for (var i = 0; i < 20000; i++) {
      final id = 1 + random.nextInt(1 << 32);
      if (ids.contains(id) != theirs.contains(id)) wrong++;
    }
    expect(wrong, 0);
  });

  test('and a set sized for what it gets never grows', () {
    final ids = IdSet(10000);
    for (var id = 1; id <= 10000; id++) {
      ids.add(id);
    }

    expect(ids.length, 10000);
    expect(ids.contains(10000), isTrue);
  });
}

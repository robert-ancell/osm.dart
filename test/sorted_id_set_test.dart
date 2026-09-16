import 'dart:math';

import 'package:osm/src/sorted_id_set.dart';
import 'package:test/test.dart';

SortedIdSet _of(Iterable<int> ids) {
  final builder = SortedIdSetBuilder();
  ids.forEach(builder.add);
  return builder.build();
}

void main() {
  test('holds what it was given and nothing else', () {
    final set = _of([3, 5, 9, 1000, 1001]);
    expect(set.length, 5);
    for (final id in [3, 5, 9, 1000, 1001]) {
      expect(set.contains(id), isTrue, reason: '$id');
    }
    for (final id in [-1, 0, 1, 4, 10, 999, 1002, 1 << 40]) {
      expect(set.contains(id), isFalse, reason: '$id');
    }
  });

  test('an empty set holds nothing', () {
    expect(_of(const []).contains(1), isFalse);
    expect(_of(const []).length, 0);
  });

  test('agrees with a plain set across many blocks and wide gaps', () {
    final random = Random(42);
    final ids = <int>[];
    var id = 1;
    for (var i = 0; i < 20000; i++) {
      // Mostly small steps, as node ids of an area are, and now and then a
      // step past what 32 bits can hold, which has to start a new block.
      id += random.nextInt(50) == 0 ? (1 << 33) : random.nextInt(1000) + 1;
      ids.add(id);
    }
    final set = _of(ids);
    final plain = ids.toSet();
    expect(set.length, ids.length);

    for (final id in ids) {
      expect(set.contains(id), isTrue);
    }
    for (var i = 0; i < 20000; i++) {
      final probe = ids[random.nextInt(ids.length)] + random.nextInt(3) - 1;
      expect(set.contains(probe), plain.contains(probe), reason: '$probe');
    }
  });

  test('negative ids, which editors give what is not uploaded yet', () {
    final set = _of([-9, -5, -1, 0, 7]);
    for (final id in [-9, -5, -1, 0, 7]) {
      expect(set.contains(id), isTrue, reason: '$id');
    }
    expect(set.contains(-2), isFalse);
  });

  test('refuses ids out of order', () {
    final builder = SortedIdSetBuilder()..add(5);
    expect(() => builder.add(5), throwsArgumentError);
    expect(() => builder.add(4), throwsArgumentError);
  });
}

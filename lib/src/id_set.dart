import 'dart:typed_data';

/// A set of element ids, for the hot membership tests a read does.
///
/// Reading an area asks "is this way's node one I kept" for every node id of
/// every way in the file — forty million times over New Zealand — and a
/// `Map<int, OsmNode>` answering it spends the whole time in the hash map that
/// is there to hold the nodes, not to be asked about them.
///
/// Open addressed, linear probing, ids in an `Int64List`: no per entry object,
/// no boxing, and a probe that stays in one cache line most of the time. Ids
/// are positive in OpenStreetMap, so zero is free to mean an empty slot.
class IdSet {
  Int64List _slots;
  int _mask;
  int _count = 0;

  /// A set sized to hold [capacity] ids without growing.
  IdSet([int capacity = 0])
      : _slots = Int64List(_sizeFor(capacity)),
        _mask = _sizeFor(capacity) - 1;

  /// A power of two with room to stay under the load factor the probing
  /// wants, which is a half.
  static int _sizeFor(int capacity) {
    var size = 1024;
    while (size < capacity * 2) {
      size <<= 1;
    }
    return size;
  }

  /// Fibonacci hashing, which spreads the sequential ids a file is full of
  /// across the table instead of leaving them in one run of it.
  static int _spread(int id) {
    final h = id * 0x9E3779B97F4A7C15;
    return h ^ (h >>> 32);
  }

  /// How many ids are in the set.
  int get length => _count;

  /// Puts [id] in the set, or does nothing if it is already there.
  void add(int id) {
    var i = _spread(id) & _mask;
    while (true) {
      final slot = _slots[i];
      if (slot == id) return;
      if (slot == 0) {
        _slots[i] = id;
        if (++_count * 2 >= _slots.length) _grow();
        return;
      }
      i = (i + 1) & _mask;
    }
  }

  /// Whether [id] is in the set.
  bool contains(int id) {
    var i = _spread(id) & _mask;
    while (true) {
      final slot = _slots[i];
      if (slot == id) return true;
      if (slot == 0) return false;
      i = (i + 1) & _mask;
    }
  }

  void _grow() {
    final was = _slots;
    _slots = Int64List(was.length << 1);
    _mask = _slots.length - 1;
    _count = 0;
    for (final id in was) {
      if (id != 0) add(id);
    }
  }
}

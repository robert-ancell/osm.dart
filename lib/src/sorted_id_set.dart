import 'dart:typed_data';

/// Ids per block. Small enough that a search inside one is a few steps, large
/// enough that the base each block carries costs little.
const int _blockSize = 256;

/// The largest step a block can hold between its first id and any other.
const int _maxOffset = 0xffffffff;

/// A set of ids given in ascending order, held in about four bytes apiece.
///
/// The ids of a sorted file arrive in order, so nothing has to be hashed or
/// sorted: each block holds one full id as its base and the rest as 32 bit
/// offsets from it. Every node of a mid-sized country is 56 million ids, about
/// 225 MB here against over a gigabyte in [IdSet], whose open addressing wants
/// twice the slots it has ids. Built once and only asked afterwards, which is
/// what knowing what a snapshot holds needs.
class SortedIdSet {
  final Int64List _bases;
  final Uint32List _offsets;

  /// Where each block starts in [_offsets].
  final Int32List _starts;

  /// How many ids are in the set.
  final int length;

  SortedIdSet._(this._bases, this._offsets, this._starts, this.length);

  /// Whether [id] is in the set.
  bool contains(int id) {
    // The last block whose base is not past the id.
    var low = 0, high = _bases.length - 1, block = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (_bases[middle] <= id) {
        block = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (block < 0) return false;

    final offset = id - _bases[block];
    if (offset > _maxOffset) return false;
    var from = _starts[block];
    var to = block + 1 < _starts.length ? _starts[block + 1] : length;
    to--;
    while (from <= to) {
      final middle = (from + to) >> 1;
      final here = _offsets[middle];
      if (here == offset) return true;
      if (here < offset) {
        from = middle + 1;
      } else {
        to = middle - 1;
      }
    }
    return false;
  }
}

/// Builds a [SortedIdSet] from ids handed over in ascending order.
class SortedIdSetBuilder {
  final List<int> _bases = [];
  final List<int> _starts = [];
  Uint32List _offsets = Uint32List(1 << 16);
  int _length = 0;
  int _blockFill = _blockSize;
  int _last = 0;

  /// Adds [id], which has to be greater than the last one added.
  void add(int id) {
    if (_length > 0 && id <= _last) {
      throw ArgumentError.value(
        id,
        'id',
        'Ids have to be added in ascending order, and $id follows $_last',
      );
    }
    _last = id;

    if (_blockFill == _blockSize || id - _bases.last > _maxOffset) {
      _bases.add(id);
      _starts.add(_length);
      _blockFill = 0;
    }
    if (_length == _offsets.length) {
      _offsets = Uint32List(_offsets.length * 2)..setAll(0, _offsets);
    }
    _offsets[_length++] = id - _bases.last;
    _blockFill++;
  }

  /// The set, which the builder should not be used after.
  SortedIdSet build() => SortedIdSet._(
        Int64List.fromList(_bases),
        Uint32List.sublistView(_offsets, 0, _length),
        Int32List.fromList(_starts),
        _length,
      );
}

/// The field numbers of the messages an OSM PBF file is made of, named after
/// `fileformat.proto` and `osmformat.proto`.
///
/// The reader and the writer both work from these, so a number can only be
/// wrong in both at once, and a decoder reading field 8 of a way says it is
/// reading the node refs.
library;

// Each class says which message it is the fields of, and each name is that
// field's name in the .proto. A line of documentation apiece would say the
// same thing sixty times over.
// ignore_for_file: public_member_api_docs

/// `BlobHeader`, the framing in front of every blob.
abstract final class BlobHeaderField {
  static const int type = 1;
  static const int indexData = 2;
  static const int dataSize = 3;
}

/// `Blob`, which holds a block either as it is or compressed.
abstract final class BlobField {
  static const int raw = 1;
  static const int rawSize = 2;
  static const int zlibData = 3;
  static const int lzmaData = 4;
  static const int obsoleteBzip2Data = 5;
  static const int lz4Data = 6;
  static const int zstdData = 7;
}

/// `HeaderBlock`, what the file says about itself.
abstract final class HeaderBlockField {
  static const int bbox = 1;
  static const int requiredFeatures = 4;
  static const int optionalFeatures = 5;
  static const int writingProgram = 16;
  static const int source = 17;
  static const int replicationTimestamp = 32;
  static const int replicationSequenceNumber = 33;
  static const int replicationBaseUrl = 34;
}

/// `HeaderBBox`, in nanodegrees.
abstract final class HeaderBBoxField {
  static const int left = 1;
  static const int right = 2;
  static const int top = 3;
  static const int bottom = 4;
}

/// `PrimitiveBlock`, a block of elements and the strings they share.
abstract final class PrimitiveBlockField {
  static const int stringTable = 1;
  static const int primitiveGroup = 2;
  static const int granularity = 17;
  static const int dateGranularity = 18;
  static const int latitudeOffset = 19;
  static const int longitudeOffset = 20;
}

/// `StringTable`.
abstract final class StringTableField {
  static const int strings = 1;
}

/// `PrimitiveGroup`, which holds one kind of element at a time.
abstract final class PrimitiveGroupField {
  static const int nodes = 1;
  static const int dense = 2;
  static const int ways = 3;
  static const int relations = 4;
  static const int changeSets = 5;
}

/// `Node`, a node written on its own rather than densely.
abstract final class NodeField {
  static const int id = 1;
  static const int keys = 2;
  static const int values = 3;
  static const int info = 4;
  static const int latitude = 8;
  static const int longitude = 9;
}

/// `DenseNodes`, where a block's nodes are parallel arrays of deltas.
abstract final class DenseNodesField {
  static const int ids = 1;
  static const int denseInfo = 5;
  static const int latitudes = 8;
  static const int longitudes = 9;
  static const int keysValues = 10;
}

/// `Info` and `DenseInfo`, which carry the same fields in the same order.
abstract final class InfoField {
  static const int version = 1;
  static const int timestamp = 2;
  static const int changeset = 3;
  static const int uid = 4;
  static const int userStringId = 5;
  static const int visible = 6;
}

/// `Way`.
abstract final class WayField {
  static const int id = 1;
  static const int keys = 2;
  static const int values = 3;
  static const int info = 4;
  static const int refs = 8;
}

/// `Relation`.
abstract final class RelationField {
  static const int id = 1;
  static const int keys = 2;
  static const int values = 3;
  static const int info = 4;
  static const int roleStringIds = 8;
  static const int memberIds = 9;
  static const int types = 10;
}

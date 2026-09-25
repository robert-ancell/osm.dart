import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _generator = 'Test Editor';

/// A way as OpenStreetMap sent it, with the version an edit has to quote.
OsmWay _way(int id, List<int> nodeIds, {int version = 3}) => OsmWay(
      id: id,
      nodeIds: nodeIds,
      tags: const {'highway': 'residential'},
      info: OsmInfo(version: version),
    );

OsmNode _node(int id, double lat, double lon, {int version = 2}) => OsmNode(
      id: id,
      latitude: lat,
      longitude: lon,
      info: OsmInfo(version: version),
    );

String _xml(OsmEditHistory edits) =>
    OsmUpload.of(edits).toXml(changeset: 77, createdBy: _generator);

void main() {
  test('sends nothing when nothing has been changed', () {
    expect(OsmUpload.of(OsmEditHistory()).isEmpty, isTrue);
  });

  test('writes a moved node with the version it was read at', () {
    final edits = OsmEditHistory()
      ..moveNode(_node(5, -36.85, 174.76), latitude: -36.86, longitude: 174.77);
    final xml = _xml(edits);
    expect(xml, contains('<modify>'));
    expect(
      xml,
      contains('<node id="5" lat="-36.86" lon="174.77" version="2" '
          'changeset="77"/>'),
    );
    expect(xml, isNot(contains('<create>')));
  });

  test('writes new elements with a version of zero', () {
    final edits = OsmEditHistory();
    final a = edits.createNode(latitude: 1, longitude: 2);
    final b = edits.createNode(latitude: 3, longitude: 4);
    edits.createWay(nodeIds: [a.id, b.id], tags: const {'building': 'yes'});
    final xml = _xml(edits);
    expect(xml, contains('<node id="-1" lat="1.0" lon="2.0" version="0"'));
    expect(xml, contains('<way id="-3" version="0" changeset="77">'));
    // A new way names the new nodes by their negative ids, which is how
    // OpenStreetMap is told which of the things in this document it means.
    expect(xml, contains('<nd ref="-1"/>'));
    expect(xml, contains('<nd ref="-2"/>'));
    expect(xml, contains('<tag k="building" v="yes"/>'));
  });

  test('writes a way without a deleted node before deleting it', () {
    final way = _way(9, [1, 2, 3]);
    final edits = OsmEditHistory()..deleteNode(_node(2, 1, 2), from: [way]);
    final xml = _xml(edits);
    expect(xml.indexOf('<modify>'), lessThan(xml.indexOf('<delete>')));
    expect(xml, contains('<nd ref="1"/>'));
    expect(xml, isNot(contains('<nd ref="2"/>')));
    expect(xml, contains('<node id="2" lat="1.0" lon="2.0" version="2"'));
  });

  test('says nothing about a node made and then taken away again', () {
    final edits = OsmEditHistory();
    final node = edits.createNode(latitude: 1, longitude: 2);
    edits.deleteNode(node);
    expect(OsmUpload.of(edits).isEmpty, isTrue);
  });

  test('forgets a deletion that was undone', () {
    final edits = OsmEditHistory()..deleteNode(_node(4, 1, 2));
    expect(OsmUpload.of(edits).deletedNodes, hasLength(1));
    edits.undo();
    expect(OsmUpload.of(edits).isEmpty, isTrue);
  });

  test('refuses to write back an element read without a version', () {
    final edits = OsmEditHistory()
      ..moveNode(const OsmNode(id: 5, latitude: 1, longitude: 2),
          latitude: 3, longitude: 4);
    expect(() => _xml(edits), throwsA(isA<OsmUploadException>()));
  });

  test('escapes what XML cannot hold as it stands', () {
    final edits = OsmEditHistory()
      ..createNode(
          latitude: 1, longitude: 2, tags: const {'name': 'Bill & Ben'});
    expect(_xml(edits), contains('v="Bill &amp; Ben"'));
  });

  test('lists what would be sent', () {
    final edits = OsmEditHistory();
    final node = edits.createNode(latitude: 1, longitude: 2);
    edits.createWay(nodeIds: [node.id]);
    expect(OsmUpload.of(edits).describe(), [
      'Create node new (-1)',
      'Create way new (-2) through 1 node(s)',
    ]);
  });
}

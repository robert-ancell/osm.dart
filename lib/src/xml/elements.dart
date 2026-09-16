import '../element.dart';
import 'exception.dart';
import 'reader.dart';

/// An element as OSM's XML describes it.
class XmlElement {
  /// The create, modify or delete it sits in, or null outside one.
  final String? action;

  /// The kind of element.
  final OsmElementType type;

  /// Its id.
  final int id;

  /// Its version, if the XML gives one.
  final int? version;

  /// Whether the XML says the element exists. False for a deleted element the
  /// API still answers for.
  final bool visible;

  /// The element, or null if the XML gives too little to build one: a node
  /// with no location, which is how a deleted one comes.
  final OsmElement? element;

  /// Creates an element record.
  const XmlElement({
    required this.action,
    required this.type,
    required this.id,
    required this.version,
    required this.visible,
    required this.element,
  });
}

/// Reads the nodes, ways and relations of OSM XML, in the order given.
///
/// The same elements in the same shape whether they sit in an `<osm>` file,
/// an API answer, or the create, modify and delete of an `<osmChange>`.
void readOsmXmlElements(
  String xml,
  void Function(XmlElement element) onElement,
) =>
    (OsmXmlElementReader(onElement)..add(xml)).close();

/// Reads the elements of OSM XML handed over a piece at a time.
class OsmXmlElementReader {
  final void Function(XmlElement element) _onElement;
  late final XmlTagReader _tags = XmlTagReader(
    onOpen: _open,
    onClose: _close,
  );

  String? _action;
  OsmElementType? _type;
  Map<String, String>? _attributes;
  var _tagsOf = <String, String>{};
  var _nodeIds = <int>[];
  var _members = <OsmMember>[];

  /// Creates a reader calling [onElement] for each element as it completes.
  OsmXmlElementReader(void Function(XmlElement element) onElement)
      : _onElement = onElement;

  /// Reads the next piece of the document.
  void add(String piece) => _tags.add(piece);

  /// Says the document is done.
  void close() {
    _tags.close();
    _finish();
  }

  void _finish() {
    final open = _attributes;
    final kind = _type;
    if (open == null || kind == null) return;
    _onElement(
      _build(
        action: _action,
        type: kind,
        attributes: open,
        tags: _tagsOf,
        nodeIds: _nodeIds,
        members: _members,
      ),
    );
    _attributes = null;
    _type = null;
    _tagsOf = <String, String>{};
    _nodeIds = <int>[];
    _members = <OsmMember>[];
  }

  void _open(String name, Map<String, String> open) {
    switch (name) {
      case 'create' || 'modify' || 'delete':
        _action = name;
      case 'node' || 'way' || 'relation':
        _finish();
        _type = OsmElementType.values.byName(name);
        _attributes = open;
      case 'tag':
        final key = open['k'], value = open['v'];
        if (key != null && value != null) _tagsOf[key] = value;
      case 'nd':
        final ref = int.tryParse(open['ref'] ?? '');
        if (ref != null) _nodeIds.add(ref);
      case 'member':
        final ref = int.tryParse(open['ref'] ?? '');
        final kind = open['type'];
        if (ref == null || kind == null) return;
        if (!OsmElementType.values.any((t) => t.name == kind)) return;
        _members.add(
          OsmMember(
            type: OsmElementType.values.byName(kind),
            ref: ref,
            role: open['role'] ?? '',
          ),
        );
    }
  }

  void _close(String name) {
    switch (name) {
      case 'node' || 'way' || 'relation':
        _finish();
      case 'create' || 'modify' || 'delete':
        _action = null;
    }
  }
}

XmlElement _build({
  required String? action,
  required OsmElementType type,
  required Map<String, String> attributes,
  required Map<String, String> tags,
  required List<int> nodeIds,
  required List<OsmMember> members,
}) {
  final id = int.tryParse(attributes['id'] ?? '');
  if (id == null) {
    throw OsmXmlException('A ${type.name} has no id');
  }
  final version = int.tryParse(attributes['version'] ?? '');
  final visible = attributes['visible'] != 'false';
  final info = _info(attributes, version);
  final held = tags.isEmpty ? const <String, String>{} : tags;

  final element = switch (type) {
    OsmElementType.node => () {
        final latitude = double.tryParse(attributes['lat'] ?? '');
        final longitude = double.tryParse(attributes['lon'] ?? '');
        // A deleted node is often given without one, and there is nothing
        // honest to put in its place.
        if (latitude == null || longitude == null) return null;
        return OsmNode(
          id: id,
          latitude: latitude,
          longitude: longitude,
          tags: held,
          info: info,
        );
      }(),
    OsmElementType.way => OsmWay(
        id: id,
        nodeIds: nodeIds,
        tags: held,
        info: info,
      ),
    OsmElementType.relation => OsmRelation(
        id: id,
        members: members,
        tags: held,
        info: info,
      ),
  };

  return XmlElement(
    action: action,
    type: type,
    id: id,
    version: version,
    visible: visible,
    element: element,
  );
}

OsmInfo? _info(Map<String, String> attributes, int? version) {
  final timestamp = attributes['timestamp'];
  final user = attributes['user'];
  final info = OsmInfo(
    version: version,
    timestamp: timestamp == null ? null : DateTime.tryParse(timestamp)?.toUtc(),
    changeset: int.tryParse(attributes['changeset'] ?? ''),
    uid: int.tryParse(attributes['uid'] ?? ''),
    user: user == null || user.isEmpty ? null : user,
    // An element in an OsmChange is there whatever `visible` claims: the
    // enclosing create, modify or delete says what happened to it.
    visible: attributes['visible'] != 'false',
  );
  return info.version == null &&
          info.timestamp == null &&
          info.changeset == null &&
          info.uid == null &&
          info.user == null
      ? null
      : info;
}

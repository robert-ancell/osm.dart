import 'edit.dart';
import 'element.dart';

/// What kind of relation a relation is, as far as editing it goes.
///
/// Editing moves members between relations, splits and joins them, and has
/// to know which relations care about how their members join up.
enum OsmRelationKind {
  /// A relation with nothing more to it than its members.
  other,

  /// An ordered run of ways, such as a bus route, whose members' order and
  /// `forward` and `backward` roles follow the ways.
  route,

  /// A boundary around an area.
  boundary,

  /// An area made of `outer` and `inner` rings of ways.
  multipolygon,

  /// A turn restriction, from a way, through a node or ways, to a way.
  restriction,

  /// Lane connectivity from one way to another through a junction.
  connectivity,

  /// A destination sign, from a way, at an intersection, to a way.
  destinationSign,

  /// A group of things that belong together without being joined, such as
  /// the houses along a street.
  grouping,
}

/// What an [OsmEditor] needs to know about tags.
///
/// The editor itself only knows about nodes, ways and relations: what it
/// takes to split a way, join two or pull a node out of them. What the tags
/// say — whether a closed way is an area, which way a oneway runs, which
/// tags go where when a way becomes two — differs from one tool to the
/// next, and each tool says it by implementing this.
///
/// [OsmPlainTagRules] knows as little about tags as it can.
/// [OsmStandardTagRules] knows how OpenStreetMap is commonly tagged.
abstract interface class OsmTagRules {
  /// Whether a closed way with [tags] is an area rather than a line.
  bool isArea(Map<String, String> tags);

  /// Whether [tags] say what a thing is, rather than only where the data
  /// came from.
  ///
  /// A node on a way that says nothing is part of the way: it goes when the
  /// way goes, and is not copied or pulled out on its own. One that says
  /// something is a thing in its own right.
  bool isDescriptive(Map<String, String> tags);

  /// Why [element] should not be deleted, or null if it can be.
  ///
  /// Asked of each element selected for deleting, with [editor] to look up
  /// what uses it.
  OsmDisabledReason? protects(OsmElement element, OsmEditor editor);

  /// [tags] for something that now faces the other way.
  ///
  /// [standalone] is a node on its own, whose compass direction turns with
  /// it, rather than one along a way that turned. [oneway] turns a oneway
  /// round too, which reversing a way to join it to another needs.
  Map<String, String> reversed(
    Map<String, String> tags, {
    required bool standalone,
    bool oneway = false,
  });

  /// A way's role in a relation once the way has been turned round.
  String reversedRole(String role);

  /// Whether a way with [tags] has a right side and a wrong one, and so
  /// sets the direction of what it is joined to.
  bool isSided(Map<String, String> tags);

  /// Whether ways with tags [a] and [b] say different things, so that
  /// joining them end to end would lose one.
  bool conflicts(Map<String, String> a, Map<String, String> b);

  /// The tags of two ways joined end to end, [into] being the one that
  /// stays.
  Map<String, String> joined(Map<String, String> into, Map<String, String> b);

  /// The tags of two things made one in any other way — a point merged into
  /// a way, nodes made one — [into] being the one that stays.
  Map<String, String> combined(
    Map<String, String> into,
    Map<String, String> b,
  );

  /// The tags of the two pieces a way with [tags] is split into, the first
  /// being [share] of it by length.
  (Map<String, String>, Map<String, String>) divided(
    Map<String, String> tags,
    double share,
  );

  /// What pulling a point out of [way] leaves: the point's tags and the
  /// way's, or null if [way] has nothing to pull out.
  ({Map<String, String> point, Map<String, String> way})? extracted(
    OsmWay way,
    OsmEditor editor,
  );

  /// How an area with [tags] divides when it becomes part of a multipolygon:
  /// what goes to the relation and what stays on the way.
  ({Map<String, String> relation, Map<String, String> way}) intoMultipolygon(
    Map<String, String> tags,
  );

  /// [tags] made to describe a closed way as an area, and no more than it
  /// takes.
  Map<String, String> asArea(Map<String, String> tags);

  /// What kind of relation [relation] is.
  OsmRelationKind kindOf(OsmRelation relation);
}

/// Rules that know as little about tags as they can: for a tool that edits
/// shapes and leaves what they mean to whoever is using it.
///
/// A closed way is an area when it says `area=yes`, anything tagged is a
/// thing in its own right, nothing is protected from deleting, tags are left
/// as they are when something turns round, ways whose tags disagree are not
/// joined, and relations are told apart by their `type`.
class OsmPlainTagRules implements OsmTagRules {
  /// Creates the rules.
  const OsmPlainTagRules();

  @override
  bool isArea(Map<String, String> tags) => tags['area'] == 'yes';

  @override
  bool isDescriptive(Map<String, String> tags) => tags.isNotEmpty;

  @override
  OsmDisabledReason? protects(OsmElement element, OsmEditor editor) => null;

  @override
  Map<String, String> reversed(
    Map<String, String> tags, {
    required bool standalone,
    bool oneway = false,
  }) =>
      tags;

  @override
  String reversedRole(String role) => role;

  @override
  bool isSided(Map<String, String> tags) => false;

  @override
  bool conflicts(Map<String, String> a, Map<String, String> b) =>
      a.entries.any((e) => b.containsKey(e.key) && b[e.key] != e.value);

  @override
  Map<String, String> joined(
    Map<String, String> into,
    Map<String, String> b,
  ) =>
      combined(into, b);

  @override
  Map<String, String> combined(
    Map<String, String> into,
    Map<String, String> b,
  ) =>
      {...b, ...into};

  @override
  (Map<String, String>, Map<String, String>) divided(
    Map<String, String> tags,
    double share,
  ) =>
      (tags, tags);

  @override
  ({Map<String, String> point, Map<String, String> way})? extracted(
    OsmWay way,
    OsmEditor editor,
  ) =>
      null;

  @override
  ({Map<String, String> relation, Map<String, String> way}) intoMultipolygon(
    Map<String, String> tags,
  ) =>
      (relation: {...tags}..remove('area'), way: const {});

  @override
  Map<String, String> asArea(Map<String, String> tags) {
    final without = Map.of(tags)..remove('area');
    return isArea(without) ? without : {...without, 'area': 'yes'};
  }

  @override
  OsmRelationKind kindOf(OsmRelation relation) {
    final type = relation.tags['type'] ?? '';
    return switch (type) {
      'route' => OsmRelationKind.route,
      'boundary' => OsmRelationKind.boundary,
      'multipolygon' => OsmRelationKind.multipolygon,
      'destination_sign' => OsmRelationKind.destinationSign,
      'associatedStreet' || 'enforcement' || 'site' => OsmRelationKind.grouping,
      _ when RegExp(r'^restriction:?').hasMatch(type) =>
        OsmRelationKind.restriction,
      _ when RegExp(r'^connectivity:?').hasMatch(type) =>
        OsmRelationKind.connectivity,
      _ => OsmRelationKind.other,
    };
  }
}

/// Why an [OsmOperation] cannot be done.
///
/// The ones here are those the editor itself gives, and those
/// [OsmStandardTagRules] gives; [OsmTagRules] can give reasons of their own
/// by making more.
class OsmDisabledReason {
  /// A name for the reason, which messages saying it can be looked up by.
  final String id;

  /// Creates a reason called [id].
  const OsmDisabledReason(this.id);

  /// Nothing selected is something it can be done to, or not all of it is.
  static const notEligible = OsmDisabledReason('not_eligible');

  /// A way that is part of a route or a boundary, or the outside of a
  /// multipolygon, which deleting would leave a hole in.
  static const partOfRelation = OsmDisabledReason('part_of_relation');

  /// Something linked from Wikidata, which is not deleted by accident.
  static const hasWikidataTag = OsmDisabledReason('has_wikidata_tag');

  /// A relation it is part of has not been read in full, so what the change
  /// does to it cannot be worked out.
  static const parentIncomplete = OsmDisabledReason('parent_incomplete');

  /// A roundabout that is part of a larger relation, which splitting would
  /// break.
  static const simpleRoundabout = OsmDisabledReason('simple_roundabout');

  /// The result would have more nodes than a way may.
  static const tooManyVertices = OsmDisabledReason('too_many_vertices');

  /// The lines do not meet end to end.
  static const notAdjacent = OsmDisabledReason('not_adjacent');

  /// The lines are in different relations.
  static const conflictingRelations =
      OsmDisabledReason('conflicting_relations');

  /// The lines cross, so joining them would make a line that crosses itself.
  static const pathsIntersect = OsmDisabledReason('paths_intersect');

  /// It would break a turn restriction.
  static const restriction = OsmDisabledReason('restriction');

  /// It would break a lane connectivity relation.
  static const connectivity = OsmDisabledReason('connectivity');

  /// The things say different things about the same tag.
  static const conflictingTags = OsmDisabledReason('conflicting_tags');

  /// A multipolygon it involves has not been read in full.
  static const incompleteRelation = OsmDisabledReason('incomplete_relation');

  /// It would break a relation, whose members it joins or separates.
  static const relation = OsmDisabledReason('relation');

  /// Nothing is joined here to be disconnected.
  static const notConnected = OsmDisabledReason('not_connected');

  @override
  String toString() => 'OsmDisabledReason($id)';
}

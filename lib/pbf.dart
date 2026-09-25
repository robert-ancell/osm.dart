/// Reading, writing and updating OpenStreetMap `.osm.pbf` files.
///
/// Use it with `package:osm/osm.dart`, which has the elements a file holds,
/// the change files that update one and the replication feeds they come
/// from.
///
/// ## Reading a PBF file
///
/// ```dart
/// import 'package:osm/osm.dart';
/// import 'package:osm/pbf.dart';
///
/// final file = await OsmPbfFile.open('extract.osm.pbf');
///
/// await for (final element in file.elements()) {
///   print('${element.type.name} ${element.id}');
/// }
/// ```
///
/// Elements are decoded a block at a time as they are asked for, so a file much
/// larger than memory can be processed by streaming through it. Each one is an
/// `OsmNode`, `OsmWay` or `OsmRelation`, with its tags and, if the file carries
/// metadata, the version, timestamp, changeset and user of the edit that made
/// it.
///
/// ## Taking part of a file
///
/// Say what you want with an [OsmFilter] rather than filtering the stream
/// afterwards:
///
/// ```dart
/// final parks = file.elements(
///   filter: const OsmFilter.tag('leisure', 'park'),
/// );
/// ```
///
/// The filter is used to skip work rather than to throw away its results. A
/// block whose string table does not hold the key is dropped without looking at
/// a single element, elements of a type that cannot match are never decoded,
/// and an element without the key is never built into an object. What is left
/// is decoded across every core.
///
/// Finding the few hundred elements with a tag in a 434 MB country extract
/// takes 1.7s, against 25s to read the same file end to end. Filters combine
/// with `&`, `|` and [OsmFilter.not], and [OsmFilter.where] takes a test
/// written as code for anything they cannot say.
///
/// ## Building geometry
///
/// A way names its nodes by id, so matching it is only half of what it takes to
/// draw it. `subset` reads the matches and everything they refer to:
///
/// ```dart
/// final parks = await file.subset(
///   const OsmFilter.tag('leisure', 'park'),
/// );
///
/// for (final park in parks.matches) {
///   if (park is! OsmWay) continue;
///   final outline = parks.nodesOf(park);
///   if (outline == null) continue; // Runs off the edge of the file.
///   print('${park.tags['name']}: ${outline.length} points');
/// }
/// ```
///
/// It holds the matches made complete: the nodes of matching ways, the members
/// of matching relations, and so on down. Pulling a few hundred areas and their
/// 17,690 nodes out of a 434 MB country extract takes 7.4s.
///
/// Everything read is held in memory, so filter to what is wanted. `elements()`
/// is there for reads too big to keep.
///
/// ## Reading an area
///
/// ```dart
/// final inside = await file.within([
///   const OsmBounds(
///     minLatitude: 48.85,
///     minLongitude: 2.33,
///     maxLatitude: 48.87,
///     maxLongitude: 2.36,
///   ),
/// ]);
/// ```
///
/// The nodes standing in the boxes, the ways using any of them along with the
/// rest of their nodes wherever those are, and the relations with any of those
/// as a member. What a kept relation refers to is not read: a relation is kept
/// because it has something here, not because it belongs here, and reading the
/// rest of a bus route that happens to pass by would pull in the country around
/// it.
///
/// ## Writing a file
///
/// ```dart
/// final writer = await OsmPbfWriter.create('out.osm.pbf', header: file.header);
/// await writer.addAll(file.elements().where(wanted));
/// await writer.close();
/// ```
///
/// Elements are gathered into blocks and written as they fill, so a file larger
/// than memory can be written by streaming through it. Hand the header of what
/// you read back to keep what the file says about itself — the replication
/// state above all, which an extract that loses can never be brought up to date
/// again.
///
/// A header declaring `Sort.Type_then_ID` is taken as a promise and checked, so
/// a file cannot quietly come out claiming an order its elements do not have.
///
/// ## Applying changes
///
/// ```dart
/// final transformer = OsmPbfTransformer(
///     [for (final path in diffs) ...await OsmChangeFile.read(path)]);
/// final counts = await transformer.transform(
///   input: 'extract.osm.pbf',
///   output: 'updated.osm.pbf',
///   header: file.header.copyWith(replicationSequenceNumber: 4906),
/// );
/// ```
///
/// Changes are taken in the order given, so hand the diffs over in the order
/// OpenStreetMap published them. Move the replication state on in the header,
/// because a file that loses it can never be brought up to date again.
///
/// ## Keeping a snapshot up to date
///
/// `OsmPbfUpdater` reads the planet's replication diffs published since a
/// snapshot's own timestamp — hours, then minutes — keeps the changes that
/// touch what the snapshot holds, and writes it back with them applied. The
/// rest of the planet's edits are dropped as they are read, so it works from
/// the planet's own feed rather than waiting on a regional one.
///
/// What the snapshot holds is decided by the nodes in it, so the region is its
/// shape rather than its bounding box, and a country across the antimeridian is
/// no trouble. A way reaching past the edge, or a node moved in from outside,
/// is looked up through the OpenStreetMap API, or with no client listed in the
/// result as due a fresh snapshot.
///
/// ## From an extract's own diffs
///
/// Geofabrik publishes a diff a day for each of its extracts, made by comparing
/// one day's extract with the next. For a country that is a few hundred
/// kilobytes a day rather than the planet's gigabytes, and nothing in it needs
/// deciding: it already holds what entered or left the extract.
///
/// ```dart
/// final feed = OsmReplication.geofabrik('europe/monaco',
///     contact: 'Your Name <you@example.com>');
/// const day = OsmReplicationPeriod.day;
/// final first = await feed.firstAfter(day, file.header.replicationTimestamp!);
/// final latest = await feed.latest(day);
/// final changes = [
///   for (var s = first; s <= latest.sequence; s++)
///     ...await OsmChangeFile.read((await feed.download(day, s)).path),
/// ];
/// ```
///
/// and then `OsmPbfTransformer` as above. A block of the file no change falls
/// in is copied as it is, so a day of a country's changes is seconds rather
/// than the whole file written again.
///
/// A day is a long time to wait for an edit of your own. `OsmApiClient` lists a
/// mapper's changesets since a moment and gives back what each one changed, a
/// few kilobytes apiece, to apply the same way:
///
/// ```dart
/// final client = OsmApiClient(contact: 'Your Name <you@example.com>');
/// final since = file.header.replicationTimestamp!;
/// final changes = [
///   for (final changeset in (await client.changesetsBy('Your Name', since: since))
///       .reversed)
///     ...await client.changesetChanges(changeset.id),
/// ];
/// ```
///
/// When the day's diff arrives with the same edits in it, they are no newer
/// than the file and are skipped.
library;

export 'src/filter.dart';
export 'src/pbf/exception.dart';
export 'src/pbf/file.dart';
export 'src/pbf/header.dart';
export 'src/pbf/transformer.dart';
export 'src/pbf/writer.dart';
export 'src/region.dart';
export 'src/update/change_filter.dart' show OsmUpdateEdges;
export 'src/update/updater.dart';

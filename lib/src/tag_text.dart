/// Tags as text, one `key=value` to a line, for one element or several.
///
/// The way iD's text view shows them, and for the same reason: a text box is
/// the quickest thing there is to read a set of tags in, paste a set into,
/// and change several of at once.
///
/// Several elements are shown as one set. A tag every one of them has with
/// the same value is shown as it is; one they disagree on, or that only some
/// of them have, is shown as `key=*`. Editing the text then says what to do
/// to all of them, and leaving a line alone leaves each element's own value
/// alone.
library;

/// What a tag the elements disagree on is shown as.
const osmMixedTagValue = '*';

/// The text for the tags of the elements in [tagSets].
///
/// One line to a tag, in order of key, so the same tags always come out as
/// the same text.
String osmTagText(List<Map<String, String>> tagSets) {
  if (tagSets.isEmpty) return '';
  final keys = <String>{for (final tags in tagSets) ...tags.keys}.toList()
    ..sort();
  return [
    for (final key in keys) '$key=${_sharedValue(tagSets, key)}',
  ].join('\n');
}

/// The value every element has for [key], or [osmMixedTagValue] if they do
/// not all have the same one.
String _sharedValue(List<Map<String, String>> tagSets, String key) {
  final first = tagSets.first[key];
  if (first == null) return osmMixedTagValue;
  for (final tags in tagSets.skip(1)) {
    if (tags[key] != first) return osmMixedTagValue;
  }
  return first;
}

/// The tags in [text], in the order they are written, keys and values
/// trimmed.
///
/// A line with nothing before its `=` says nothing and is left out. A line
/// with no `=` at all is a key with no value, which is what taking the value
/// off a line leaves, and is read as asking for that tag to go. Where a key
/// is written twice, the later line wins.
List<(String, String)> osmParseTagText(String text) {
  final found = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final equals = line.indexOf('=');
    final key = (equals < 0 ? line : line.substring(0, equals)).trim();
    if (key.isEmpty) continue;
    final value = equals < 0 ? '' : line.substring(equals + 1).trim();
    // Removed first, so that a key written again moves to where it was
    // written last.
    found.remove(key);
    found[key] = value;
  }
  return [for (final entry in found.entries) (entry.key, entry.value)];
}

/// The tags each of [tagSets] ends up with once the text [before] — what was
/// shown for them, by [osmTagText] — has been edited into [after].
///
/// Only what was changed is changed:
///
/// * a line left as it was leaves every element's own value alone, which
///   for a `key=*` line is whatever each of them has;
/// * a value written in sets that value on every element;
/// * a line taken out, or left with no value, takes the tag off every
///   element;
/// * a new line adds the tag to every element;
/// * a key renamed on a `key=*` line moves each element's own value to the
///   new key. A renamed key shows as one line gone and a new one with no
///   value of its own to give, and the two are paired in the order they are
///   written. A renamed key with a value written in needs no pairing: the
///   old one goes and the new one is set.
///
/// The result is in the same order as [tagSets]. An element whose tags come
/// out the same is given back the same tags.
List<Map<String, String>> osmApplyTagText(
  List<Map<String, String>> tagSets, {
  required String before,
  required String after,
}) {
  final shown = {
    for (final (key, value) in osmParseTagText(before)) key: value,
  };
  final edited = osmParseTagText(after);
  final editedKeys = {for (final (key, _) in edited) key};

  final gone = [
    for (final key in shown.keys)
      if (!editedKeys.contains(key)) key,
  ];
  final unvalued = [
    for (final (key, value) in edited)
      if (!shown.containsKey(key) && value == osmMixedTagValue) key,
  ];
  final renamed = <String, String>{
    for (var i = 0; i < gone.length && i < unvalued.length; i++)
      unvalued[i]: gone[i],
  };
  final movedFrom = renamed.values.toSet();

  return [
    for (final tags in tagSets)
      _applied(tags, shown, edited, gone, renamed, movedFrom),
  ];
}

Map<String, String> _applied(
  Map<String, String> tags,
  Map<String, String> shown,
  List<(String, String)> edited,
  List<String> gone,
  Map<String, String> renamed,
  Set<String> movedFrom,
) {
  final out = Map<String, String>.of(tags);
  for (final key in gone) {
    if (!movedFrom.contains(key)) out.remove(key);
  }
  for (final MapEntry(key: to, value: from) in renamed.entries) {
    final value = tags[from];
    out.remove(from);
    if (value != null) out[to] = value;
  }
  for (final (key, value) in edited) {
    if (renamed.containsKey(key)) continue;
    // Left as it was, or asking each to keep its own: nothing to do.
    if (value == osmMixedTagValue || shown[key] == value) continue;
    if (value.isEmpty) {
      out.remove(key);
    } else {
      out[key] = value;
    }
  }
  return _same(out, tags) ? tags : out;
}

bool _same(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

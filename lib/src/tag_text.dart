/// Tags as text, one `key=value` to a line, for one element or several.
///
/// A text box is the quickest thing there is to read a set of tags in, paste a
/// set into, and change several of at once.
///
/// Several elements are shown as one set. A tag every one of them has with
/// the same value is shown as it is; one they disagree on, or that only some
/// of them have, is shown as `key=*`. Editing the text then says what to do
/// to all of them, and leaving such a line alone leaves each element's own
/// value alone.
///
/// A `*` only means that on a line that was shown for a mix of values.
/// Anywhere else it is a value like any other: OpenStreetMap allows it, so
/// it can be shown and it can be set.
///
/// A key or value that could not be told apart from the text around it — one
/// holding an `=`, a quote, a backslash or a line break — is written in double
/// quotes with JSON's escapes, so that whatever is on the map comes back out of
/// the text exactly as it went in.
library;

import 'dart:convert';

/// The tags of one element or several, as text that can be edited.
///
/// Made from each element's tags, it holds the [text] to show; given the
/// text as it was edited, [apply] says what each element's tags become.
class OsmTagText {
  /// What a tag the elements disagree on, or only some of them have, is
  /// shown as.
  static const mixed = '*';

  /// Each element's tags, in the order the elements were given.
  final List<Map<String, String>> tagSets;

  /// The text shown for [tagSets].
  ///
  /// One line to a tag, in order of key, so the same tags always come out
  /// as the same text; see the library documentation for how a tag they
  /// disagree on is shown and how awkward keys and values are written.
  final String text;

  /// The text for the tags in [tagSets].
  ///
  /// [text] can be given instead of worked out, for a text that was shown
  /// for these tags earlier and has been applied since: what an edit is
  /// compared with is what was on screen when it was made.
  OsmTagText(List<Map<String, String>> tagSets, {String? text})
      : tagSets = List.unmodifiable(tagSets),
        text = text ?? _format(tagSets);

  /// The tags in [text], in the order they are written.
  ///
  /// A key or value in double quotes is read with JSON's escapes; anything
  /// else is taken as it is, trimmed. A line with nothing for a key says
  /// nothing and is left out. A line with no `=` at all is a key with no
  /// value, which is what taking the value off a line leaves, and is read
  /// as asking for that tag to go. Where a key is written twice, the later
  /// line wins.
  static List<(String, String)> parse(String text) => _parse(text);

  /// What each element's tags become once [text] is edited to [edited], in
  /// the order of [tagSets].
  ///
  /// Only what was changed is changed:
  ///
  /// * a line left as it was leaves every element's own value alone, which
  ///   for a line shown mixed as `key=*` is whatever each of them has;
  /// * a value written in sets that value on every element, and that
  ///   includes `*` anywhere but on a line shown mixed;
  /// * a line taken out, or left with no value, takes the tag off every
  ///   element;
  /// * a new line adds the tag to every element;
  /// * a key renamed on a line shown mixed, and left as `*`, moves each
  ///   element's own value to the new key. A renamed key shows as one line
  ///   gone and a new one, and a mixed line gone is paired with a new `*`
  ///   line in the order they are written. A key renamed with a value
  ///   written in needs no pairing: the old one goes and the new one is set.
  ///
  /// An element whose tags come out the same is given back the same tags.
  List<Map<String, String>> apply(String edited) =>
      _apply(tagSets, before: text, after: edited);
}

/// The text for [tagSets]; see [OsmTagText.text].
String _format(List<Map<String, String>> tagSets) {
  if (tagSets.isEmpty) return '';
  final keys = <String>{for (final tags in tagSets) ...tags.keys}.toList()
    ..sort();
  return [
    for (final key in keys)
      '${_quoted(key)}=${switch (_sharedValue(tagSets, key)) {
        null => OsmTagText.mixed,
        final value => _quoted(value),
      }}',
  ].join('\n');
}

/// The value every element has for [key], or null if they do not all have
/// the same one.
String? _sharedValue(List<Map<String, String>> tagSets, String key) {
  final first = tagSets.first[key];
  if (first == null) return null;
  for (final tags in tagSets.skip(1)) {
    if (tags[key] != first) return null;
  }
  return first;
}

/// [text] as it is written in a line: as it is if it reads back the same,
/// and in double quotes with JSON's escapes if it would not.
///
/// A real `*` is written bare, the same as a mixed one: which of the two a
/// line holds is known from the elements, not from the text.
String _quoted(String text) {
  final escaped = jsonEncode(text);
  final bare = escaped.substring(1, escaped.length - 1);
  // Quoted as well when it would otherwise be misread: an equals sign splits
  // a line, space at either end is trimmed off, and a value that starts and
  // ends with a quote would be taken for a quoted one.
  final needsQuotes = bare != text ||
      text.contains('=') ||
      text.trim() != text ||
      (text.length > 1 && text.startsWith('"') && text.endsWith('"'));
  return needsQuotes ? escaped : text;
}

/// The tags in [text]; see [OsmTagText.parse].
List<(String, String)> _parse(String text) {
  final found = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final (key, rest) = _splitKey(line);
    if (key.isEmpty) continue;
    final value = rest == null ? '' : _unquoted(rest.trim());
    // Removed first, so that a key written again moves to where it was
    // written last.
    found.remove(key);
    found[key] = value;
  }
  return [for (final entry in found.entries) (entry.key, entry.value)];
}

/// The key at the start of [line], and whatever follows its `=`, or null if
/// there is no `=`.
///
/// A quoted key is read to its closing quote, so an `=` inside it is part of
/// the key rather than the end of it.
(String, String?) _splitKey(String line) {
  if (line.startsWith('"')) {
    final end = _closingQuote(line);
    if (end > 0) {
      final after = line.substring(end + 1).trimLeft();
      if (after.isEmpty || after.startsWith('=')) {
        final key = _unquoted(line.substring(0, end + 1));
        return (key, after.isEmpty ? null : after.substring(1));
      }
    }
  }
  final equals = line.indexOf('=');
  if (equals < 0) return (line, null);
  return (line.substring(0, equals).trim(), line.substring(equals + 1));
}

/// Where the quote closing the one [text] starts with is, or -1 if it is
/// never closed.
int _closingQuote(String text) {
  for (var i = 1; i < text.length; i++) {
    final c = text[i];
    if (c == r'\') {
      i++;
    } else if (c == '"') {
      return i;
    }
  }
  return -1;
}

/// [text] with its quotes and escapes read, if it is quoted, and as it is
/// otherwise — including when the quotes do not hold valid escapes, since
/// what someone typed is better kept than thrown away.
String _unquoted(String text) {
  if (text.length < 2 || !text.startsWith('"') || !text.endsWith('"')) {
    return text;
  }
  try {
    final read = jsonDecode(text);
    return read is String ? read : text;
  } on FormatException {
    return text;
  }
}

/// [tagSets] with the edit from [before] to [after]; see [OsmTagText.apply].
List<Map<String, String>> _apply(
  List<Map<String, String>> tagSets, {
  required String before,
  required String after,
}) {
  final shown = {
    for (final (key, value) in _parse(before)) key: value,
  };
  // Mixed by what the elements hold, not by what the text says: a `*` every
  // one of them really has is a value, not a mix.
  bool mixed(String key) =>
      shown[key] == OsmTagText.mixed &&
      tagSets.isNotEmpty &&
      _sharedValue(tagSets, key) == null;

  final edited = _parse(after);
  final editedKeys = {for (final (key, _) in edited) key};

  final gone = [
    for (final key in shown.keys)
      if (!editedKeys.contains(key)) key,
  ];
  final goneMixed = [
    for (final key in gone)
      if (mixed(key)) key,
  ];
  final newStars = [
    for (final (key, value) in edited)
      if (!shown.containsKey(key) && value == OsmTagText.mixed) key,
  ];
  final renamed = <String, String>{
    for (var i = 0; i < goneMixed.length && i < newStars.length; i++)
      newStars[i]: goneMixed[i],
  };
  final movedFrom = renamed.values.toSet();

  return [
    for (final tags in tagSets)
      _applied(tags, shown, edited, gone, renamed, movedFrom, mixed),
  ];
}

Map<String, String> _applied(
  Map<String, String> tags,
  Map<String, String> shown,
  List<(String, String)> edited,
  List<String> gone,
  Map<String, String> renamed,
  Set<String> movedFrom,
  bool Function(String key) mixed,
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
    // A mixed line left mixed: each keeps its own.
    if (value == OsmTagText.mixed && mixed(key)) continue;
    // A line left as it was: nothing to do.
    if (shown[key] == value) continue;
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

import 'exception.dart';

/// The largest character Unicode defines.
const int _maxCodePoint = 0x10ffff;

/// Reads the tags of an XML document, in the order they appear.
///
/// Only as much XML as OpenStreetMap's own files use: elements, attributes,
/// empty elements, comments and the declaration. No namespaces, no document
/// type definitions, and no text content, which OSM's XML never carries
/// anything in.
///
/// Written rather than taken as a dependency because this is the whole of it,
/// and because a package read by an app is better off with nothing behind it.
void readXml(
  String source, {
  required void Function(String name, Map<String, String> attributes) onOpen,
  required void Function(String name) onClose,
}) {
  var at = 0;

  Never fail(String message) => throw OsmXmlException(message, offset: at);

  void skipSpace() {
    while (at < source.length && _isSpace(source.codeUnitAt(at))) {
      at++;
    }
  }

  String readName() {
    final start = at;
    while (at < source.length && _isNameChar(source.codeUnitAt(at))) {
      at++;
    }
    if (at == start) fail('Expected a name');
    return source.substring(start, at);
  }

  void skipTo(String end) {
    final found = source.indexOf(end, at);
    if (found < 0) fail('Unterminated ${end == '>' ? 'tag' : end}');
    at = found + end.length;
  }

  while (true) {
    final open = source.indexOf('<', at);
    if (open < 0) return;
    at = open + 1;
    if (at >= source.length) fail('Document ends in a tag');

    // The declaration, comments and a document type say nothing worth
    // hearing here.
    if (source.startsWith('?', at)) {
      skipTo('?>');
      continue;
    }
    if (source.startsWith('!--', at)) {
      skipTo('-->');
      continue;
    }
    if (source.startsWith('!', at)) {
      skipTo('>');
      continue;
    }

    if (source.startsWith('/', at)) {
      at++;
      final name = readName();
      skipSpace();
      if (at >= source.length || source[at] != '>') fail('Expected >');
      at++;
      onClose(name);
      continue;
    }

    final name = readName();
    final attributes = <String, String>{};
    while (true) {
      skipSpace();
      if (at >= source.length) fail('Unterminated tag');

      if (source.startsWith('/>', at)) {
        at += 2;
        onOpen(name, attributes);
        onClose(name);
        break;
      }
      if (source[at] == '>') {
        at++;
        onOpen(name, attributes);
        break;
      }

      final attribute = readName();
      skipSpace();
      if (at >= source.length || source[at] != '=') fail('Expected =');
      at++;
      skipSpace();
      if (at >= source.length) fail('Expected a value');
      final quote = source[at];
      if (quote != '"' && quote != "'") fail('Expected a quoted value');
      at++;
      final end = source.indexOf(quote, at);
      if (end < 0) fail('Unterminated value');
      attributes[attribute] = _unescape(source.substring(at, end), at);
      at = end + 1;
    }
  }
}

/// The characters this has to know apart, by the code unit each one is.
abstract final class _Char {
  static const int tab = 0x09;
  static const int newline = 0x0a;
  static const int carriageReturn = 0x0d;
  static const int space = 0x20;
  static const int hyphen = 0x2d;
  static const int fullStop = 0x2e;
  static const int zero = 0x30;
  static const int nine = 0x39;
  static const int colon = 0x3a;
  static const int upperA = 0x41;
  static const int upperZ = 0x5a;
  static const int underscore = 0x5f;
  static const int lowerA = 0x61;
  static const int lowerZ = 0x7a;
}

bool _isSpace(int c) =>
    c == _Char.space ||
    c == _Char.tab ||
    c == _Char.newline ||
    c == _Char.carriageReturn;

bool _isNameChar(int c) =>
    (c >= _Char.lowerA && c <= _Char.lowerZ) ||
    (c >= _Char.upperA && c <= _Char.upperZ) ||
    (c >= _Char.zero && c <= _Char.nine) ||
    c == _Char.underscore ||
    c == _Char.colon ||
    c == _Char.hyphen ||
    c == _Char.fullStop;

/// Puts back the five entities XML defines and any character written by
/// number.
///
/// An entity that is none of those is an error rather than something to pass
/// through: a tag value that quietly keeps its `&raquo;` is worse than one
/// that stops the read.
String _unescape(String value, int offset) {
  if (!value.contains('&')) return value;

  final out = StringBuffer();
  var at = 0;
  while (at < value.length) {
    final amp = value.indexOf('&', at);
    if (amp < 0) {
      out.write(value.substring(at));
      break;
    }
    out.write(value.substring(at, amp));
    final end = value.indexOf(';', amp);
    if (end < 0) {
      throw OsmXmlException('Unterminated entity', offset: offset + amp);
    }
    final entity = value.substring(amp + 1, end);
    switch (entity) {
      case 'amp':
        out.write('&');
      case 'lt':
        out.write('<');
      case 'gt':
        out.write('>');
      case 'quot':
        out.write('"');
      case 'apos':
        out.write("'");
      default:
        final code = entity.startsWith('#x') || entity.startsWith('#X')
            ? int.tryParse(entity.substring(2), radix: 16)
            : entity.startsWith('#')
                ? int.tryParse(entity.substring(1))
                : null;
        if (code == null || code < 0 || code > _maxCodePoint) {
          throw OsmXmlException(
            'Unknown entity &$entity;',
            offset: offset + amp,
          );
        }
        out.writeCharCode(code);
    }
    at = end + 1;
  }
  return out.toString();
}

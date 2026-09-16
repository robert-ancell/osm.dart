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
}) =>
    XmlTagReader(onOpen: onOpen, onClose: onClose)
      ..add(source)
      ..close();

/// Reads the tags of an XML document handed over a piece at a time.
///
/// A tag cut in two by where one piece ends is held until the next piece
/// finishes it, so a file can be read as it is decompressed without ever
/// being whole in memory.
class XmlTagReader {
  /// Called for each tag that opens, including an empty one.
  final void Function(String name, Map<String, String> attributes) onOpen;

  /// Called for each tag that closes, including an empty one.
  final void Function(String name) onClose;

  /// What has been handed over and not yet read: at most the start of one
  /// tag, once [add] returns.
  String _pending = '';

  /// Where [_pending] starts in the whole document, for saying where a
  /// failure is.
  int _consumed = 0;

  /// Creates a reader calling [onOpen] and [onClose] as tags go by.
  XmlTagReader({required this.onOpen, required this.onClose});

  /// Reads the next piece of the document.
  void add(String piece) {
    final source = _pending.isEmpty ? piece : '$_pending$piece';
    final read = _read(source);
    _pending = source.substring(read);
    _consumed += read;
  }

  /// Says the document is done. Throws if it ended inside a tag.
  void close() {
    final open = _pending.indexOf('<');
    if (open >= 0) {
      throw OsmXmlException(
        'Document ends in a tag',
        offset: _consumed + open,
      );
    }
    _pending = '';
  }

  /// Reads the whole tags at the start of [source], and gives back how much
  /// of it they took.
  int _read(String source) {
    var at = 0;

    Never fail(String message) =>
        throw OsmXmlException(message, offset: _consumed + at);

    void skipSpace() {
      while (at < source.length && _isSpace(source.codeUnitAt(at))) {
        at++;
      }
    }

    String? readName() {
      final start = at;
      while (at < source.length && _isNameChar(source.codeUnitAt(at))) {
        at++;
      }
      if (at == source.length) return null;
      if (at == start) fail('Expected a name');
      return source.substring(start, at);
    }

    while (true) {
      final open = source.indexOf('<', at);
      if (open < 0) return source.length;
      at = open + 1;

      // From here to the end of the tag, running out means the tag goes on
      // in the next piece, and all of it waits for that.
      if (at >= source.length) return open;
      // `<!` could yet be the start of a comment.
      if (source.startsWith('!', at) && at + 3 > source.length) return open;

      // The declaration, comments and a document type say nothing worth
      // hearing here.
      final String? end;
      if (source.startsWith('?', at)) {
        end = '?>';
      } else if (source.startsWith('!--', at)) {
        end = '-->';
      } else if (source.startsWith('!', at)) {
        end = '>';
      } else {
        end = null;
      }
      if (end != null) {
        final found = source.indexOf(end, at);
        if (found < 0) return open;
        at = found + end.length;
        continue;
      }

      if (source.startsWith('/', at)) {
        at++;
        final name = readName();
        if (name == null) return open;
        skipSpace();
        if (at >= source.length) return open;
        if (source[at] != '>') fail('Expected >');
        at++;
        onClose(name);
        continue;
      }

      final name = readName();
      if (name == null) return open;
      final attributes = <String, String>{};
      var whole = false;
      while (true) {
        skipSpace();
        if (at >= source.length) break;

        if (source.startsWith('/>', at)) {
          at += 2;
          whole = true;
          onOpen(name, attributes);
          onClose(name);
          break;
        }
        if (source[at] == '/') {
          if (at + 1 >= source.length) break;
          fail('Expected />');
        }
        if (source[at] == '>') {
          at++;
          whole = true;
          onOpen(name, attributes);
          break;
        }

        final attribute = readName();
        if (attribute == null) break;
        skipSpace();
        if (at >= source.length) break;
        if (source[at] != '=') fail('Expected =');
        at++;
        skipSpace();
        if (at >= source.length) break;
        final quote = source[at];
        if (quote != '"' && quote != "'") fail('Expected a quoted value');
        final valueEnd = source.indexOf(quote, at + 1);
        if (valueEnd < 0) break;
        attributes[attribute] = _unescape(
          source.substring(at + 1, valueEnd),
          _consumed + at + 1,
        );
        at = valueEnd + 1;
      }
      if (!whole) return open;
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

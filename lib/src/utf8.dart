import 'dart:convert';

import 'exception.dart';

/// [bytes] as UTF-8 text, or what [fail] makes of it if they are not.
String decodeUtf8(List<int> bytes, OsmException Function(String) fail) {
  try {
    return utf8.decode(bytes);
  } on FormatException catch (e) {
    throw fail('Not UTF-8 text: ${e.message}');
  }
}

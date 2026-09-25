import 'dart:io';

import 'package:osm/osm.dart';
import 'package:osm/pbf.dart';
import 'package:test/test.dart';

void main() {
  test('is an OsmException, with something to say, whatever went wrong', () {
    final bounds = OsmBounds(
      minLatitude: 0,
      minLongitude: 0,
      maxLatitude: 1,
      maxLongitude: 1,
    );
    final all = <OsmException>[
      const OsmXmlException('bad'),
      const OsmPbfException('bad'),
      const OsmJsonException('bad'),
      const OsmReplicationException('bad'),
      OsmHttpException(Uri.parse('https://example.org/'), 500),
      const OsmAbandonedException(),
      OsmTooMuchDataException(bounds, 'too big'),
      const OsmAuthenticationException('bad'),
      const OsmAuthenticationCancelledException(),
      const OsmUploadException('bad'),
    ];
    for (final exception in all) {
      expect(exception.message, isNotEmpty, reason: '$exception');
    }
  });

  test('is still an IOException where it is a failure to fetch', () {
    expect(
      OsmHttpException(Uri.parse('https://example.org/'), 500),
      isA<IOException>(),
    );
    expect(const OsmAbandonedException(), isA<IOException>());
  });

  test('says a resource that is not JSON is not, rather than failing to cast',
      () {
    for (final read in <void Function()>[
      () => OsmImageryIndex.parse('<html>'),
      () => OsmCountryCoder.parse('<html>'),
      () => OsmPresets.parse(presets: '<html>', translations: '{}'),
    ]) {
      expect(read, throwsA(isA<OsmJsonException>()));
      expect(read, throwsA(isA<FormatException>()));
    }
  });

  test('says a file that is not UTF-8 cannot be read', () async {
    final directory = Directory.systemTemp.createTempSync('exception');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/bad.osm')
      ..writeAsBytesSync([0x3c, 0xff, 0xfe, 0x3e]);
    expect(OsmXmlFile.read(file.path), throwsA(isA<OsmXmlException>()));
    expect(
      OsmChangeFile.read(file.path),
      throwsA(isA<OsmXmlException>()),
    );
  });
}

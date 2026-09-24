import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// What [tagSets] come out as once the text shown for them is edited by
/// [edit].
List<Map<String, String>> _edited(
  List<Map<String, String>> tagSets,
  String Function(String shown) edit,
) {
  final shown = osmTagText(tagSets);
  return osmApplyTagText(tagSets, before: shown, after: edit(shown));
}

void main() {
  group('showing', () {
    test('writes one tag to a line, in order of key', () {
      expect(
        osmTagText([
          {'name': 'Queen Street', 'highway': 'primary'},
        ]),
        'highway=primary\nname=Queen Street',
      );
    });

    test('shows a tag every element has the same as it is', () {
      expect(
        osmTagText([
          {'highway': 'residential'},
          {'highway': 'residential'},
        ]),
        'highway=residential',
      );
    });

    test('shows a tag the elements disagree on as a star', () {
      expect(
        osmTagText([
          {'name': 'Queen Street'},
          {'name': 'King Street'},
        ]),
        'name=*',
      );
    });

    test('shows a tag only some of them have as a star', () {
      expect(
        osmTagText([
          {'highway': 'residential', 'name': 'Queen Street'},
          {'highway': 'residential'},
        ]),
        'highway=residential\nname=*',
      );
    });

    test('shows nothing for nothing', () {
      expect(osmTagText([]), '');
      expect(osmTagText([{}]), '');
    });
  });

  group('reading', () {
    test('reads a key and a value from each line', () {
      expect(osmParseTagText('a=1\nb = 2 \n\n'), [('a', '1'), ('b', '2')]);
    });

    test('keeps everything after the first equals sign in the value', () {
      expect(osmParseTagText('note=a=b'), [('note', 'a=b')]);
    });

    test('reads a line with no equals sign as a key with no value', () {
      expect(osmParseTagText('name'), [('name', '')]);
    });

    test('leaves out a line with no key', () {
      expect(osmParseTagText('=value'), isEmpty);
    });

    test('takes the later of a key written twice', () {
      expect(osmParseTagText('a=1\nb=2\na=3'), [('b', '2'), ('a', '3')]);
    });
  });

  group('changing one element', () {
    const road = {'highway': 'residential', 'name': 'Queen Street'};

    test('changes a value', () {
      expect(_edited([road], (t) => t.replaceFirst('residential', 'service')), [
        {'highway': 'service', 'name': 'Queen Street'},
      ]);
    });

    test('adds a tag', () {
      expect(_edited([road], (t) => '$t\nsurface=asphalt'), [
        {...road, 'surface': 'asphalt'},
      ]);
    });

    test('takes a tag off when its line goes', () {
      expect(_edited([road], (t) => 'highway=residential'), [
        {'highway': 'residential'},
      ]);
    });

    test('takes a tag off when its value goes', () {
      expect(_edited([road], (t) => t.replaceFirst('=Queen Street', '=')), [
        {'highway': 'residential'},
      ]);
    });

    test('renames a key, keeping its value', () {
      expect(_edited([road], (t) => t.replaceFirst('name=', 'old_name=')), [
        {'highway': 'residential', 'old_name': 'Queen Street'},
      ]);
    });

    test('gives back the same tags when nothing changed', () {
      final tags = {...road};
      final out = _edited([tags], (t) => t);
      expect(identical(out.single, tags), isTrue);
    });
  });

  group('changing several at once', () {
    const queen = {'highway': 'residential', 'name': 'Queen Street'};
    const king = {'highway': 'residential', 'name': 'King Street'};
    const unnamed = {'highway': 'residential'};

    test('leaves each its own value on a line left as a star', () {
      final out = _edited([queen, king, unnamed], (t) => '$t\nlit=yes');
      expect(out, [
        {...queen, 'lit': 'yes'},
        {...king, 'lit': 'yes'},
        {...unnamed, 'lit': 'yes'},
      ]);
    });

    test('sets a value written over a star on all of them', () {
      final out = _edited(
        [queen, king, unnamed],
        (t) => t.replaceFirst('name=*', 'name=High Street'),
      );
      for (final tags in out) {
        expect(tags['name'], 'High Street');
      }
    });

    test('changes a value they share on all of them', () {
      final out = _edited(
        [queen, king],
        (t) => t.replaceFirst('residential', 'tertiary'),
      );
      expect(out.map((tags) => tags['highway']), ['tertiary', 'tertiary']);
      expect(out.map((tags) => tags['name']), ['Queen Street', 'King Street']);
    });

    test('takes a star line off all of them', () {
      final out = _edited([queen, king, unnamed], (t) => 'highway=residential');
      expect(out, [unnamed, unnamed, unnamed]);
    });

    test('moves each its own value when a star line is renamed', () {
      final out = _edited(
        [queen, king, unnamed],
        (t) => t.replaceFirst('name=*', 'old_name=*'),
      );
      expect(out, [
        {'highway': 'residential', 'old_name': 'Queen Street'},
        {'highway': 'residential', 'old_name': 'King Street'},
        unnamed,
      ]);
    });

    test('pairs renames in the order they are written', () {
      final a = {'x': '1', 'y': '2'};
      final b = {'x': '3', 'y': '4'};
      final out = _edited([a, b], (t) => 'p=*\nq=*');
      expect(out, [
        {'p': '1', 'q': '2'},
        {'p': '3', 'q': '4'},
      ]);
    });

    test('writes a new star line as a star, there being nothing mixed', () {
      final out = _edited([queen, king], (t) => '$t\nsurface=*');
      expect(out.map((tags) => tags['surface']), ['*', '*']);
    });

    test('writes a star over a shared value as a star', () {
      final out = _edited(
        [queen, king],
        (t) => t.replaceFirst('highway=residential', 'highway=*'),
      );
      expect(out.map((tags) => tags['highway']), ['*', '*']);
      expect(out.map((tags) => tags['name']), ['Queen Street', 'King Street']);
    });

    test('carries values across a rename only from a mixed line', () {
      // highway is shared, so renaming it with a star says to write a star;
      // there is no mix of values for the star to stand for.
      final out = _edited([queen, king], (t) => 'road=*\nname=*');
      expect(out, [
        {'road': '*', 'name': 'Queen Street'},
        {'road': '*', 'name': 'King Street'},
      ]);
    });

    test('gives back the same tags for those it did not change', () {
      final out = _edited(
        [queen, unnamed],
        (t) => t.replaceFirst('name=*', ''),
      );
      expect(identical(out[1], unnamed), isTrue);
    });
  });

  group('a real star', () {
    test('is shown as it is', () {
      expect(
          osmTagText([
            {'note': '*'},
          ]),
          'note=*');
    });

    test('is left as it is when its line is left alone', () {
      final tags = {'note': '*', 'name': 'x'};
      expect(identical(_edited([tags], (t) => t).single, tags), isTrue);
    });

    test('is not mistaken for a mix when every element has it', () {
      const a = {'note': '*'};
      const b = {'note': '*'};
      final out = _edited([a, b], (t) => 'note=done');
      expect(out, [
        {'note': 'done'},
        {'note': 'done'},
      ]);
    });

    test('can be set on one element', () {
      expect(
          _edited([
            {'name': 'x'}
          ], (t) => 'name=*'),
          [
            {'name': '*'},
          ]);
    });
  });

  group('quoting', () {
    /// [tags] shown and read back unchanged.
    Map<String, String> roundTrip(Map<String, String> tags) => {
          for (final (key, value) in osmParseTagText(osmTagText([tags])))
            key: value,
        };

    test('leaves ordinary tags bare', () {
      expect(
          osmTagText([
            {'name': 'Queen Street', 'name:mi': 'Kuini'},
          ]),
          'name=Queen Street\nname:mi=Kuini');
    });

    test('quotes a value holding an equals sign and reads it back', () {
      const tags = {'note': 'a=b'};
      expect(osmTagText([tags]), 'note="a=b"');
      expect(roundTrip(tags), tags);
    });

    test('quotes a key holding an equals sign and reads it back', () {
      // Read to its closing quote: split at the first equals sign it would
      // come apart.
      const tags = {'a=b': 'c'};
      expect(osmTagText([tags]), '"a=b"=c');
      expect(roundTrip(tags), tags);
    });

    test('keeps a line break inside a value', () {
      const tags = {'description': 'first line\nsecond line'};
      expect(osmTagText([tags]).split('\n'), hasLength(1));
      expect(roundTrip(tags), tags);
    });

    test('keeps quotes, backslashes and space at the ends', () {
      for (final value in ['"quoted"', r'back\slash', ' padded ', 'say "hi"']) {
        expect(roundTrip({'note': value}), {'note': value}, reason: value);
      }
    });

    test('keeps what was typed when its quotes do not read', () {
      expect(osmParseTagText(r'note="\q"'), [('note', r'"\q"')]);
    });

    test('takes an edit made to a quoted value', () {
      const tags = {'note': 'a=b'};
      final out = _edited([tags], (t) => t.replaceFirst('a=b', 'a=c'));
      expect(out, [
        {'note': 'a=c'},
      ]);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/content_block.dart';

/// The parser IS the security boundary. Everything a remote document is
/// allowed to do to this app has to get past these rules, so most of this file
/// is about what gets REJECTED.
void main() {
  group('the closed registry', () {
    test('a known type parses', () {
      final b = ContentBlock.tryParse({'type': 'notice', 'body': 'hello'});
      expect(b, isNotNull);
      expect(b!.type, 'notice');
    });

    test('an unknown type is dropped, not rendered', () {
      // Forward compatibility: a newer document may name a block this build
      // was never taught. Skipping is correct; guessing would not be.
      expect(
        ContentBlock.tryParse({'type': 'video_player', 'body': 'x'}),
        isNull,
      );
      expect(ContentBlock.tryParse({'type': 'webview', 'body': 'x'}), isNull);
    });

    test('a missing type is dropped', () {
      expect(ContentBlock.tryParse({'body': 'orphan'}), isNull);
    });
  });

  group('actions are constrained', () {
    test('an https url action is allowed', () {
      final b = ContentBlock.tryParse({
        'type': 'link',
        'title': 'Docs',
        'action': 'url',
        'action_target': 'https://example.com/help',
      });
      expect(b!.action, BlockAction.url);
    });

    test('plain http is refused', () {
      // A remote document must not be able to point a user at an
      // unencrypted host.
      expect(
        ContentBlock.tryParse({
          'type': 'link',
          'title': 'x',
          'action': 'url',
          'action_target': 'http://example.com',
        }),
        isNull,
      );
    });

    test('app and file schemes are refused', () {
      for (final target in [
        'ugam://internal/admin',
        'file:///etc/passwd',
        'javascript:alert(1)',
        'intent://scan/#Intent;scheme=zxing;end',
      ]) {
        expect(
          ContentBlock.tryParse({
            'type': 'link',
            'title': 'x',
            'action': 'url',
            'action_target': target,
          }),
          isNull,
          reason: '$target must not be launchable from remote content',
        );
      }
    });

    test('a url action with no target is refused', () {
      expect(
        ContentBlock.tryParse({'type': 'link', 'title': 'x', 'action': 'url'}),
        isNull,
      );
    });

    test('a route action keeps only the NAME — resolution is compiled in', () {
      final b = ContentBlock.tryParse({
        'type': 'link',
        'title': 'Bookings',
        'action': 'route',
        'action_target': 'my_bookings',
      });
      expect(b!.action, BlockAction.route);
      expect(b.actionTarget, 'my_bookings');
    });

    test('an unrecognised action verb becomes inert, not an error', () {
      final b = ContentBlock.tryParse({
        'type': 'notice',
        'body': 'x',
        'action': 'execute',
        'action_target': 'rm -rf /',
      });
      expect(b!.action, BlockAction.none);
      expect(b.actionTarget, isNull,
          reason: 'an inert block must not retain a target');
    });
  });

  group('images', () {
    test('an https image is kept', () {
      final b = ContentBlock.tryParse({
        'type': 'banner',
        'image_url': 'https://cdn.example.com/a.png',
      });
      expect(b!.imageUrl, 'https://cdn.example.com/a.png');
    });

    test('a non-https image is dropped but the block survives', () {
      final b = ContentBlock.tryParse({
        'type': 'banner',
        'title': 'Still shows',
        'image_url': 'http://cdn.example.com/a.png',
      });
      expect(b, isNotNull);
      expect(b!.imageUrl, isNull);
      expect(b.title, 'Still shows');
    });
  });

  group('tolerance', () {
    test('an empty block is dropped', () {
      expect(ContentBlock.tryParse({'type': 'notice'}), isNull);
      expect(
        ContentBlock.tryParse({'type': 'notice', 'title': '   ', 'body': ''}),
        isNull,
        reason: 'whitespace-only is nothing to show',
      );
    });

    test('non-map input is dropped', () {
      for (final junk in ['a string', 42, null, ['a', 'list']]) {
        expect(ContentBlock.tryParse(junk), isNull);
      }
    });

    test('an unknown tone falls back to neutral', () {
      final b = ContentBlock.tryParse(
          {'type': 'notice', 'body': 'x', 'tone': 'apocalyptic'});
      expect(b!.tone, 'neutral');
    });
  });

  group('parseDocument', () {
    test('one bad block does not cost the others', () {
      final blocks = ContentBlock.parseDocument({
        'blocks': [
          {'type': 'notice', 'body': 'first'},
          {'type': 'nonsense', 'body': 'dropped'},
          null,
          'a string',
          {'type': 'link', 'title': 'third'},
        ],
      });
      expect(blocks, hasLength(2));
      expect(blocks.first.body, 'first');
      expect(blocks.last.title, 'third');
    });

    test('a malformed document yields nothing rather than throwing', () {
      for (final junk in [null, 'string', 42, <String, Object>{}, {'blocks': 'nope'}]) {
        expect(ContentBlock.parseDocument(junk), isEmpty);
      }
    });

    test('an empty blocks array is the remote off switch', () {
      // Publishing {"blocks": []} must clear the slot everywhere.
      expect(ContentBlock.parseDocument({'blocks': []}), isEmpty);
    });
  });
}

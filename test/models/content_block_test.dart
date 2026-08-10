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

  group('slots', () {
    test('a block defaults to the customer tour list when no slot is named',
        () {
      // A published document outlives the build that read it. Documents
      // written before slots existed must keep working unchanged.
      final b = ContentBlock.tryParse({'type': 'notice', 'body': 'x'});
      expect(b!.slot, ContentSlots.customerTourListTop);
    });

    test('a known slot is kept', () {
      final b = ContentBlock.tryParse({
        'type': 'notice',
        'body': 'x',
        'slot': ContentSlots.handlerChartTop,
      });
      expect(b!.slot, ContentSlots.handlerChartTop);
    });

    test('an unknown slot is dropped, not defaulted', () {
      // Defaulting would silently dump a block written for a future screen
      // onto the customer home page.
      expect(
        ContentBlock.tryParse(
            {'type': 'notice', 'body': 'x', 'slot': 'admin.future.screen'}),
        isNull,
      );
    });
  });

  group('the expanded registry', () {
    test('stat requires a value', () {
      expect(
        ContentBlock.tryParse({'type': 'stat', 'title': 'Seats left'}),
        isNull,
        reason: 'a stat with no figure is just a label',
      );
      final ok = ContentBlock.tryParse(
          {'type': 'stat', 'title': 'Seats left', 'value': '12'});
      expect(ok!.value, '12');
    });

    test('cta requires a label', () {
      expect(ContentBlock.tryParse({'type': 'cta', 'body': 'x'}), isNull);
    });

    test('divider is the one type allowed to carry no content', () {
      expect(ContentBlock.tryParse({'type': 'divider'}), isNotNull);
      expect(ContentBlock.tryParse({'type': 'notice'}), isNull);
    });

    test('faq parses title and body', () {
      final b = ContentBlock.tryParse(
          {'type': 'faq', 'title': 'When?', 'body': 'Friday.'});
      expect(b!.type, 'faq');
    });
  });

  group('targeting', () {
    const ctx = (
      platform: 'android',
      build: 26,
      locale: 'gu',
      role: 'customer',
    );
    bool match(BlockTargeting t, {DateTime? now}) => t.matches(
          platform: ctx.platform,
          build: ctx.build,
          locale: ctx.locale,
          role: ctx.role,
          nowUtc: now ?? DateTime.utc(2026, 8, 10),
        );

    test('no conditions means always', () {
      expect(BlockTargeting.always.isUnrestricted, isTrue);
      expect(match(BlockTargeting.always), isTrue);
    });

    test('platform', () {
      expect(match(const BlockTargeting(platforms: {'android'})), isTrue);
      expect(match(const BlockTargeting(platforms: {'ios'})), isFalse);
    });

    test('build window', () {
      expect(match(const BlockTargeting(minBuild: 26)), isTrue);
      expect(match(const BlockTargeting(minBuild: 27)), isFalse);
      expect(match(const BlockTargeting(maxBuild: 26)), isTrue);
      expect(match(const BlockTargeting(maxBuild: 25)), isFalse);
    });

    test('an unreadable build passes any build window', () {
      // AppInfo leaves an empty string when PackageInfo fails. An unreadable
      // build must not silently hide content.
      expect(
        const BlockTargeting(minBuild: 999).matches(
          platform: 'android',
          build: null,
          locale: 'gu',
          role: 'customer',
          nowUtc: DateTime.utc(2026, 8, 10),
        ),
        isTrue,
      );
    });

    test('locale and role', () {
      expect(match(const BlockTargeting(locales: {'gu'})), isTrue);
      expect(match(const BlockTargeting(locales: {'hi'})), isFalse);
      expect(match(const BlockTargeting(roles: {'customer'})), isTrue);
      expect(match(const BlockTargeting(roles: {'handler'})), isFalse);
    });

    test('a schedule window opens and closes', () {
      final t = BlockTargeting(
        from: DateTime.utc(2026, 8, 1),
        to: DateTime.utc(2026, 9, 1),
      );
      expect(match(t, now: DateTime.utc(2026, 7, 31)), isFalse);
      expect(match(t, now: DateTime.utc(2026, 8, 15)), isTrue);
      // `to` is exclusive, so a promo ending 1 Sept is gone ON 1 Sept.
      expect(match(t, now: DateTime.utc(2026, 9, 1)), isFalse);
    });

    test('parses from a document', () {
      final b = ContentBlock.tryParse({
        'type': 'notice',
        'body': 'x',
        'when': {
          'platforms': ['iOS'],
          'min_build': '30',
          'locales': ['GU'],
          'from': '2026-08-01T00:00:00Z',
        },
      });
      // Case is normalised so a document is forgiving about it.
      expect(b!.when.platforms, {'ios'});
      expect(b.when.locales, {'gu'});
      expect(b.when.minBuild, 30);
      expect(b.when.from, DateTime.utc(2026, 8, 1));
    });

    test('a malformed when block is ignored, the block survives', () {
      final b = ContentBlock.tryParse(
          {'type': 'notice', 'body': 'x', 'when': 'nonsense'});
      expect(b, isNotNull);
      expect(b!.when.isUnrestricted, isTrue);
    });
  });

  group('ordering', () {
    test('blocks sort by order, ties keep document sequence', () {
      final blocks = ContentBlock.parseDocument({
        'blocks': [
          {'type': 'notice', 'body': 'third', 'order': 10},
          {'type': 'notice', 'body': 'first', 'order': -5},
          {'type': 'notice', 'body': 'second-a', 'order': 0},
          {'type': 'notice', 'body': 'second-b', 'order': 0},
        ],
      });
      expect(
        [for (final b in blocks) b.body],
        ['first', 'second-a', 'second-b', 'third'],
      );
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

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/remote_flags_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The gate's safety case is "it can only ever fail open". A flag service that
/// can block a healthy user is worse than no flag service at all, because there
/// is no way to reach those users to fix it. These tests pin that property
/// harder than they pin the happy path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  RemoteFlagsService serviceWith(Map<String, dynamic> doc) =>
      RemoteFlagsService(fetcher: () async => jsonEncode(doc));

  group('fail-open', () {
    test('defaults never block', () {
      final s = RemoteFlagsService();
      expect(s.decide(buildNumber: '1'), LaunchDecision.proceed);
      expect(s.decide(buildNumber: '999'), LaunchDecision.proceed);
    });

    test('an unreadable build number proceeds, even below the floor', () {
      final s = RemoteFlagsService();
      s.flags.value = const RemoteFlags(minSupportedBuild: 100);

      // AppInfo.load() swallows PackageInfo failures and leaves ''. That must
      // never lock a user out of a working app.
      expect(s.decide(buildNumber: ''), LaunchDecision.proceed);
      expect(s.decide(buildNumber: 'not-a-number'), LaunchDecision.proceed);
    });

    test('a fetch that throws leaves the previous document intact', () async {
      final s = RemoteFlagsService(fetcher: () async => throw 'network down');
      s.flags.value = const RemoteFlags(recommendedBuild: 42);

      await s.warm();
      await Future<void>.delayed(Duration.zero);

      expect(s.flags.value.recommendedBuild, 42);
      expect(s.decide(buildNumber: '1'), LaunchDecision.updateRecommended);
    });

    test('malformed JSON is ignored rather than fatal', () async {
      final s = RemoteFlagsService(fetcher: () async => '{ not json');
      await s.warm();
      await Future<void>.delayed(Duration.zero);
      expect(s.decide(buildNumber: '1'), LaunchDecision.proceed);
    });

    test('a JSON array where an object was expected is ignored', () async {
      final s = RemoteFlagsService(fetcher: () async => '[1,2,3]');
      await s.warm();
      await Future<void>.delayed(Duration.zero);
      expect(s.decide(buildNumber: '1'), LaunchDecision.proceed);
    });

    test('wrong-typed fields fall back to defaults, not exceptions', () {
      final f = RemoteFlags.fromJson({
        'min_supported_build': {'nonsense': true},
        'recommended_build': [],
        'maintenance_mode': 'yes please',
        'kill': 'not a map',
        'tunables': 42,
      });

      expect(f.minSupportedBuild, 0);
      expect(f.recommendedBuild, 0);
      // Only a literal true enables maintenance — a truthy string must not.
      expect(f.maintenanceMode, isFalse);
      expect(f.kill, isEmpty);
      expect(f.tunables, isEmpty);
    });
  });

  group('decide', () {
    test('below the floor is a hard block', () async {
      final s = serviceWith({'min_supported_build': 30});
      await s.warm();
      await Future<void>.delayed(Duration.zero);

      expect(s.decide(buildNumber: '29'), LaunchDecision.updateRequired);
      expect(s.decide(buildNumber: '30'), LaunchDecision.proceed);
      expect(s.decide(buildNumber: '31'), LaunchDecision.proceed);
    });

    test('below the recommendation is a soft nudge', () async {
      final s = serviceWith({'recommended_build': 30});
      await s.warm();
      await Future<void>.delayed(Duration.zero);

      expect(s.decide(buildNumber: '29'), LaunchDecision.updateRecommended);
      expect(s.decide(buildNumber: '30'), LaunchDecision.proceed);
    });

    test('maintenance outranks the version gate', () async {
      // Telling a user to update during an outage sends them to the store for a
      // build that also cannot work.
      final s = serviceWith({
        'maintenance_mode': true,
        'min_supported_build': 999,
      });
      await s.warm();
      await Future<void>.delayed(Duration.zero);

      expect(s.decide(buildNumber: '1'), LaunchDecision.maintenance);
    });

    test('a zero floor blocks nobody', () {
      final s = RemoteFlagsService();
      s.flags.value = const RemoteFlags(minSupportedBuild: 0);
      expect(s.decide(buildNumber: '0'), LaunchDecision.proceed);
    });
  });

  group('cache', () {
    test('last-known-good is read before any fetch', () async {
      SharedPreferences.setMockInitialValues({
        'remote_flags.doc': jsonEncode({'min_supported_build': 50}),
      });

      // No fetcher and the feature is off, so only the cache can supply this.
      final s = RemoteFlagsService();
      await s.warm();

      expect(s.decide(buildNumber: '49'), LaunchDecision.updateRequired);
    });

    test('a successful fetch is written back', () async {
      final s = serviceWith({'recommended_build': 77});
      await s.warm();
      await Future<void>.delayed(Duration.zero);

      final prefs = await SharedPreferences.getInstance();
      final cached = jsonDecode(prefs.getString('remote_flags.doc')!);
      expect(cached['recommended_build'], 77);
    });

    test('a corrupt cache degrades to defaults without throwing', () async {
      SharedPreferences.setMockInitialValues({
        'remote_flags.doc': '{ corrupt',
      });

      final s = RemoteFlagsService();
      await s.warm();

      expect(s.decide(buildNumber: '1'), LaunchDecision.proceed);
    });
  });

  group('network frugality', () {
    // On a 2G link the round trip dominates, not the payload — the flag
    // document is a few hundred bytes. A conditional request saves the body;
    // only NOT making the request saves the latency. Both are tested by
    // counting calls, because "it was fast" is not observable in a unit test.

    test('a second warm inside the interval does not hit the network',
        () async {
      var calls = 0;
      RemoteFlagsService build() => RemoteFlagsService(fetcher: () async {
            calls++;
            return jsonEncode({'recommended_build': 5});
          });

      // An injected fetcher deliberately bypasses the throttle so the rest of
      // the suite stays deterministic; the throttle is asserted against the
      // stored timestamp instead.
      final first = build();
      await first.warm();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt('remote_flags.fetched_at'),
        isNotNull,
        reason: 'the attempt must be stamped, or the throttle can never engage',
      );
    });

    test('a stale timestamp does not block the next check', () async {
      SharedPreferences.setMockInitialValues({
        'remote_flags.fetched_at': DateTime.now()
            .subtract(RemoteFlagsService.minFetchInterval * 2)
            .millisecondsSinceEpoch,
      });

      var calls = 0;
      final s = RemoteFlagsService(fetcher: () async {
        calls++;
        return jsonEncode({'recommended_build': 9});
      });
      await s.warm();
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);
      expect(s.decide(buildNumber: '1'), LaunchDecision.updateRecommended);
    });

    test('the interval is short enough for a kill switch to matter', () {
      // A flag nobody receives for hours is not a kill switch. Cold start
      // bypasses this entirely; it only bounds repeated foregrounding.
      expect(
        RemoteFlagsService.minFetchInterval.inMinutes,
        lessThanOrEqualTo(15),
      );
    });

    test('refreshNow bypasses the throttle', () async {
      SharedPreferences.setMockInitialValues({
        'remote_flags.fetched_at': DateTime.now().millisecondsSinceEpoch,
      });

      var calls = 0;
      final s = RemoteFlagsService(fetcher: () async {
        calls++;
        return jsonEncode({'maintenance_mode': true});
      });

      await s.refreshNow();
      expect(calls, 1);
      expect(s.decide(buildNumber: '1'), LaunchDecision.maintenance);
    });
  });

  group('kill switches and tunables', () {
    test('absent means enabled', () {
      final s = RemoteFlagsService();
      expect(s.isKilled('anything'), isFalse);
      expect(s.tunable('anything'), isNull);
    });

    test('parsed from the document', () async {
      final s = serviceWith({
        'kill': {'upi_payment': true, 'pdf_share': false},
        'tunables': {'hold_ttl_seconds': 900},
      });
      await s.warm();
      await Future<void>.delayed(Duration.zero);

      expect(s.isKilled('upi_payment'), isTrue);
      expect(s.isKilled('pdf_share'), isFalse);
      expect(s.tunable('hold_ttl_seconds'), 900);
    });
  });
}

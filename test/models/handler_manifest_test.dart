import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/handler_manifest.dart';

void main() {
  test('fromJson parses groups and resolves labels', () {
    final m = HandlerManifest.fromJson({
      'groups': [
        {
          'id': 'g1',
          'tour_id': 't1',
          'label': 'Patel family',
          'color_index': 2,
          'created_at': '2026-01-01T00:00:00Z',
        },
      ],
    });
    expect(m.groups, hasLength(1));
    expect(m.groups.first.label, 'Patel family');
    expect(m.groupLabel('g1'), 'Patel family');
    expect(m.groupLabel('missing'), isNull);
    expect(m.groupLabel(null), isNull);
  });
}

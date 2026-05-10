import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/admin.dart';

void main() {
  group('Admin.fromMap', () {
    test('reads snake_case Postgres columns', () {
      final admin = Admin.fromMap({
        'id': 'uuid-abc',
        'phone': '9327148044',
        'name': 'Zeel',
        'whatsapp_number': '9327148044',
      });
      expect(admin.id, 'uuid-abc');
      expect(admin.phone, '9327148044');
      expect(admin.name, 'Zeel');
      expect(admin.whatsappNumber, '9327148044');
    });
    test('whatsappNumber may be null', () {
      final admin = Admin.fromMap({
        'id': 'x',
        'phone': '9999999999',
        'name': 'Test',
      });
      expect(admin.whatsappNumber, isNull);
    });
  });
  group('Admin.effectiveWhatsappNumber', () {
    test('falls back to phone when whatsapp_number is null', () {
      final a = Admin(id: 'x', phone: '9327148044', name: 'Z');
      expect(a.effectiveWhatsappNumber, '9327148044');
    });
    test('uses whatsapp_number when set', () {
      final a = Admin(
        id: 'x',
        phone: '9327148044',
        name: 'Z',
        whatsappNumber: '8888888888',
      );
      expect(a.effectiveWhatsappNumber, '8888888888');
    });
  });
}

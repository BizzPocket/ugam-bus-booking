import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../models/customer_memory.dart';
import '../models/priority_status.dart';
import '../models/tour.dart';
import '../services/sync_service.dart';
import '../utils/phone_normalize.dart';
import 'auth_controller.dart';

/// Per-admin, phone-keyed memory of returning customers.
///
/// ~80% of customers repeat across tours, but priority + group membership live
/// ONLY inside per-tour `passengers` rows, which cascade-delete with the tour.
/// [captureFromTour] snapshots that memory (priority + travel companions)
/// before a tour is deleted; [forPhone] / [companionPhonesFor] read it back so
/// a returning phone can have its priority auto-restored and its usual group
/// recreated in one tap.
class CustomerMemoryController extends GetxController {
  final memories = <CustomerMemory>[].obs;

  /// normalised phone → memory, rebuilt on every load/upsert for O(1) lookups.
  final _byPhone = <String, CustomerMemory>{};

  SyncService get _sync => Get.find<SyncService>();
  AuthController get _auth => Get.find<AuthController>();

  String? get _adminId => _auth.currentAdmin.value?.id;
  String get _cacheKey => 'customer_memory_${_adminId ?? "none"}';

  @override
  void onInit() {
    super.onInit();
    load();
  }

  /// (Re)load the current admin's memory rows. No-op on a non-admin session.
  Future<void> load() async {
    final adminId = _adminId;
    if (!_auth.isAdmin || adminId == null) {
      memories.clear();
      _byPhone.clear();
      return;
    }
    try {
      final data = await _sync.smartFetch(
        table: 'customer_memory',
        cacheKey: _cacheKey,
        filters: {'owner_id': adminId},
        orderBy: 'updated_at',
        maxAge: 120000,
      );
      memories.assignAll(data.map((m) => CustomerMemory.fromMap(m)).toList());
      _rebuildIndex();
    } catch (_) {
      // Best-effort — memory is an enhancement, never block the app on it.
    }
  }

  void _rebuildIndex() {
    _byPhone
      ..clear()
      ..addEntries(memories.map((m) => MapEntry(normalisePhone(m.phone), m)));
  }

  /// The remembered record for [phone], or null if this customer is new to
  /// the current admin. Accepts any phone format.
  CustomerMemory? forPhone(String phone) => _byPhone[normalisePhone(phone)];

  /// Phones this customer is remembered to travel with (the "travels with"
  /// union across past tours). Empty when unknown.
  List<String> companionPhonesFor(String phone) =>
      forPhone(phone)?.companions ?? const [];

  /// Snapshot every passenger of [tour] into customer memory BEFORE the tour
  /// (and its passenger rows) are deleted. Remembers:
  ///   • the agent's priority DECISION (approved / declined only — a fresh
  ///     `requested` comes from the customer each tour, so it isn't a trait);
  ///   • travel companions — the other phones sharing the passenger's group.
  /// Merges with any existing memory (companions union; latest decision wins).
  /// Best-effort: a failed row is skipped, the rest still save.
  Future<void> captureFromTour(Tour tour) async {
    final adminId = _adminId;
    if (!_auth.isAdmin || adminId == null) return;

    // groupId → normalised phones of its members (for the companions snapshot).
    final groupMembers = <String, List<String>>{};
    for (final p in tour.passengers) {
      final gid = p.groupId;
      if (gid == null) continue;
      final phone = normalisePhone(p.phone);
      if (phone.isEmpty) continue;
      (groupMembers[gid] ??= <String>[]).add(phone);
    }

    for (final p in tour.passengers) {
      final phone = normalisePhone(p.phone);
      if (phone.isEmpty) continue;

      final companions = <String>[];
      final gid = p.groupId;
      if (gid != null) {
        companions.addAll(
          (groupMembers[gid] ?? const []).where((ph) => ph != phone),
        );
      }

      final isDecision = p.priorityStatus == PriorityStatus.approved ||
          p.priorityStatus == PriorityStatus.declined;

      await _remember(
        ownerId: adminId,
        phone: phone,
        name: p.name,
        priorityStatus: isDecision ? p.priorityStatus : null,
        priorityReason: isDecision ? p.priorityReason : null,
        companions: companions,
      );
    }
  }

  /// Upsert one customer's memory, merging into any existing row. Pass a null
  /// [priorityStatus] to leave an existing decision untouched.
  Future<void> _remember({
    required String ownerId,
    required String phone,
    required String name,
    PriorityStatus? priorityStatus,
    String? priorityReason,
    List<String> companions = const [],
  }) async {
    final key = normalisePhone(phone);
    if (key.isEmpty) return;

    final existing = _byPhone[key];

    // Union companions, drop self.
    final mergedCompanions = <String>{
      ...?existing?.companions,
      ...companions,
    }..remove(key);

    final merged = (existing ??
            CustomerMemory(
              id: const Uuid().v4(),
              ownerId: ownerId,
              phone: key,
            ))
        .copyWith(
      name: name.trim().isNotEmpty ? name.trim() : null,
      priorityStatus: priorityStatus,
      priorityReason: priorityStatus != null ? priorityReason : null,
      companions: mergedCompanions.toList(),
    );

    // Optimistic local update so lookups reflect it immediately.
    _byPhone[key] = merged;
    final idx = memories.indexWhere((m) => m.id == merged.id);
    if (idx >= 0) {
      memories[idx] = merged;
    } else {
      memories.add(merged);
    }

    try {
      if (existing != null) {
        await _sync.smartUpdate(
          table: 'customer_memory',
          entityId: merged.id,
          data: merged.toMap(),
        );
      } else {
        await _sync.smartInsert(
          table: 'customer_memory',
          entityId: merged.id,
          data: merged.toMap(),
        );
      }
      await _sync.invalidateCache(_cacheKey);
    } catch (_) {
      // Best-effort; the in-memory copy still helps this session.
    }
  }
}

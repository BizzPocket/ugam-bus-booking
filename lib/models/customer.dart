import 'package:uuid/uuid.dart';
import 'age_group.dart';

class Customer {
  final String id;
  final String name;
  final String? mobileNumber;
  final AgeGroup ageGroup;
  final DateTime createdAt;

  Customer({
    String? id,
    required this.name,
    this.mobileNumber,
    required this.ageGroup,
    DateTime? createdAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  bool validate() {
    return name.trim().isNotEmpty;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Customer && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

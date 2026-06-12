/// Editable footer block for the seating chart (boarding place, departure time
/// text, and a free-form handler / return note). Persisted per tour via
/// [ChartFooterStore]. The `Tour` model has no boarding-place or
/// departure-time-text fields, so these live only in the footer.
class ChartFooter {
  /// Boarding place — rendered after "સ્થળ" on the chart.
  final String boardingPlace;

  /// Free text departure time, e.g. "સાંજે 5 વાગ્યે".
  final String departureTime;

  /// Handler / return note line.
  final String note;

  const ChartFooter({
    this.boardingPlace = '',
    this.departureTime = '',
    this.note = '',
  });

  bool get isEmpty =>
      boardingPlace.isEmpty && departureTime.isEmpty && note.isEmpty;

  Map<String, dynamic> toJson() => {
        'boardingPlace': boardingPlace,
        'departureTime': departureTime,
        'note': note,
      };

  factory ChartFooter.fromJson(Map<String, dynamic> json) => ChartFooter(
        boardingPlace: json['boardingPlace'] as String? ?? '',
        departureTime: json['departureTime'] as String? ?? '',
        note: json['note'] as String? ?? '',
      );

  ChartFooter copyWith({
    String? boardingPlace,
    String? departureTime,
    String? note,
  }) =>
      ChartFooter(
        boardingPlace: boardingPlace ?? this.boardingPlace,
        departureTime: departureTime ?? this.departureTime,
        note: note ?? this.note,
      );
}

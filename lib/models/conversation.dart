/// A named conversation thread.
class Conversation {
  final int? id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int messageCount;
  final DateTime? consolidatedAt;

  const Conversation({
    this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.messageCount = 0,
    this.consolidatedAt,
  });

  factory Conversation.fromMap(Map<String, dynamic> map) => Conversation(
        id: map['id'] as int?,
        title: map['title'] as String,
        createdAt: _parseDateTime(map['created_at']),
        updatedAt: _parseDateTime(map['updated_at']),
        messageCount: map['message_count'] as int? ?? 0,
        consolidatedAt: map['consolidated_at'] != null
            ? _parseDateTime(map['consolidated_at'])
            : null,
      );

  static DateTime _parseDateTime(dynamic value) {
    if (value is String) {
      try {
        return DateTime.parse(value);
      } catch (_) {}
    }
    return DateTime.now();
  }

  Conversation copyWith({
    int? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? messageCount,
    DateTime? consolidatedAt,
  }) =>
      Conversation(
        id: id ?? this.id,
        title: title ?? this.title,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        messageCount: messageCount ?? this.messageCount,
        consolidatedAt: consolidatedAt ?? this.consolidatedAt,
      );
}

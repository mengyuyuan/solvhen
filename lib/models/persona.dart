/// A user-created custom persona that layers on top of the base Solvhen personality.
/// Each persona is additive — base personality is always present, personas add instructions.
class Persona {
  final int? id;
  final String name;       // display name
  final String prompt;     // additional instructions appended to system prompt
  final bool active;       // currently selected?
  final DateTime createdAt;

  const Persona({
    this.id,
    required this.name,
    required this.prompt,
    this.active = false,
    required this.createdAt,
  });

  static DateTime _parseDateTime(dynamic value) {
    if (value is String) {
      try {
        return DateTime.parse(value);
      } catch (_) {
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    return DateTime.now();
  }

  factory Persona.fromMap(Map<String, dynamic> map) => Persona(
        id: map['id'] as int?,
        name: map['name'] as String,
        prompt: map['prompt'] as String,
        active: (map['active'] as int?) == 1,
        createdAt: _parseDateTime(map['created_at']),
      );

}

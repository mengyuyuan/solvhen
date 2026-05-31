/// Minimal self-registering tool registry — ported from Hermes.
///
/// Each tool module imports this singleton and calls registry.register().
/// Schema generation and dispatch are thread-safe via a simple Map.
library;

import 'dart:convert';

class ToolRegistry {
  static final ToolRegistry _instance = ToolRegistry._();
  factory ToolRegistry() => _instance;

  /// Create a truly independent registry (NOT the singleton).
  /// Use this when you need a filtered view — e.g. sub-agents
  /// that must not inherit the full global toolset.
  factory ToolRegistry.isolated() => ToolRegistry._();

  ToolRegistry._();

  final _tools = <String, ToolEntry>{};

  void register(ToolEntry entry) {
    _tools[entry.name] = entry;
  }

  /// Returns OpenAI-format function calling schemas for available tools.
  List<Map<String, dynamic>> getDefinitions(Set<String> toolNames) {
    return toolNames
        .map((name) => _tools[name])
        .where((e) => e != null && (e.checkFn?.call() ?? true))
        .map((e) => {
              'type': 'function',
              'function': e!.schema,
            })
        .toList();
  }

  /// Execute a tool handler by name. Returns JSON result string.
  Future<String> dispatch(String name, Map<String, dynamic> args) async {
    final entry = _tools[name];
    if (entry == null) return jsonEncode({'error': 'Unknown tool: $name'});
    try {
      return await entry.handler(args);
    } catch (e) {
      return jsonEncode({'error': 'Tool execution failed: $e'});
    }
  }

  bool contains(String name) => _tools.containsKey(name);

  ToolEntry? operator [](String name) => _tools[name];

  Set<String> get names => _tools.keys.toSet();

  /// Convenience: get all tool defs
  List<Map<String, dynamic>> getToolDefs() => getDefinitions(names);
}

class ToolEntry {
  final String name;
  final String toolset;
  final Map<String, dynamic> schema; // OpenAI function schema with name/description/parameters
  final Future<String> Function(Map<String, dynamic> args) handler;
  final bool Function()? checkFn; // null = always available

  const ToolEntry({
    required this.name,
    required this.toolset,
    required this.schema,
    required this.handler,
    this.checkFn,
  });
}

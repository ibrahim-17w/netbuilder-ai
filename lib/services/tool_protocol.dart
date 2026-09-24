import 'dart:convert';

/// The wire shapes for model tool-calling, for both providers.
///
/// Spec §3 wants the model to be able to ask for network information before it
/// answers, and §11 wants that to be provider-independent. This file is the
/// translation layer only: it builds the *declarations* the model sees, reads
/// the *calls* it asks for, and builds the *result* message to send back.
///
/// It is pure - no I/O - so the shapes are unit-tested rather than discovered
/// against a live endpoint. The loop that drives it lives in the chat.

class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;
  const ToolCall({required this.id, required this.name, required this.args});

  @override
  String toString() => '$name(${args.keys.join(', ')})';
}

class ToolProtocol {
  const ToolProtocol._();

  /// The tool catalogue as the engine reports it
  /// (`GET /tools/list` -> `{tools: [{name, kind, summary, args}]}`).
  static List<Map<String, dynamic>> catalogue(Object? engineReply) {
    if (engineReply is! Map) return const [];
    final tools = engineReply['tools'];
    if (tools is! List) return const [];
    return [
      for (final t in tools)
        if (t is Map) Map<String, dynamic>.from(t),
    ];
  }

  /// Gemini wants `tools:[{functionDeclarations:[{name, description,
  /// parameters}]}]` with OpenAPI-ish schema types in upper case.
  static List<Map<String, dynamic>> geminiDeclarations(
    List<Map<String, dynamic>> tools,
  ) {
    final declarations = <Map<String, dynamic>>[];
    for (final tool in tools) {
      final name = tool['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final args = (tool['args'] as Map?) ?? const {};
      final properties = <String, dynamic>{};
      for (final entry in args.entries) {
        properties[entry.key.toString()] = {
          'type': _geminiType(entry.value?.toString() ?? 'string'),
          'description': '${entry.key}',
        };
      }
      declarations.add({
        'name': name,
        'description': _describe(tool),
        'parameters': {
          'type': 'OBJECT',
          'properties': properties,
          if (properties.isNotEmpty)
            'required': properties.keys.toList(),
        },
      });
    }
    return declarations.isEmpty
        ? const []
        : [
            {'functionDeclarations': declarations},
          ];
  }

  /// OpenAI wants `tools:[{type:function, function:{name, description,
  /// parameters}}]` with lower-case schema types.
  static List<Map<String, dynamic>> openAiDeclarations(
    List<Map<String, dynamic>> tools,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final tool in tools) {
      final name = tool['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final args = (tool['args'] as Map?) ?? const {};
      final properties = <String, dynamic>{};
      for (final entry in args.entries) {
        properties[entry.key.toString()] = {
          'type': _openAiType(entry.value?.toString() ?? 'string'),
          'description': '${entry.key}',
        };
      }
      out.add({
        'type': 'function',
        'function': {
          'name': name,
          'description': _describe(tool),
          'parameters': {
            'type': 'object',
            'properties': properties,
            if (properties.isNotEmpty) 'required': properties.keys.toList(),
          },
        },
      });
    }
    return out;
  }

  /// The calls a provider asked for. Handles both shapes; anything malformed
  /// is skipped rather than crashing the turn.
  static List<ToolCall> parseCalls(Object? decoded) {
    if (decoded is! Map) return const [];
    final out = <ToolCall>[];

    // Gemini: candidates[0].content.parts[].functionCall{name, args}
    final candidates = decoded['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final content = (candidates.first as Map)['content'];
      final parts = (content is Map) ? content['parts'] : null;
      if (parts is List) {
        var index = 0;
        for (final part in parts) {
          if (part is! Map) continue;
          final call = part['functionCall'];
          if (call is! Map) continue;
          final name = call['name']?.toString() ?? '';
          if (name.isEmpty) continue;
          out.add(ToolCall(
            id: 'gemini-$index',
            name: name,
            args: Map<String, dynamic>.from((call['args'] as Map?) ?? const {}),
          ));
          index++;
        }
      }
    }

    // OpenAI: choices[0].message.tool_calls[].function{name, arguments(JSON)}
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final message = (choices.first as Map)['message'];
      final calls = (message is Map) ? message['tool_calls'] : null;
      if (calls is List) {
        for (final call in calls) {
          if (call is! Map) continue;
          final fn = call['function'];
          if (fn is! Map) continue;
          final name = fn['name']?.toString() ?? '';
          if (name.isEmpty) continue;
          out.add(ToolCall(
            id: call['id']?.toString() ?? name,
            name: name,
            args: _parseArgs(fn['arguments']),
          ));
        }
      }
    }
    return out;
  }

  /// The assistant turn that carries the calls back to the provider.
  static Map<String, dynamic> assistantTurn(List<ToolCall> calls) => {
    'role': 'assistant',
    'tool_calls': [
      for (final call in calls)
        {
          'id': call.id,
          'type': 'function',
          'function': {
            'name': call.name,
            'arguments': _encode(call.args),
          },
        },
    ],
  };

  /// The result message for one call. [result] is what the engine returned.
  static Map<String, dynamic> resultMessage(ToolCall call, Object? result) => {
    'role': 'tool',
    'tool_call_id': call.id,
    'name': call.name,
    'content': _encode(result),
  };

  /// A short, human status line for the UI - never raw reasoning (spec §4).
  static String statusLine(ToolCall call) {
    const friendly = {
      'get_topology': 'Reading the topology',
      'get_devices': 'Listing the devices',
      'get_device': 'Inspecting a device',
      'get_interfaces': 'Reading the interfaces',
      'get_device_config': 'Reading a configuration',
      'get_routing_table': 'Reading the routing table',
      'get_vlans': 'Checking the VLANs',
      'get_links': 'Checking the cabling',
      'get_network_summary': 'Summarising the network',
      'check_connectivity': 'Testing connectivity',
      'check_subnet': 'Comparing subnets',
      'check_gateway': 'Validating the default gateway',
      'check_routes': 'Checking the routing',
      'check_vlans': 'Checking the VLAN configuration',
      'check_dhcp': 'Checking DHCP',
      'check_acls': 'Checking the ACLs',
      'analyze_network': 'Analyzing the network',
      'validate_network': 'Validating the network',
    };
    final base = friendly[call.name] ?? 'Applying ${call.name}';
    final who = call.args['device'] ?? call.args['source'] ?? '';
    return who.toString().isEmpty ? '$base...' : '$base ($who)...';
  }

  static String _describe(Map<String, dynamic> tool) {
    final summary = tool['summary']?.toString() ?? '';
    final kind = tool['kind']?.toString() ?? 'read';
    final prefix = kind == 'modify'
        ? "PROPOSAL ONLY - requires the user's approval before it is applied. "
        : 'READ-ONLY. ';
    return '$prefix$summary';
  }

  static Map<String, dynamic> _parseArgs(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  static String _encode(Object? value) {
    if (value is String) return value;
    return jsonEncode(value);
  }

  static String _geminiType(String declared) {
    final t = declared.toLowerCase();
    if (t.contains('int') || t.contains('number')) return 'NUMBER';
    if (t.contains('bool')) return 'BOOLEAN';
    if (t.contains('list') || t.contains('array')) return 'ARRAY';
    return 'STRING';
  }

  static String _openAiType(String declared) {
    final t = declared.toLowerCase();
    if (t.contains('int') || t.contains('number')) return 'number';
    if (t.contains('bool')) return 'boolean';
    if (t.contains('list') || t.contains('array')) return 'array';
    return 'string';
  }
}

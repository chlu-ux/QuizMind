/// What this device needs to run the assistant itself: how to reach the model, the instructions and
/// tools, and the rules a question must meet. It comes from GET /agent/local-spec with the
/// server's access token, is kept in shared preferences, and so survives the server being out of reach.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class AgentToolSpec {
  const AgentToolSpec({required this.name, required this.description, required this.inputSchema});

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  Map<String, dynamic> toApi() => {'name': name, 'description': description, 'input_schema': inputSchema};

  factory AgentToolSpec.fromJson(Map<String, dynamic> j) => AgentToolSpec(
        name: (j['name'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        inputSchema: (j['input_schema'] as Map?)?.cast<String, dynamic>() ?? {'type': 'object', 'properties': {}},
      );

  Map<String, dynamic> toJson() => {'name': name, 'description': description, 'input_schema': inputSchema};
}

class AgentModelConfig {
  const AgentModelConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.maxTokens = 16000,
    this.effort = '',
    this.vision = false,
  });

  /// The provider's Anthropic-protocol address; requests go to `{baseUrl}/v1/messages`.
  final String baseUrl;
  final String apiKey;
  final String model;
  final int maxTokens;
  final String effort;
  final bool vision;

  bool get usable => baseUrl.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;

  factory AgentModelConfig.fromJson(Map<String, dynamic> j) => AgentModelConfig(
        baseUrl: (j['base_url'] as String?) ?? '',
        apiKey: (j['api_key'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        maxTokens: (j['max_tokens'] as num?)?.toInt() ?? 16000,
        effort: (j['effort'] as String?) ?? '',
        vision: j['vision'] == true,
      );

  Map<String, dynamic> toJson() => {
        'base_url': baseUrl,
        'api_key': apiKey,
        'model': model,
        'max_tokens': maxTokens,
        'effort': effort,
        'vision': vision,
      };
}

class LocalAgentSpec {
  const LocalAgentSpec({
    required this.version,
    required this.prompt,
    required this.tools,
    required this.model,
    this.maxRounds = 8,
    this.maxProposePerCall = 5,
    this.maxDraftsPerChat = 30,
    this.maxToolResult = 6000,
    this.wrapUpNudge = '已经查阅了足够多的资料。请不要再调用工具，直接基于已有的信息回答。',
    this.dedupeThreshold = 0.8,
  });

  final String version;

  /// The stable system text.
  final String prompt;
  final List<AgentToolSpec> tools;
  final AgentModelConfig model;
  final int maxRounds;
  final int maxProposePerCall;
  final int maxDraftsPerChat;
  final int maxToolResult;
  final String wrapUpNudge;
  final double dedupeThreshold;

  bool get usable => model.usable && prompt.isNotEmpty && tools.isNotEmpty;

  factory LocalAgentSpec.fromJson(Map<String, dynamic> j) {
    final limits = (j['limits'] as Map?)?.cast<String, dynamic>() ?? const {};
    int n(String k, int d) => (limits[k] as num?)?.toInt() ?? d;
    return LocalAgentSpec(
      version: (j['version'] as String?) ?? '',
      prompt: (j['prompt'] as String?) ?? '',
      tools: [
        for (final t in (j['tools'] as List? ?? const []))
          if (t is Map<String, dynamic>) AgentToolSpec.fromJson(t),
      ],
      model: AgentModelConfig.fromJson((j['model'] as Map?)?.cast<String, dynamic>() ?? const {}),
      maxRounds: n('max_rounds', 8),
      maxProposePerCall: n('max_propose_per_call', 5),
      maxDraftsPerChat: n('max_drafts_per_chat', 30),
      maxToolResult: n('max_tool_result', 6000),
      wrapUpNudge: (limits['wrap_up_nudge'] as String?) ?? '已经查阅了足够多的资料。请不要再调用工具，直接基于已有的信息回答。',
      dedupeThreshold: (j['dedupe_threshold'] as num?)?.toDouble() ?? 0.8,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'prompt': prompt,
        'tools': [for (final t in tools) t.toJson()],
        'model': model.toJson(),
        'limits': {
          'max_rounds': maxRounds,
          'max_propose_per_call': maxProposePerCall,
          'max_drafts_per_chat': maxDraftsPerChat,
          'max_tool_result': maxToolResult,
          'wrap_up_nudge': wrapUpNudge,
        },
        'dedupe_threshold': dedupeThreshold,
      };
}

/// Where the spec lives on this device.
class AgentSpecStore {
  AgentSpecStore(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'agent.spec';

  LocalAgentSpec? get spec {
    final raw = _prefs.getString(_key);
    if (raw == null) return null;
    try {
      final s = LocalAgentSpec.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      return s.usable ? s : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(LocalAgentSpec? s) =>
      s == null ? _prefs.remove(_key) : _prefs.setString(_key, jsonEncode(s.toJson()));
}

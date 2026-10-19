/// One turn of a tool-using conversation with a model over the Anthropic Messages protocol (streaming),
/// the protocol the server's assistant speaks too (server/internal/llm/anthropic/converse.go).
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../agent_models.dart';
import 'agent_spec.dart';
import 'text_filters.dart';

enum BlockKind { text, thinking, toolUse, toolResult }

/// One piece of a message. Only the fields of its [kind] are used.
class LlmBlock {
  const LlmBlock.text(this.text)
      : kind = BlockKind.text,
        signature = '',
        toolUseId = '',
        toolName = '',
        toolInput = const {},
        isError = false;

  const LlmBlock.thinking(this.text, this.signature)
      : kind = BlockKind.thinking,
        toolUseId = '',
        toolName = '',
        toolInput = const {},
        isError = false;

  const LlmBlock.toolUse({required this.toolUseId, required this.toolName, required this.toolInput})
      : kind = BlockKind.toolUse,
        text = '',
        signature = '',
        isError = false;

  const LlmBlock.toolResult({required this.toolUseId, required this.text, this.isError = false})
      : kind = BlockKind.toolResult,
        signature = '',
        toolName = '',
        toolInput = const {};

  final BlockKind kind;

  /// The text, the reasoning, or the tool's output.
  final String text;

  /// Belongs to thinking; it must be sent back unchanged with the block.
  final String signature;
  final String toolUseId;
  final String toolName;
  final Map<String, dynamic> toolInput;
  final bool isError;

  Map<String, dynamic> toJson() => switch (kind) {
        BlockKind.text => {'type': 'text', 'text': text},
        BlockKind.thinking => {'type': 'thinking', 'thinking': text, 'signature': signature},
        BlockKind.toolUse => {'type': 'tool_use', 'id': toolUseId, 'name': toolName, 'input': toolInput},
        BlockKind.toolResult => {
            'type': 'tool_result',
            'tool_use_id': toolUseId,
            'content': text,
            if (isError) 'is_error': true,
          },
      };
}

class LlmMessage {
  const LlmMessage(this.role, this.blocks);
  LlmMessage.text(this.role, String text) : blocks = [LlmBlock.text(text)];

  final String role; // user | assistant
  final List<LlmBlock> blocks;
}

class LlmUsage {
  const LlmUsage({this.input = 0, this.output = 0, this.cached = 0});
  final int input;
  final int output;
  final int cached;
}

/// The model's complete answer for one turn.
class LlmTurn {
  const LlmTurn(this.blocks, this.stopReason, this.usage);
  final List<LlmBlock> blocks;

  /// end_turn | tool_use | max_tokens | refusal
  final String stopReason;
  final LlmUsage usage;

  List<LlmBlock> get toolCalls => [for (final b in blocks) if (b.kind == BlockKind.toolUse) b];
}

abstract class AnthropicChat {
  /// Runs one turn. [onText] gets the text as it is written; cancelling [cancel] aborts the request.
  /// Failures are an [AgentException] whose message is safe to show.
  Future<LlmTurn> converse({
    required AgentModelConfig config,
    required List<String> system,
    required List<LlmMessage> messages,
    required List<AgentToolSpec> tools,
    int maxTokens = 0,
    void Function(String text)? onText,
    CancelToken? cancel,
  });
}

class HttpAnthropicChat implements AnthropicChat {
  HttpAnthropicChat({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              // For a stream: the longest silence between two chunks.
              receiveTimeout: const Duration(seconds: 120),
            ));

  final Dio _dio;

  @override
  Future<LlmTurn> converse({
    required AgentModelConfig config,
    required List<String> system,
    required List<LlmMessage> messages,
    required List<AgentToolSpec> tools,
    int maxTokens = 0,
    void Function(String text)? onText,
    CancelToken? cancel,
  }) async {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final sys = [for (final s in system) if (s.isNotEmpty) s];
    final msgs = [
      for (final m in messages)
        if (m.blocks.isNotEmpty) {'role': m.role, 'content': [for (final b in m.blocks) b.toJson()]},
    ];
    // The second breakpoint goes after the last block: the next call of the same answer (another tool round)
    // and the next question read everything up to here from the cache instead of paying for it again.
    if (msgs.isNotEmpty) {
      final last = (msgs.last['content'] as List).last as Map<String, dynamic>;
      if (last['type'] != 'thinking') last['cache_control'] = {'type': 'ephemeral'};
    }
    final body = {
      'model': config.model,
      'max_tokens': maxTokens > 0 ? maxTokens : config.maxTokens,
      'stream': true,
      // The first block is the stable one: the breakpoint goes after it. Gateways that ignore it still cache by prefix.
      'system': [
        for (var i = 0; i < sys.length; i++)
          {'type': 'text', 'text': sys[i], if (i == 0) 'cache_control': {'type': 'ephemeral'}},
      ],
      if (tools.isNotEmpty) 'tools': [for (final t in tools) t.toApi()],
      'messages': msgs,
      if (config.effort.isNotEmpty) 'output_config': {'effort': config.effort},
    };
    Response<ResponseBody> res;
    try {
      res = await _dio.post<ResponseBody>(
        '$base/v1/messages',
        data: body,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'x-api-key': config.apiKey,
            'anthropic-version': '2023-06-01',
            'Accept': 'text/event-stream',
          },
        ),
        cancelToken: cancel,
      );
    } on DioException catch (e) {
      throw await _translate(e);
    }
    try {
      return await _read(res.data!.stream, onText);
    } on DioException catch (e) {
      throw await _translate(e);
    } on AgentException {
      rethrow;
    } catch (_) {
      throw AgentException('和模型的连接中断了，请重试');
    }
  }

  Future<LlmTurn> _read(Stream<List<int>> body, void Function(String)? onText) async {
    final blocks = <int, _Building>{};
    var stop = '';
    var input = 0, output = 0, cached = 0, created = 0;
    var started = false;
    _Building? current;
    NoiseFilter noise = NoiseFilter();

    void usage(Object? u) {
      if (u is! Map) return;
      int n(String k) => (u[k] as num?)?.toInt() ?? 0;
      // Some gateways report the input counts only at the end, so a later non-zero value wins.
      if (n('input_tokens') > 0) input = n('input_tokens');
      if (n('cache_creation_input_tokens') > 0) created = n('cache_creation_input_tokens');
      if (n('cache_read_input_tokens') > 0) cached = n('cache_read_input_tokens');
      if (n('output_tokens') > 0) output = n('output_tokens');
    }

    await for (final raw in utf8.decoder.bind(body).transform(const LineSplitter())) {
      final line = raw.trim();
      if (!line.startsWith('data:')) continue;
      final Object? j;
      try {
        j = jsonDecode(line.substring(5).trim());
      } catch (_) {
        continue;
      }
      if (j is! Map) continue;
      switch (j['type']) {
        case 'message_start':
          started = true;
          usage((j['message'] as Map?)?['usage']);
        case 'content_block_start':
          final idx = (j['index'] as num?)?.toInt() ?? blocks.length;
          final cb = (j['content_block'] as Map?) ?? const {};
          current = blocks[idx] = _Building(
            type: '${cb['type']}',
            id: '${cb['id'] ?? ''}',
            name: '${cb['name'] ?? ''}',
          );
          noise = NoiseFilter();
        case 'content_block_delta':
          final b = blocks[(j['index'] as num?)?.toInt() ?? -1] ?? current;
          final d = (j['delta'] as Map?) ?? const {};
          if (b == null) break;
          switch (d['type']) {
            case 'text_delta':
              final t = '${d['text'] ?? ''}';
              b.text.write(t);
              final shown = noise.write(t);
              if (shown.isNotEmpty) onText?.call(shown);
            case 'thinking_delta':
              b.text.write('${d['thinking'] ?? ''}');
            case 'signature_delta':
              b.signature.write('${d['signature'] ?? ''}');
            case 'input_json_delta':
              b.json.write('${d['partial_json'] ?? ''}');
          }
        case 'content_block_stop':
          final shown = noise.flush();
          if (shown.isNotEmpty) onText?.call(shown);
          noise = NoiseFilter();
        case 'message_delta':
          final d = (j['delta'] as Map?) ?? const {};
          if (d['stop_reason'] is String) stop = d['stop_reason'] as String;
          usage(j['usage']);
        case 'error':
          final e = j['error'];
          final msg = e is Map ? '${e['message'] ?? ''}' : '$e';
          throw AgentException(msg.isEmpty ? '模型服务出错了' : '模型服务出错了：$msg', code: 'unavailable');
      }
    }
    if (!started) throw AgentException('模型没有返回内容，请检查模型名称，或稍后重试', code: 'unavailable');

    final out = <LlmBlock>[];
    for (final idx in (blocks.keys.toList()..sort())) {
      final b = blocks[idx]!;
      switch (b.type) {
        case 'text':
          final t = stripNoise(b.text.toString());
          if (t.isNotEmpty) out.add(LlmBlock.text(t));
        case 'thinking':
          out.add(LlmBlock.thinking(b.text.toString(), b.signature.toString()));
        case 'tool_use':
          // The arguments of a turn cut off by max_tokens may be incomplete: drop them.
          if (stop == 'max_tokens') continue;
          final raw = b.json.toString().trim();
          Object? input = const <String, dynamic>{};
          if (raw.isNotEmpty) {
            try {
              input = jsonDecode(raw);
            } catch (_) {
              throw AgentException('模型的工具调用参数不合法，请重试', code: 'internal');
            }
          }
          out.add(LlmBlock.toolUse(
            toolUseId: b.id,
            toolName: b.name,
            toolInput: input is Map ? input.cast<String, dynamic>() : const {},
          ));
      }
    }
    return LlmTurn(out, stop, LlmUsage(input: input + created, output: output, cached: cached));
  }

  Future<AgentException> _translate(DioException e) async {
    if (CancelToken.isCancel(e)) return AgentException('已停止');
    final status = e.response?.statusCode;
    if (status != null) {
      final detail = await _errorDetail(e.response!.data);
      final hint = switch (status) {
        401 || 403 => '助手的模型密钥无效或没有权限，请联网同步一次以更新配置',
        404 => '模型地址或模型名不对',
        429 => '模型请求太频繁或额度用完了',
        _ when status >= 500 => '模型服务出错了',
        _ => '模型拒绝了请求',
      };
      return AgentException('$hint（$status）${detail.isEmpty ? '' : '：$detail'}', status: status, code: 'unavailable');
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout || DioExceptionType.connectionError =>
        AgentException('连不上模型服务，请检查网络', code: 'unavailable', unreachable: true),
      DioExceptionType.receiveTimeout || DioExceptionType.sendTimeout => AgentException('模型响应超时', code: 'timeout'),
      _ => AgentException('网络错误：${e.message ?? e.type.name}', code: 'unavailable'),
    };
  }

  Future<String> _errorDetail(Object? data) async {
    try {
      final text = data is ResponseBody ? utf8.decode(await data.stream.expand((c) => c).toList()) : '$data';
      final j = jsonDecode(text);
      final err = j is Map ? j['error'] : null;
      final msg = err is Map ? err['message'] : (err ?? (j is Map ? j['message'] : null));
      final s = '${msg ?? ''}'.trim();
      return s.length > 160 ? '${s.substring(0, 160)}…' : s;
    } catch (_) {
      return '';
    }
  }
}

class _Building {
  _Building({required this.type, required this.id, required this.name});
  final String type;
  final String id;
  final String name;
  final text = StringBuffer();
  final signature = StringBuffer();
  final json = StringBuffer();
}

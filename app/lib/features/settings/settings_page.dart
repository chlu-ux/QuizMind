import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/ai_chat.dart';
import '../../data/ai_prompt.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../home/sync_widgets.dart';
import 'goal_settings.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _url;
  bool _testing = false;
  String? _result;
  bool _resultOk = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _url = TextEditingController(text: s.baseUrl);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final url = normalizeBaseUrl(_url.text);
    if (url.isEmpty) {
      setState(() {
        _result = '请先填写服务器地址';
        _resultOk = false;
      });
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final api = HttpQuizApi(baseUrl: url);
      await api.health();
      final banks = await api.banks();
      setState(() {
        _result = '连接成功，服务器上有 ${banks.length} 个题库';
        _resultOk = true;
      });
    } on ApiException catch (e) {
      setState(() {
        _result = e.message;
        _resultOk = false;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    await ref.read(settingsProvider.notifier).save(baseUrl: _url.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
    ref.read(syncProvider.notifier).run();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final sync = ref.watch(syncProvider);
    final pending = ref.watch(pendingUploadsProvider).value ?? 0;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('服务器', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'http://192.168.1.10:8080',
                  helperText: '手机填 Mac 的局域网 IP；macOS 版可填 http://localhost:8080',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                OutlinedButton(onPressed: _testing ? null : _test, child: Text(_testing ? '测试中…' : '测试连接')),
                const SizedBox(width: 12),
                FilledButton(onPressed: _save, child: const Text('保存并同步')),
              ]),
              if (_result != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_result!, style: TextStyle(color: _resultOk ? Colors.green : theme.colorScheme.error)),
                ),
              const Divider(height: 40),
              const GoalSettingsSection(),
              const Divider(height: 40),
              Text('同步', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('上次同步：${formatLastSync(sync.lastSync)}'),
                subtitle: Text(pending > 0 ? '有 $pending 条作答等待上传' : '没有待上传的作答'),
                trailing: sync.running
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(onPressed: () => ref.read(syncProvider.notifier).run(), child: const Text('立即同步')),
              ),
              if (sync.message != null)
                Text(sync.message!, style: TextStyle(color: sync.isError ? theme.colorScheme.error : null)),
              const Divider(height: 40),
              const AiSettingsSection(),
              const Divider(height: 40),
              Text('本设备', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              SelectableText('设备 ID：${settings.deviceId}', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "AI 解读" settings: the access token for fetching the server's LLM
/// configuration, and a hand-typed configuration for use without a server.
class AiSettingsSection extends ConsumerStatefulWidget {
  const AiSettingsSection({super.key});

  @override
  ConsumerState<AiSettingsSection> createState() => _AiSettingsSectionState();
}

class _AiSettingsSectionState extends ConsumerState<AiSettingsSection> {
  late final TextEditingController _token;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  bool _showToken = false;
  bool _testing = false;
  String? _result;
  bool _resultOk = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(aiSettingsProvider);
    _token = TextEditingController(text: s.token);
    _baseUrl = TextEditingController(text: s.manual?.baseUrl ?? '');
    _apiKey = TextEditingController(text: s.manual?.apiKey ?? '');
    _model = TextEditingController(text: s.manual?.model ?? '');
  }

  @override
  void dispose() {
    _token.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  void _toast(String text) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _saveToken() async {
    await ref.read(aiSettingsProvider.notifier).saveToken(_token.text);
    if (!mounted) return;
    if (!ref.read(settingsProvider).configured) {
      _toast('令牌已保存；填好服务器地址并同步后才能拿到 AI 配置');
      return;
    }
    await ref.read(syncProvider.notifier).run();
    if (!mounted) return;
    final s = ref.read(syncProvider);
    _toast(s.message ?? '已同步');
  }

  AiConfig? _manualFromFields() {
    final c = AiConfig(
      baseUrl: _baseUrl.text.trim().replaceAll(RegExp(r'/+$'), ''),
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
    );
    return c.usable ? c : null;
  }

  Future<void> _saveManual() async {
    final c = _manualFromFields();
    if (c == null) {
      _toast('Base URL、API Key 和模型都要填');
      return;
    }
    await ref.read(aiSettingsProvider.notifier).saveManual(c);
    if (mounted) _toast('已保存，本机配置优先于服务器配置');
  }

  Future<void> _clearManual() async {
    await ref.read(aiSettingsProvider.notifier).saveManual(null);
    _baseUrl.clear();
    _apiKey.clear();
    _model.clear();
    if (mounted) _toast('已清除本机配置');
  }

  Future<void> _test() async {
    // Test what is typed in the fields if complete, else what is in use now.
    final config = _manualFromFields() ?? ref.read(aiSettingsProvider).effective;
    if (config == null) {
      setState(() {
        _result = '还没有可用的配置';
        _resultOk = false;
      });
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final buffer = StringBuffer();
      await for (final p in ref.read(aiChatProvider).stream(
          AiConfig(baseUrl: config.baseUrl, apiKey: config.apiKey, model: config.model, maxTokens: 32),
          const [ChatMessage('user', 'Reply with the single word: pong')])) {
        buffer.write(p);
      }
      setState(() {
        _result = '连接成功，模型回复：${buffer.toString().trim()}';
        _resultOk = true;
      });
    } on AiException catch (e) {
      setState(() {
        _result = e.message;
        _resultOk = false;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ai = ref.watch(aiSettingsProvider);
    final status = ai.usingManual
        ? '当前使用：本机配置（${ai.manual!.model}）'
        : ai.effective != null
            ? '当前使用：服务器同步的配置（${ai.effective!.model}）'
            : '还没有 AI 配置';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('AI 解读', style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(status, style: theme.textTheme.bodyMedium),
      const SizedBox(height: 12),
      TextField(
        controller: _token,
        obscureText: !_showToken,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: '访问令牌',
          helperText: '服务端管理页「AI 解读」里设置的令牌；同步时用它取回 LLM 配置',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showToken = !_showToken),
          ),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(onPressed: _saveToken, child: const Text('保存令牌并同步')),
      const SizedBox(height: 8),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        initiallyExpanded: ai.usingManual,
        title: const Text('本机自定义配置'),
        subtitle: const Text('没连过服务器时用；填了之后优先于服务器配置'),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://api.openai.com/v1',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'API Key', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '模型', hintText: 'gpt-4o-mini', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton(onPressed: _saveManual, child: const Text('保存')),
            OutlinedButton(onPressed: _testing ? null : _test, child: Text(_testing ? '测试中…' : '测试')),
            TextButton(onPressed: ai.manual == null ? null : _clearManual, child: const Text('清除')),
          ]),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_result!, style: TextStyle(color: _resultOk ? Colors.green : theme.colorScheme.error)),
              ),
            ),
        ],
      ),
    ]);
  }
}

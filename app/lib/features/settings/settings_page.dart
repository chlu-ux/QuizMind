import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/api.dart';
import '../home/sync_widgets.dart';

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

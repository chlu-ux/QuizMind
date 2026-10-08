import 'package:flutter/material.dart';

import 'agent_controller.dart';
import 'agent_page.dart';

/// The assistant as a tab of the home screen. It keeps its conversation while the learner looks at
/// other tabs; "new conversation" starts over in place.
class AgentTab extends StatefulWidget {
  const AgentTab({super.key});

  @override
  State<AgentTab> createState() => _AgentTabState();
}

class _AgentTabState extends State<AgentTab> {
  AgentArgs _args = const AgentArgs();

  void _startOver() => setState(() => _args = AgentArgs(fresh: DateTime.now().microsecondsSinceEpoch));

  @override
  Widget build(BuildContext context) =>
      AgentPage(key: ValueKey(_args), args: _args, onNewConversation: _startOver);
}

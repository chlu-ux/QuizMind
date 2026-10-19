/// Filters for the model's streamed text: gateway noise, and links to things the assistant never saw.
library;

/// Removes internal markers some gateways leak into the reply, such as DeepSeek's
/// `<ds_safety>…</ds_safety>` (and the word "Safe" left after the closing tag). Text arrives in arbitrary
/// pieces, so a marker can be split across calls; anything that might be the start of one is held back.
/// Use a new filter per text block. Port of server/internal/llm/converse.go NoiseFilter.
class NoiseFilter {
  String _pending = '';
  String _closing = '';
  bool _trail = false;

  static const _open = '<ds_';
  static const _trailWord = 'Safe';
  static const _maxNoise = 4096;

  String write(String s) {
    _pending += s;
    final out = StringBuffer();
    while (true) {
      if (_closing.isNotEmpty) {
        final i = _pending.indexOf(_closing);
        if (i < 0) {
          if (_pending.length > _maxNoise) {
            out.write(_pending);
            _pending = '';
            _closing = '';
          }
          return out.toString();
        }
        _pending = _pending.substring(i + _closing.length);
        _closing = '';
        _trail = true;
        continue;
      }
      if (_trail) {
        if (_pending.length < _trailWord.length && _trailWord.startsWith(_pending)) return out.toString();
        if (_pending.startsWith(_trailWord)) _pending = _pending.substring(_trailWord.length);
        _trail = false;
      }
      final i = _pending.indexOf(_open);
      if (i < 0) {
        var keep = 0;
        for (var n = (_open.length - 1 < _pending.length ? _open.length - 1 : _pending.length); n > 0; n--) {
          if (_pending.endsWith(_open.substring(0, n))) {
            keep = n;
            break;
          }
        }
        out.write(_pending.substring(0, _pending.length - keep));
        _pending = _pending.substring(_pending.length - keep);
        return out.toString();
      }
      out.write(_pending.substring(0, i));
      _pending = _pending.substring(i);
      final end = _pending.indexOf('>');
      if (end < 0) {
        if (_pending.length > 64) {
          out.write(_pending[0]);
          _pending = _pending.substring(1);
          continue;
        }
        return out.toString();
      }
      final name = _pending.substring(1, end);
      if (!_isNoiseName(name)) {
        out.write(_pending[0]);
        _pending = _pending.substring(1);
        continue;
      }
      _closing = '</$name>';
      _pending = _pending.substring(end + 1);
    }
  }

  /// What was held back once the text has ended. A marker that never closed is dropped.
  String flush() {
    final rest = _pending;
    final closed = _closing.isEmpty;
    _pending = '';
    _closing = '';
    _trail = false;
    return closed ? rest : '';
  }

  static bool _isNoiseName(String name) =>
      name.startsWith('ds_') && name.length > 3 && name.length <= 32 && RegExp(r'^[a-z0-9_]+$').hasMatch(name);
}

String stripNoise(String s) {
  final f = NoiseFilter();
  return f.write(s) + f.flush();
}

/// Checks the `lesson:` and `question:` links of streamed Markdown. A link whose id the assistant never
/// saw (in a tool result or the request's context) is invented, so the link is dropped and its label
/// kept. Text is held back only while it could still be the start of a link.
/// Port of server/internal/agent/linkfilter.go.
class LinkFilter {
  LinkFilter(this.known);

  final bool Function(String id) known;
  String _buf = '';

  static const _maxLink = 400;

  String write(String s) {
    _buf += s;
    final out = StringBuffer();
    while (true) {
      final i = _buf.indexOf('[');
      if (i < 0) {
        out.write(_buf);
        _buf = '';
        return out.toString();
      }
      out.write(_buf.substring(0, i));
      _buf = _buf.substring(i);

      final j = _buf.indexOf(']');
      final nl = _buf.indexOf('\n');
      if (nl >= 0 && (j < 0 || nl < j)) {
        out.write(_buf.substring(0, nl + 1)); // links do not span lines
        _buf = _buf.substring(nl + 1);
        continue;
      }
      if (j < 0) {
        if (_buf.length > _maxLink) {
          out.write(_buf[0]);
          _buf = _buf.substring(1);
          continue;
        }
        return out.toString();
      }
      if (j + 1 == _buf.length) return out.toString(); // wait to see whether "(" follows
      if (_buf[j + 1] != '(') {
        out.write(_buf.substring(0, j + 1));
        _buf = _buf.substring(j + 1);
        continue;
      }
      var k = _buf.indexOf(')', j);
      if (k < 0) {
        if (_buf.length > _maxLink) {
          out.write(_buf.substring(0, j + 1));
          _buf = _buf.substring(j + 1);
          continue;
        }
        return out.toString();
      }
      final label = _buf.substring(1, j), target = _buf.substring(j + 2, k);
      final id = _linkId(target);
      if (id != null && !known(id)) {
        out.write(label);
      } else {
        out.write(_buf.substring(0, k + 1));
      }
      _buf = _buf.substring(k + 1);
    }
  }

  /// What is still held once the text has ended.
  String flush() {
    final rest = _buf;
    _buf = '';
    return rest;
  }

  static String? _linkId(String target) {
    for (final p in const ['lesson:', 'question:']) {
      if (target.startsWith(p)) return target.substring(p.length).trim();
    }
    return null;
  }

  static final _link = RegExp(r'\]\((?:lesson|question):([^)\s]+)\)');

  /// The ids of the lesson: and question: links in [text]. Links in an earlier answer passed the filter
  /// then, so the model may link to them again.
  static Iterable<String> idsIn(String text) => _link.allMatches(text).map((m) => m.group(1)!);
}

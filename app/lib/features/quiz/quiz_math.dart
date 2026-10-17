import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

/// Formulas in Markdown text, written the way models and textbooks write LaTeX: `$x^2$` and `\(x^2\)`
/// in a line, `$$ ... $$` and `\[ ... \]` on their own. A formula that is still being written (not
/// closed yet) stays ordinary text until it is complete.
///
/// `$` also means dollars, so an inline `$…$` formula must not start or end with a space and must not
/// be followed by a digit: "$5 到 $10" is money.
final _inlineMath = RegExp(
  r'\\\(([\s\S]+?)\\\)' // \( ... \)
  r'|\\\[([\s\S]+?)\\\]' // \[ ... \]
  r'|\$\$([\s\S]+?)\$\$' // $$ ... $$
  r'|\$(?!\s)((?:\\.|[^$\\\n])+?)(?<!\s)\$(?!\d)', // $ ... $
);

/// The Markdown element a formula becomes; `display` says whether it stands on its own line.
const mathTag = 'math';

class MathInlineSyntax extends md.InlineSyntax {
  MathInlineSyntax() : super(_inlineMath.pattern);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final display = match[2] != null || match[3] != null;
    final tex = (match[1] ?? match[2] ?? match[3] ?? match[4] ?? '').trim();
    if (tex.isEmpty) return false;
    parser.addNode(
      md.Element.text(mathTag, tex)
        ..attributes['display'] = display ? 'true' : 'false',
    );
    return true;
  }
}

/// A formula that has the lines to itself: `$$` or `\[` opens it, `$$` or `\]` closes it, on the same
/// line or a later one (but before the next blank line).
class MathBlockSyntax extends md.BlockSyntax {
  const MathBlockSyntax();

  @override
  RegExp get pattern => RegExp(r'^ {0,3}(?:\$\$|\\\[)');

  /// The formula starting at the parser's line, and how many lines it takes; null if it is not
  /// complete (or has other text after the closing).
  (String, int)? _read(md.BlockParser parser) {
    final first = parser.current.content.trimLeft();
    final dollars = first.startsWith(r'$$');
    final open = dollars ? r'$$' : r'\[';
    final close = dollars ? r'$$' : r'\]';
    var line = first.substring(open.length);
    final body = StringBuffer();
    for (var n = 1; ; n++) {
      final at = line.indexOf(close);
      if (at >= 0) {
        if (line.substring(at + close.length).trim().isNotEmpty) return null;
        body.write(line.substring(0, at));
        final tex = body.toString().trim();
        return tex.isEmpty ? null : (tex, n);
      }
      body.writeln(line);
      final next = parser.peek(n);
      if (next == null || next.content.trim().isEmpty) return null;
      line = next.content;
    }
  }

  @override
  bool canParse(md.BlockParser parser) =>
      pattern.hasMatch(parser.current.content) && _read(parser) != null;

  @override
  md.Node? parse(md.BlockParser parser) {
    final (tex, lines) = _read(parser)!;
    for (var i = 0; i < lines; i++) {
      parser.advance();
    }
    return md.Element('p', [
      md.Element.text(mathTag, tex)..attributes['display'] = 'true',
    ]);
  }
}

/// Draws a formula. One that does not parse is shown as its source instead of an error.
class MathBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final tex = element.textContent;
    final display = element.attributes['display'] == 'true';
    final style = DefaultTextStyle.of(context).style
        .merge(parentStyle)
        .merge(preferredStyle);
    Widget fallback(Object _) => Text(
      display ? tex : '\$$tex\$',
      style: style.copyWith(fontFamily: 'monospace'),
    );
    if (display) {
      return SingleChildScrollView(
        key: const ValueKey('math-display'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Math.tex(
          tex,
          mathStyle: MathStyle.display,
          textStyle: style,
          onErrorFallback: (e) => fallback(e),
        ),
      );
    }
    // A text widget, so that it joins the words around it instead of standing apart.
    return Text.rich(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Math.tex(
          tex,
          mathStyle: MathStyle.text,
          textStyle: style,
          onErrorFallback: (e) => fallback(e),
        ),
      ),
    );
  }
}

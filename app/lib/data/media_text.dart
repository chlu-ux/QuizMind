/// Pictures inside question text. A stem, option or explanation refers to an uploaded picture as
/// `![alt](media:<id>)`; the server hands the bytes out at `/api/v1/media/<id>`.
final _image = RegExp(r'!\[([^\]]*)\]\(media:([0-9a-f]{24})\)');

/// Question text with each picture replaced by a short placeholder, for lists and search.
String plainText(String text) => text.replaceAllMapped(_image, (m) {
  final alt = m[1]!.trim();
  return alt.isEmpty ? '[图]' : '[图：$alt]';
});

/// The ids of the pictures [texts] refer to.
Set<String> mediaIds(Iterable<String> texts) => {
  for (final t in texts)
    for (final m in _image.allMatches(t)) m[2]!,
};

/// Question text for a model: each picture becomes `[图N]`, N being its place in [order].
String numberPictures(String text, List<String> order) =>
    text.replaceAllMapped(_image, (m) => '[图${order.indexOf(m[2]!) + 1}]');

sealed class TextPart {
  const TextPart();
}

class PlainPart extends TextPart {
  const PlainPart(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is PlainPart && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

class PicturePart extends TextPart {
  const PicturePart(this.id, this.alt);

  final String id;
  final String alt;

  @override
  bool operator ==(Object other) => other is PicturePart && other.id == id && other.alt == alt;

  @override
  int get hashCode => Object.hash(id, alt);
}

/// Splits an option into text and pictures. Options are shown as plain text (they may hold `*p++` or
/// `<T>`, which Markdown would mangle), so only the picture syntax is interpreted.
List<TextPart> splitPictures(String text) {
  final out = <TextPart>[];
  var last = 0;
  for (final m in _image.allMatches(text)) {
    if (m.start > last) out.add(PlainPart(text.substring(last, m.start)));
    out.add(PicturePart(m[2]!, m[1]!));
    last = m.end;
  }
  if (last < text.length) out.add(PlainPart(text.substring(last)));
  return out;
}

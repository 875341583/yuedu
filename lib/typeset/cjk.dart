/// CJK排版规则：标点挤压、避头尾、中西文间距
library;

/// 判断一个字符是否属于CJK字符
bool isCjk(String ch) {
  if (ch.isEmpty) return false;
  final code = ch.codeUnitAt(0);
  return (code >= 0x4E00 && code <= 0x9FFF) || // CJK Unified Ideographs
      (code >= 0x3400 && code <= 0x4DBF) || // CJK Extension A
      (code >= 0xF900 && code <= 0xFAFF) || // CJK Compatibility
      (code >= 0x2E80 && code <= 0x2EFF) || // CJK Radicals
      (code >= 0x3000 && code <= 0x303F) || // CJK Symbols and Punctuation
      (code >= 0xFF00 && code <= 0xFFEF) || // Fullwidth Forms
      (code >= 0x3040 && code <= 0x309F) || // Hiragana
      (code >= 0x30A0 && code <= 0x30FF) || // Katakana
      (code >= 0xAC00 && code <= 0xD7AF); // Korean Syllables
}

/// 判断是否为CJK标点
bool isCjkPunctuation(String ch) {
  const punctuations = {
    '，', '。', '、', '：', '；', '！', '？',
    '（', '）', '「', '」', '『', '』', '【', '】',
    '《', '》', '〈', '〉', '─', '—', '…', '·', '～',
  };
  if (punctuations.contains(ch)) return true;
  final code = ch.codeUnitAt(0);
  return (code >= 0x3000 && code <= 0x303F) ||
      (code >= 0xFF01 && code <= 0xFF5E);
}

/// 行首禁则字符（不应出现在行首）
bool isHeadForbidden(String ch) {
  const forbidden = {
    '，', '。', '、', '：', '；', '！', '？',
    '）', '」', '』', '】', '》', '〉',
    '—', '…', '～',
    '.', ',', ':', ';', '!', '?', ')',
  };
  if (forbidden.contains(ch)) return true;
  // 全角标点也禁则
  final code = ch.codeUnitAt(0);
  return (code >= 0xFF01 && code <= 0xFF0F) ||
      (code >= 0xFF1A && code <= 0xFF20) ||
      (code >= 0xFF3B && code <= 0xFF40) ||
      (code >= 0xFF5B && code <= 0xFF5E);
}

/// 行尾禁则字符（不应出现在行尾）
bool isTailForbidden(String ch) {
  const forbidden = {
    '（', '「', '『', '【', '《', '〈',
    '(', '[', '{', '<',
  };
  return forbidden.contains(ch);
}

/// 判断是否为CJK字母（不含标点）
bool isCjkLetter(String ch) {
  return isCjk(ch) && !isCjkPunctuation(ch);
}

/// 判断是否为拉丁字母/数字
bool isLatinChar(String ch) {
  return RegExp(r'^[a-zA-Z0-9_]$').hasMatch(ch);
}

/// 判断是否为可压缩标点（行首/行尾/连续标点时可压缩为半角宽度）
bool isCompressible(String ch) {
  const compressible = {
    '，', '。', '、', '：', '；', '！', '？',
    '）', '」', '』', '】', '》', '〉',
    '（', '「', '『', '【', '《', '〈',
  };
  return compressible.contains(ch);
}

/// 判断一个字符是否可以出现在行首
bool canBeLineHead(String ch) => !isHeadForbidden(ch);

/// 判断一个字符是否可以出现在行尾
bool canBeLineTail(String ch) => !isTailForbidden(ch);

/// 排版段类型
enum SegmentKind {
  /// 普通字符
  character,

  /// 中西文间距（1/4 em）
  cjkLatinSpacing,

  /// 换行符（强制换行）
  lineBreak,
}

/// 排版段
class Segment {
  final SegmentKind kind;
  final String char_;
  final double widthEm; // 以em为单位

  const Segment.char(this.char_, this.widthEm)
      : kind = SegmentKind.character;
  const Segment.cjkLatinSpacing()
      : kind = SegmentKind.cjkLatinSpacing,
        char_ = '',
        widthEm = 0.25;
  const Segment.lineBreak()
      : kind = SegmentKind.lineBreak,
        char_ = '\n',
        widthEm = 0;

  /// 是否为连续换行（段落分隔）
  bool get isParagraphBreak => kind == SegmentKind.lineBreak;

  @override
  String toString() {
    if (kind == SegmentKind.cjkLatinSpacing) return 'Segment(CjkLatinSpacing)';
    return 'Segment("$char_", ${widthEm}em)';
  }
}

/// 在中文与西文之间插入间距段
List<Segment> insertCjkLatinSpacing(List<String> chars) {
  final segments = <Segment>[];
  for (var i = 0; i < chars.length; i++) {
    final ch = chars[i];
    if (i > 0) {
      final prev = chars[i - 1];
      final prevCjk = isCjkLetter(prev);
      final curLatin = isLatinChar(ch);
      final curCjk = isCjkLetter(ch);
      final prevLatin = isLatinChar(prev);

      if ((prevCjk && curLatin) || (prevLatin && curCjk)) {
        segments.add(Segment.cjkLatinSpacing());
      }
    }
    // 换行符特殊处理
    if (ch == '\n') {
      segments.add(const Segment.lineBreak());
    } else {
      final widthEm = isCjk(ch) ? 1.0 : 0.5;
      segments.add(Segment.char(ch, widthEm));
    }
  }
  return segments;
}

/// 对一行内的标点进行挤压处理
List<Segment> squeezePunctuation(List<Segment> line) {
  if (line.isEmpty) return line;

  final result = List<Segment>.from(line);
  final len = result.length;

  // 行首标点半角化
  if (len > 0 && result[0].kind == SegmentKind.character) {
    if (isCompressible(result[0].char_)) {
      result[0] = Segment.char(result[0].char_, 0.5);
    }
  }

  // 行尾标点半角化
  if (len > 1 && result[len - 1].kind == SegmentKind.character) {
    if (isCompressible(result[len - 1].char_)) {
      result[len - 1] = Segment.char(result[len - 1].char_, 0.5);
    }
  }

  // 连续标点挤压
  for (var i = 1; i < len; i++) {
    if (result[i - 1].kind == SegmentKind.character &&
        result[i].kind == SegmentKind.character) {
      if (isCompressible(result[i - 1].char_) &&
          isCompressible(result[i].char_)) {
        result[i] = Segment.char(result[i].char_, 0.5);
      }
    }
  }

  return result;
}

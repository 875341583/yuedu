//! CJK排版规则：标点挤压、避头尾、中西文间距

/// 判断一个字符是否属于CJK统一汉字/ CJK标点范围
pub fn is_cjk(ch: char) -> bool {
    matches!(ch,
        '\u{4E00}'..='\u{9FFF}'   |  // CJK Unified Ideographs
        '\u{3400}'..='\u{4DBF}'   |  // CJK Unified Ideographs Extension A
        '\u{F900}'..='\u{FAFF}'   |  // CJK Compatibility Ideographs
        '\u{2E80}'..='\u{2EFF}'   |  // CJK Radicals Supplement
        '\u{3000}'..='\u{303F}'   |  // CJK Symbols and Punctuation
        '\u{FF00}'..='\u{FFEF}'   |  // Halfwidth and Fullwidth Forms
        '\u{3040}'..='\u{309F}'   |  // Hiragana
        '\u{30A0}'..='\u{30FF}'   |  // Katakana
        '\u{AC00}'..='\u{D7AF}'      // Korean Syllables
    )
}

/// 行首禁则字符（这些字符不应出现在行首）
fn is_head_forbidden(ch: char) -> bool {
    matches!(ch,
        '，' | '。' | '、' | '：' | '；' | '！' | '？' |
        '）' | '」' | '』' | '】' | '》' |
        '.' | ',' | ':' | ';' | '!' | '?' | ')' |
        '—' | '…' | '～' |
        '\u{FF01}'..='\u{FF0F}' |  // 全角标点
        '\u{FF1A}'..='\u{FF20}' |
        '\u{FF3B}'..='\u{FF40}' |
        '\u{FF5B}'..='\u{FF5E}'
    )
}

/// 行尾禁则字符（这些字符不应出现在行尾）
fn is_tail_forbidden(ch: char) -> bool {
    matches!(ch,
        '（' | '「' | '『' | '【' | '《' | '〈' |
        '(' | '[' | '{' | '<'
    )
}

/// 判断是否为CJK标点（用于标点挤压判断）
pub fn is_cjk_punctuation(ch: char) -> bool {
    matches!(ch,
        '，' | '。' | '、' | '：' | '；' | '！' | '？' |
        '（' | '）' | '「' | '」' | '『' | '』' | '【' | '】' |
        '《' | '》' | '〈' | '〉' |
        '─' | '—' | '…' | '·' | '～' |
        '\u{3000}'..='\u{303F}' |
        '\u{FF01}'..='\u{FF5E}'
    )
}

/// 判断是否为可半角化的标点（行首/行尾/连续标点时可压缩为半角宽度）
fn is_compressible(ch: char) -> bool {
    matches!(ch,
        '，' | '。' | '、' | '：' | '；' | '！' | '？' |
        '）' | '」' | '』' | '】' | '》' | '〉' |
        '（' | '「' | '『' | '【' | '《' | '〈'
    )
}

/// 排版段类型
#[derive(Debug, Clone, PartialEq)]
pub enum SegmentKind {
    /// 普通字符
    Char(char),
    /// 中西文间距（1/4 em）
    CjkLatinSpacing,
    /// 换行符（强制换行，段落分隔）
    LineBreak,
}

/// 排版段
#[derive(Debug, Clone)]
pub struct Segment {
    pub kind: SegmentKind,
    /// 该段的宽度（以em为单位，1.0=全角宽度）
    pub width_em: f64,
}

/// 在中文字符与西文字符之间插入间距段
pub fn insert_cjk_latin_spacing(chars: &[char]) -> Vec<Segment> {
    let mut segments = Vec::new();
    for (i, &ch) in chars.iter().enumerate() {
        // 换行符特殊处理：直接转为LineBreak段
        if ch == '\n' {
            segments.push(Segment {
                kind: SegmentKind::LineBreak,
                width_em: 0.0,
            });
            continue;
        }

        if i > 0 {
            let prev = chars[i - 1];
            // 跳过换行符的中西文间距判断
            if prev != '\n' {
                let prev_is_cjk = is_cjk_letter(prev);
                let cur_is_latin = is_latin_char(ch);
                let cur_is_cjk = is_cjk_letter(ch);
                let prev_is_latin = is_latin_char(prev);

                if (prev_is_cjk && cur_is_latin) || (prev_is_latin && cur_is_cjk) {
                    segments.push(Segment {
                        kind: SegmentKind::CjkLatinSpacing,
                        width_em: 0.25,
                    });
                }
            }
        }
        let width_em = if is_cjk(ch) { 1.0 } else if ch.is_ascii() { 0.5 } else { 0.5 };
        segments.push(Segment {
            kind: SegmentKind::Char(ch),
            width_em,
        });
    }
    segments
}

/// 判断是否为CJK字母（不含标点）
fn is_cjk_letter(ch: char) -> bool {
    is_cjk(ch) && !is_cjk_punctuation(ch)
}

/// 判断是否为拉丁字母/数字
fn is_latin_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_'
}

/// 对一行内的标点进行挤压处理
///
/// 返回调整后的段列表
pub fn squeeze_punctuation(line: &[Segment], _line_idx: usize, _total_lines: usize) -> Vec<Segment> {
    let mut result = line.to_vec();
    let len = result.len();

    if len == 0 {
        return result;
    }

    // 行首标点半角化
    if let Some(seg) = result.first_mut() {
        if let SegmentKind::Char(ch) = seg.kind {
            if is_compressible(ch) {
                seg.width_em = 0.5; // 压缩为半角
            }
        }
    }

    // 行尾标点半角化
    if let Some(seg) = result.last_mut() {
        if let SegmentKind::Char(ch) = seg.kind {
            if is_compressible(ch) {
                seg.width_em = 0.5; // 压缩为半角
            }
        }
    }

    // 连续标点挤压：相邻的两个可压缩标点，第二个压缩
    for i in 1..len {
        if let (SegmentKind::Char(prev_ch), SegmentKind::Char(cur_ch)) =
            (&result[i - 1].kind, &result[i].kind)
        {
            if is_compressible(*prev_ch) && is_compressible(*cur_ch) {
                result[i].width_em = 0.5;
            }
        }
    }

    result
}

/// 判断一个字符是否可以出现在行首（避头尾规则）
pub fn can_be_line_head(ch: char) -> bool {
    !is_head_forbidden(ch)
}

/// 判断一个字符是否可以出现在行尾（避头尾规则）
pub fn can_be_line_tail(ch: char) -> bool {
    !is_tail_forbidden(ch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_cjk() {
        assert!(is_cjk('你'));
        assert!(is_cjk('，'));
        assert!(!is_cjk('A'));
        assert!(!is_cjk('1'));
    }

    #[test]
    fn test_head_forbidden() {
        assert!(!can_be_line_head('，'));
        assert!(!can_be_line_head('。'));
        assert!(can_be_line_head('你'));
        assert!(can_be_line_head('A'));
    }

    #[test]
    fn test_tail_forbidden() {
        assert!(!can_be_line_tail('（'));
        assert!(can_be_line_tail('）'));
        assert!(can_be_line_tail('你'));
    }

    #[test]
    fn test_cjk_latin_spacing() {
        let chars: Vec<char> = "读abc书".chars().collect();
        let segments = insert_cjk_latin_spacing(&chars);
        // 期望：读 + spacing + a + b + c + spacing + 书
        assert_eq!(segments.len(), 7);
        assert!(matches!(segments[1].kind, SegmentKind::CjkLatinSpacing));
        assert!(matches!(segments[5].kind, SegmentKind::CjkLatinSpacing));
    }

    #[test]
    fn test_squeeze_line_start() {
        let line = vec![
            Segment { kind: SegmentKind::Char('，'), width_em: 1.0 },
            Segment { kind: SegmentKind::Char('你'), width_em: 1.0 },
        ];
        let result = squeeze_punctuation(&line, 0, 2);
        assert_eq!(result[0].width_em, 0.5); // 行首逗号被压缩
    }
}

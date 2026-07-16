//! 行分割模块：按容器宽度将段落拆分为行
//!
//! 实现避头尾规则的行分割算法

use crate::TypesetConfig;
use super::cjk::{Segment, SegmentKind, can_be_line_head, can_be_line_tail};

/// 将排版段列表分割为多行
///
/// 核心逻辑：
/// 1. 逐段累加宽度，直到超过容器宽度
/// 2. 找到换行点时，应用避头尾规则
/// 3. 行首禁则字符回退到上一行
/// 4. 行尾禁则字符提前换行
/// 5. 遇到LineBreak段时强制换行，并插入空行作为段落标记
pub fn break_lines(segments: &[Segment], config: &TypesetConfig) -> Vec<Vec<Segment>> {
    if segments.is_empty() {
        return vec![];
    }

    let max_width = config.container_width;
    let mut lines: Vec<Vec<Segment>> = vec![];
    let mut current_line: Vec<Segment> = vec![];
    let mut current_width: f64 = 0.0;

    let mut i = 0;
    while i < segments.len() {
        let seg = &segments[i];

        // 换行符：强制结束当前行
        if seg.kind == SegmentKind::LineBreak {
            // 先保存当前行（如果有内容）
            if !current_line.is_empty() {
                lines.push(current_line);
                current_line = vec![];
                current_width = 0.0;
            }
            // 插入空行作为段落标记（用于后续引擎计算段落间距）
            lines.push(vec![]);
            i += 1;
            continue;
        }

        // 精确度量：字符用 ab_glyph 真实宽度，中西文间距用固定 1/4 em
        let width = match &seg.kind {
            SegmentKind::Char(ch) => crate::measure_char_width(*ch, config),
            SegmentKind::CjkLatinSpacing => config.font_size * 0.25,
            SegmentKind::LineBreak => 0.0,
        };

        if current_width + width > max_width && !current_line.is_empty() {
            // 超出容器宽度，需要换行
            // 应用避头尾规则
            let break_result = apply_kinsoku(&segments[i..], current_line, current_width, max_width, config);

            lines.push(break_result.current_line);
            current_line = vec![];
            current_width = 0.0;
            i += break_result.next_index;
            continue;
        }

        current_width += width;
        current_line.push(seg.clone());
        i += 1;
    }

    if !current_line.is_empty() {
        lines.push(current_line);
    }

    lines
}

/// 应用避头尾规则后的换行结果
struct BreakResult {
    /// 上一行（已完成）
    current_line: Vec<Segment>,
    /// 下一段开始索引（相对于原始segments偏移）
    next_index: usize,
}

/// 应用避头尾规则
fn apply_kinsoku(
    remaining: &[Segment],
    mut current_line: Vec<Segment>,
    mut current_width: f64,
    _max_width: f64,
    config: &TypesetConfig,
) -> BreakResult {
    let em = config.font_size;

    // 检查下一个字符是否为行首禁则
    if let Some(next_seg) = remaining.first() {
        if let SegmentKind::Char(ch) = next_seg.kind {
            if !can_be_line_head(ch) {
                // 行首禁则：将当前行最后一个字符移到下一行
                // 或者将禁则字符保留在上一行
                // 简化实现：将禁则字符附加到上一行
                let seg_width = next_seg.width_em * em;
                current_width += seg_width;
                current_line.push(next_seg.clone());
                return BreakResult {
                    current_line,
                    next_index: 1, // 跳过已处理的段
                };
            }
        }
    }

    // 检查当前行最后一个字符是否为行尾禁则
    if let Some(last_seg) = current_line.last() {
        if let SegmentKind::Char(ch) = last_seg.kind {
            if !can_be_line_tail(ch) {
                // 行尾禁则：将最后字符移到下一行
                let _removed = current_line.pop().unwrap();
                return BreakResult {
                    current_line,
                    next_index: 0, // 被移除的字符将在下一行开头处理
                };
            }
        }
    }

    BreakResult {
        current_line,
        next_index: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_break_single_line() {
        let segments = vec![
            Segment { kind: SegmentKind::Char('你'), width_em: 1.0 },
            Segment { kind: SegmentKind::Char('好'), width_em: 1.0 },
        ];
        let config = TypesetConfig {
            container_width: 100.0,
            font_size: 16.0,
            line_height_ratio: 1.5,
        };
        let lines = break_lines(&segments, &config);
        assert_eq!(lines.len(), 1);
    }

    #[test]
    fn test_break_multiple_lines() {
        let segments: Vec<Segment> = "你好世界测试"
            .chars()
            .map(|ch| Segment {
                kind: SegmentKind::Char(ch),
                width_em: if super::super::cjk::is_cjk(ch) { 1.0 } else { 0.5 },
            })
            .collect();

        let config = TypesetConfig {
            container_width: 50.0, // 极窄，每行约3个CJK字符
            font_size: 16.0,
            line_height_ratio: 1.5,
        };
        let lines = break_lines(&segments, &config);
        assert!(lines.len() > 1, "应产生多行: {:?}", lines);
    }

    #[test]
    fn test_kinsoku_head() {
        // 逗号不应出现在行首
        let segments = vec![
            Segment { kind: SegmentKind::Char('你'), width_em: 1.0 },
            Segment { kind: SegmentKind::Char('好'), width_em: 1.0 },
            Segment { kind: SegmentKind::Char('，'), width_em: 1.0 },
            Segment { kind: SegmentKind::Char('世'), width_em: 1.0 },
            Segment { kind: SegmentKind::Char('界'), width_em: 1.0 },
        ];

        let config = TypesetConfig {
            container_width: 50.0,
            font_size: 16.0,
            line_height_ratio: 1.5,
        };
        let lines = break_lines(&segments, &config);

        // 验证没有行以，开头
        for line in &lines {
            if let Some(SegmentKind::Char(ch)) = line.first().map(|s| &s.kind) {
                assert!(can_be_line_head(*ch), "行首不应是禁则字符: {}", ch);
            }
        }
    }
}

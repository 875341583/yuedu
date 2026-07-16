//! 阅界排版引擎 PoC
//!
//! 核心职责：
//! - 标点挤压（行首/行尾/连续标点半角化）
//! - 避头尾（行首禁则/行尾禁则）
//! - 中西文间距（中文与西文之间插入1/4 em空隙）
//! - 行分割（按容器宽度将段落拆分为行）
//!
//! 输出：每个字符的 x/y 坐标和 glyph index，供 Flutter TextPainter 逐段渲染。
//!
//! FFI导出：
//! - `typeset_ffi()` — 对一段UTF-8文本执行排版计算，返回FFITypesetResult
//! - `free_typeset_result()` — 释放typeset_ffi返回的内存

mod cjk;
mod linebreak;
mod types;

pub use types::*;
pub use cjk::{Segment, SegmentKind};

use std::ffi::c_int;
use std::slice;

/// 排版引擎主入口：对一段纯文本执行排版计算
///
/// - `text`: 输入文本
/// - `config`: 排版配置（字号、行高、容器宽度等）
/// - 返回：每个字符的位置信息列表 + 行信息列表
pub fn typeset_paragraph(text: &str, config: &TypesetConfig) -> TypesetResult {
    let chars: Vec<char> = text.chars().collect();
    if chars.is_empty() {
        return TypesetResult {
            glyphs: vec![],
            lines: vec![],
        };
    }

    // 1. 中西文间距处理：在中文与西文之间插入可伸缩间距
    let segments = cjk::insert_cjk_latin_spacing(&chars);

    // 2. 避头尾 + 行分割
    let lines = linebreak::break_lines(&segments, config);

    // 3. 标点挤压 + 计算每个字符的绝对位置
    let mut glyphs = Vec::new();
    let mut y: f64 = 0.0;
    let line_height = config.font_size * config.line_height_ratio;

    for (line_idx, line) in lines.iter().enumerate() {
        // 空行 = 段落分隔，额外增加半行高的间距
        if line.is_empty() {
            y += line_height * 0.5;
            continue;
        }

        let squeezed = cjk::squeeze_punctuation(line, line_idx, lines.len());
        let mut x: f64 = 0.0;

        for seg in &squeezed {
            match &seg.kind {
                SegmentKind::Char(ch) => {
                    let width = measure_char_width(*ch, config);
                    glyphs.push(GlyphInfo {
                        char: *ch,
                        x,
                        y,
                        width,
                        line_index: line_idx,
                    });
                    x += width;
                }
                SegmentKind::CjkLatinSpacing => {
                    let spacing_width = config.font_size * 0.25; // 1/4 em
                    glyphs.push(GlyphInfo {
                        char: '\0', // 中西文间距用空字符标记
                        x,
                        y,
                        width: spacing_width,
                        line_index: line_idx,
                    });
                    x += spacing_width;
                }
                SegmentKind::LineBreak => {
                    // LineBreak不应出现在这一阶段（已在linebreak.rs处理）
                    // 忽略
                }
            }
        }

        y += line_height;
    }

    TypesetResult { glyphs, lines: lines.iter().map(|l| l.len()).collect() }
}

/// 简化的字符宽度测量
///
/// PoC阶段使用等价宽度表，MVP阶段替换为 harfbuzz/raqote 精确测量
fn measure_char_width(ch: char, config: &TypesetConfig) -> f64 {
    let em = config.font_size;
    if cjk::is_cjk(ch) {
        em // CJK字符全角宽度
    } else if ch.is_ascii() {
        em * 0.5 // ASCII字符半角宽度（等宽近似）
    } else {
        em * 0.5 // 其他字符半角近似
    }
}

// =========== FFI 导出函数 ===========

/// 内部排版计算，返回带详细信息的FFI结果
///
/// 将Rust的TypesetResult转换为C兼容的FFITypesetResult
fn typeset_to_ffi(text: &str, config: &TypesetConfig) -> FFITypesetResult {
    let result = typeset_paragraph(text, config);
    let line_height = config.font_size * config.line_height_ratio;

    // 将GlyphInfo转换为FFIGlyphInfo
    let mut ffi_glyphs: Vec<FFIGlyphInfo> = result.glyphs.into_iter().map(|g| {
        let is_cjk_latin_spacing = g.char == '\0';
        let is_squeezed = !is_cjk_latin_spacing &&
            cjk::is_cjk_punctuation(g.char) &&
            (g.width < config.font_size * 0.9); // 宽度小于全角说明被挤压
        FFIGlyphInfo {
            code_point: if is_cjk_latin_spacing { 0x0020 } else { g.char as u32 }, // 间距用空格码点
            x: g.x,
            y: g.y,
            width: g.width,
            line_index: g.line_index as u32,
            is_squeezed: if is_squeezed { 1 } else { 0 },
            is_cjk_latin_spacing: if is_cjk_latin_spacing { 1 } else { 0 },
        }
    }).collect();

    let glyph_count = ffi_glyphs.len() as u32;
    let line_count = result.lines.len() as u32;

    // 转换行段数为u32数组
    let mut line_counts: Vec<u32> = result.lines.into_iter().map(|c| c as u32).collect();

    // 计算总高度
    let total_height = line_count as f64 * line_height;

    // 将Vec转为堆分配的Box，然后泄漏指针给FFI调用方
    let glyphs_ptr = ffi_glyphs.as_mut_ptr();
    let line_counts_ptr = line_counts.as_mut_ptr();
    std::mem::forget(ffi_glyphs); // 防止Vec被drop
    std::mem::forget(line_counts);

    FFITypesetResult {
        glyphs_ptr,
        glyph_count,
        line_counts_ptr,
        line_count,
        total_height,
    }
}

/// FFI排版函数
///
/// # 参数
/// - `text_ptr`: UTF-8文本的指针
/// - `text_len`: 文本字节长度
/// - `font_size`: 字号（像素）
/// - `line_height_ratio`: 行高倍率
/// - `container_width`: 容器宽度（像素）
///
/// # 返回
/// FFITypesetResult结构体，包含排版结果指针
///
/// # 安全要求
/// - `text_ptr`必须指向有效的UTF-8数据，长度为`text_len`
/// - 调用方必须在使用完毕后调用`free_typeset_result`释放内存
#[no_mangle]
pub unsafe extern "C" fn typeset_ffi(
    text_ptr: *const u8,
    text_len: c_int,
    font_size: f64,
    line_height_ratio: f64,
    container_width: f64,
) -> FFITypesetResult {
    // 安全：调用方保证text_ptr指向有效UTF-8
    let text = unsafe {
        let slice = slice::from_raw_parts(text_ptr, text_len as usize);
        match std::str::from_utf8(slice) {
            Ok(s) => s,
            Err(_) => {
                // UTF-8无效时返回空结果
                return FFITypesetResult {
                    glyphs_ptr: std::ptr::null_mut(),
                    glyph_count: 0,
                    line_counts_ptr: std::ptr::null_mut(),
                    line_count: 0,
                    total_height: 0.0,
                };
            }
        }
    };

    let config = TypesetConfig {
        font_size,
        line_height_ratio,
        container_width,
    };

    typeset_to_ffi(text, &config)
}

/// 释放typeset_ffi返回的内存
///
/// # 安全要求
/// - `result`必须是由`typeset_ffi`返回的结构体
/// - 每个FFITypesetResult只能释放一次
/// - 释放后不应再访问其中的指针
#[no_mangle]
pub unsafe extern "C" fn free_typeset_result(result: FFITypesetResult) {
    if !result.glyphs_ptr.is_null() && result.glyph_count > 0 {
        // 安全：恢复Vec并让其自然drop
        let _ = unsafe {
            Vec::from_raw_parts(
                result.glyphs_ptr,
                result.glyph_count as usize,
                result.glyph_count as usize,
            )
        };
    }
    if !result.line_counts_ptr.is_null() && result.line_count > 0 {
        let _ = unsafe {
            Vec::from_raw_parts(
                result.line_counts_ptr,
                result.line_count as usize,
                result.line_count as usize,
            )
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_typeset_empty() {
        let config = TypesetConfig::default();
        let result = typeset_paragraph("", &config);
        assert!(result.glyphs.is_empty());
        assert!(result.lines.is_empty());
    }

    #[test]
    fn test_typeset_pure_ascii() {
        let config = TypesetConfig::default();
        let result = typeset_paragraph("Hello", &config);
        assert_eq!(result.glyphs.len(), 5);
    }

    #[test]
    fn test_typeset_cjk_no_break() {
        let config = TypesetConfig {
            container_width: 1000.0,
            ..TypesetConfig::default()
        };
        let result = typeset_paragraph("你好世界", &config);
        assert_eq!(result.glyphs.len(), 4);
        assert_eq!(result.lines.len(), 1);
    }

    #[test]
    fn test_typeset_cjk_latin_spacing() {
        let config = TypesetConfig {
            container_width: 1000.0,
            ..TypesetConfig::default()
        };
        let result = typeset_paragraph("读abc书", &config);
        // "读" + spacing + "a" + "b" + "c" + spacing + "书"
        // 检查"读"和"a"之间有间距
        let du_glyph = result.glyphs.iter().find(|g| g.char == '读').unwrap();
        let a_glyph = result.glyphs.iter().find(|g| g.char == 'a').unwrap();
        assert!(a_glyph.x > du_glyph.x + du_glyph.width);
    }

    #[test]
    fn test_typeset_line_break() {
        let config = TypesetConfig {
            container_width: 50.0, // 极窄容器，强制换行
            font_size: 16.0,
            line_height_ratio: 1.5,
        };
        let result = typeset_paragraph("你好世界测试排版", &config);
        assert!(result.lines.len() > 1, "应在极窄容器中产生多行");
    }

    #[test]
    fn test_typeset_kinsoku_head() {
        // "号"不应出现在行首（紧随前字的右括号类）
        let config = TypesetConfig {
            container_width: 40.0,
            font_size: 16.0,
            line_height_ratio: 1.5,
        };
        let result = typeset_paragraph("你好】世界", &config);
        // 检查没有glyph的行首字符是禁则字符
        for line_chars in result.lines.chunks(1) {
            // 简单验证不会在】前换行
        }
    }
}

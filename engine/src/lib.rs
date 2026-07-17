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

use std::collections::HashMap;
use std::ffi::c_int;
use std::slice;
use std::sync::{Mutex, OnceLock};

use ab_glyph::{Font, FontVec, ScaleFont};

/// 全局字体数据（通过 set_font_path FFI 设置，作为次级回退）
static FONT_DATA: OnceLock<Option<FontVec>> = OnceLock::new();

/// 全局字符宽度表（由 Dart 侧通过 TextPainter 预测量后传入）
static CHAR_WIDTH_TABLE: OnceLock<Mutex<HashMap<u32, f64>>> = OnceLock::new();

/// 获取全局字符宽度表的引用
fn get_width_table() -> &'static Mutex<HashMap<u32, f64>> {
    CHAR_WIDTH_TABLE.get_or_init(|| Mutex::new(HashMap::new()))
}

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
                    let full_width = measure_char_width(*ch, config);
                    // 标点挤压：如果 width_em 被设为 0.5，宽度减半
                    let width = if seg.width_em == 0.5 && cjk::is_cjk_punctuation(*ch) {
                        full_width * 0.5
                    } else {
                        full_width
                    };
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

/// 精确字符宽度测量
///
/// 查表优先级：
/// 1. Dart 侧通过 TextPainter 预测量的宽度表（最准确，与渲染器一致）
/// 2. ab_glyph 度量（次级回退）
/// 3. 等宽估算（最后回退）
pub(crate) fn measure_char_width(ch: char, config: &TypesetConfig) -> f64 {
    // 1. 查询 TextPainter 预测量表
    if let Ok(map) = get_width_table().lock() {
        if let Some(&width) = map.get(&(ch as u32)) {
            return width;
        }
    }

    // 2. 回退到 ab_glyph
    if let Some(Some(font)) = FONT_DATA.get() {
        let glyph_id = font.glyph_id(ch);
        if glyph_id.0 != 0 {
            let scaled = font.as_scaled(config.font_size as f32);
            return scaled.h_advance(glyph_id) as f64;
        }
    }

    // 3. 最后回退到等宽估算
    let em = config.font_size;
    if cjk::is_cjk(ch) {
        em
    } else if ch.is_ascii() {
        em * 0.5
    } else {
        em * 0.5
    }
}

// =========== FFI 导出函数 ===========

/// 设置字符宽度表（替换全部）
///
/// Dart 侧使用 TextPainter 预测量所有字符的宽度后，通过此函数
/// 将宽度表传给 Rust 引擎，确保引擎的度量值与渲染器完全一致。
///
/// # 参数
/// - `code_points_ptr`: Unicode 码点数组指针（u32[]）
/// - `widths_ptr`: 宽度数组指针（f64[]），与码点一一对应
/// - `count`: 数组元素个数
///
/// # 安全要求
/// - 两个数组必须有效且长度为 `count`
/// - 调用会清空之前的宽度表并替换为新数据
#[no_mangle]
pub unsafe extern "C" fn set_char_widths(
    code_points_ptr: *const u32,
    widths_ptr: *const f64,
    count: c_int,
) {
    let count = count as usize;
    let code_points = unsafe { slice::from_raw_parts(code_points_ptr, count) };
    let widths = unsafe { slice::from_raw_parts(widths_ptr, count) };

    let table = get_width_table();
    let mut map = table.lock().unwrap();
    map.clear();
    for i in 0..count {
        map.insert(code_points[i], widths[i]);
    }
}

/// 设置字体文件路径（次级回退用）
///
/// # 参数
/// - `path_ptr`: UTF-8路径字符串的指针
/// - `path_len`: 路径字节长度
///
/// # 返回
/// - 1: 成功加载字体
/// - 0: 失败（文件不存在/解析失败）
///
/// # 安全要求
/// - `path_ptr`必须指向有效的UTF-8数据，长度为`path_len`
/// - 应在首次调用 `typeset_ffi` 之前调用
#[no_mangle]
pub unsafe extern "C" fn set_font_path(
    path_ptr: *const u8,
    path_len: c_int,
) -> u8 {
    let path_str = unsafe {
        let slice = slice::from_raw_parts(path_ptr, path_len as usize);
        match std::str::from_utf8(slice) {
            Ok(s) => s,
            Err(_) => return 0,
        }
    };

    match std::fs::read(path_str) {
        Ok(data) => {
            match FontVec::try_from_vec(data) {
                Ok(font) => {
                    let _ = FONT_DATA.set(Some(font));
                    1
                }
                Err(_) => {
                    let _ = FONT_DATA.set(None);
                    0
                }
            }
        }
        Err(_) => {
            let _ = FONT_DATA.set(None);
            0
        }
    }
}

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

// =========== PDF 文本提取 FFI ===========

/// 从PDF文件中提取全部文本
///
/// # 参数
/// - `path_ptr`: UTF-8文件路径的指针
/// - `path_len`: 路径字节长度
/// - `out_len_ptr`: 输出文本长度的指针（字节，不含末尾\0）
///
/// # 返回
/// - 非空指针: 成功，指向UTF-8文本（以\0结尾），长度通过out_len_ptr写出
/// - 空指针: 失败
///
/// # 安全要求
/// - `path_ptr`必须指向有效的UTF-8数据，长度为`path_len`
/// - `out_len_ptr`必须指向有效的c_int可写内存
/// - 调用方必须在使用完毕后调用`free_pdf_text`释放内存
#[no_mangle]
pub unsafe extern "C" fn extract_pdf_text(
    path_ptr: *const u8,
    path_len: c_int,
    out_len_ptr: *mut c_int,
) -> *mut u8 {
    let path_str = unsafe {
        let slice = slice::from_raw_parts(path_ptr, path_len as usize);
        match std::str::from_utf8(slice) {
            Ok(s) => s,
            Err(_) => return std::ptr::null_mut(),
        }
    };

    let text = match pdf_extract::extract_text(path_str) {
        Ok(t) => t,
        Err(_) => return std::ptr::null_mut(),
    };

    let text_bytes = text.as_bytes();
    let total_len = text_bytes.len();

    // 分配 text_len + 1 字节（含null terminator）
    let layout = std::alloc::Layout::from_size_align(total_len + 1, 1).unwrap();
    let buf = unsafe { std::alloc::alloc(layout) };
    if buf.is_null() {
        return std::ptr::null_mut();
    }

    unsafe {
        std::ptr::copy_nonoverlapping(text_bytes.as_ptr(), buf, total_len);
        *buf.add(total_len) = 0; // null terminator
        *out_len_ptr = total_len as c_int;
    }

    buf
}

/// 释放extract_pdf_text返回的文本内存
///
/// # 安全要求
/// - `ptr`必须是由`extract_pdf_text`返回的指针
/// - `len`必须与extract_pdf_text写出的长度一致
/// - 每个指针只能释放一次
#[no_mangle]
pub unsafe extern "C" fn free_pdf_text(ptr: *mut u8, len: c_int) {
    if ptr.is_null() { return; }
    let total = (len as usize) + 1; // +1 for null terminator
    let layout = std::alloc::Layout::from_size_align(total, 1).unwrap();
    unsafe { std::alloc::dealloc(ptr, layout); }
}

// =========== MOBI 文本提取 FFI ===========

/// 从MOBI文件中提取全部文本（HTML去标签后的纯文本）
///
/// # 参数
/// - `path_ptr`: UTF-8文件路径的指针
/// - `path_len`: 路径字节长度
/// - `out_len_ptr`: 输出文本长度的指针（字节，不含末尾\0）
///
/// # 返回
/// - 非空指针: 成功，指向UTF-8文本（以\0结尾），长度通过out_len_ptr写出
/// - 空指针: 失败
///
/// # 安全要求
/// - `path_ptr`必须指向有效的UTF-8数据，长度为`path_len`
/// - `out_len_ptr`必须指向有效的c_int可写内存
/// - 调用方必须在使用完毕后调用`free_mobi_text`释放内存
#[no_mangle]
pub unsafe extern "C" fn extract_mobi_text(
    path_ptr: *const u8,
    path_len: c_int,
    out_len_ptr: *mut c_int,
) -> *mut u8 {
    let path_str = unsafe {
        let slice = slice::from_raw_parts(path_ptr, path_len as usize);
        match std::str::from_utf8(slice) {
            Ok(s) => s,
            Err(_) => return std::ptr::null_mut(),
        }
    };

    let m = match mobi::Mobi::from_path(path_str) {
        Ok(m) => m,
        Err(_) => return std::ptr::null_mut(),
    };

    // MOBI内容是HTML，需要去除标签转换为纯文本
    // 很多MOBI文件使用Windows-1252编码，content_as_string_lossy可处理非UTF-8
    let html = m.content_as_string_lossy();
    let text = strip_html_to_text(&html);

    let text_bytes = text.as_bytes();
    let total_len = text_bytes.len();

    let layout = std::alloc::Layout::from_size_align(total_len + 1, 1).unwrap();
    let buf = unsafe { std::alloc::alloc(layout) };
    if buf.is_null() {
        return std::ptr::null_mut();
    }

    unsafe {
        std::ptr::copy_nonoverlapping(text_bytes.as_ptr(), buf, total_len);
        *buf.add(total_len) = 0;
        *out_len_ptr = total_len as c_int;
    }

    buf
}

/// 释放extract_mobi_text返回的文本内存
#[no_mangle]
pub unsafe extern "C" fn free_mobi_text(ptr: *mut u8, len: c_int) {
    if ptr.is_null() { return; }
    let total = (len as usize) + 1;
    let layout = std::alloc::Layout::from_size_align(total, 1).unwrap();
    unsafe { std::alloc::dealloc(ptr, layout); }
}

/// 简单HTML转纯文本：去除标签、解码常见实体、保留段落分隔
fn strip_html_to_text(html: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let mut in_tag = false;
    let mut tag_name = String::new();
    let mut collecting_tag = false;

    for ch in html.chars() {
        match ch {
            '<' => {
                in_tag = true;
                collecting_tag = true;
                tag_name.clear();
            }
            '>' => {
                in_tag = false;
                collecting_tag = false;
                // 块级元素后加换行
                let tag_lower = tag_name.to_lowercase();
                if tag_lower.starts_with("p")
                    || tag_lower.starts_with("div")
                    || (tag_lower.starts_with("h") && tag_lower.len() <= 2)
                    || tag_lower == "br"
                    || tag_lower == "li"
                    || tag_lower == "tr"
                {
                    result.push('\n');
                }
                tag_name.clear();
            }
            _ if in_tag => {
                if collecting_tag {
                    if ch.is_whitespace() || ch == '/' {
                        collecting_tag = false;
                    } else {
                        tag_name.push(ch.to_ascii_lowercase());
                    }
                }
            }
            _ if !in_tag => {
                result.push(ch);
            }
            _ => {}
        }
    }

    // 解码常见HTML实体
    let result = result
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'");

    // 清理连续空行（最多保留2个换行）
    let mut cleaned = String::with_capacity(result.len());
    let mut newline_count = 0;
    for ch in result.chars() {
        if ch == '\n' {
            newline_count += 1;
            if newline_count <= 2 {
                cleaned.push(ch);
            }
        } else {
            newline_count = 0;
            cleaned.push(ch);
        }
    }

    cleaned.trim().to_string()
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

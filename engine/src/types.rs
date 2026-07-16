//! 排版引擎公共类型定义

/// 排版配置
#[derive(Debug, Clone)]
pub struct TypesetConfig {
    /// 字号（像素，也是em单位的基准）
    pub font_size: f64,
    /// 行高倍率（1.0 = 紧密行，1.5 = 1.5倍行高）
    pub line_height_ratio: f64,
    /// 容器宽度（像素）
    pub container_width: f64,
}

impl Default for TypesetConfig {
    fn default() -> Self {
        TypesetConfig {
            font_size: 16.0,
            line_height_ratio: 1.6,
            container_width: 360.0,
        }
    }
}

/// 单个字符的位置信息
#[derive(Debug, Clone)]
pub struct GlyphInfo {
    /// 字符
    pub char: char,
    /// x 坐标（像素，从段落左边缘算起）
    pub x: f64,
    /// y 坐标（像素，从段落顶部算起）
    pub y: f64,
    /// 字符宽度（像素）
    pub width: f64,
    /// 所在行索引
    pub line_index: usize,
}

/// 排版结果
#[derive(Debug, Clone)]
pub struct TypesetResult {
    /// 每个字符的位置信息
    pub glyphs: Vec<GlyphInfo>,
    /// 每行的字符段数
    pub lines: Vec<usize>,
}

// =========== FFI C接口类型 ===========

/// FFI版本的GlyphInfo，使用C兼容类型
#[repr(C)]
#[derive(Debug, Clone)]
pub struct FFIGlyphInfo {
    /// Unicode码点
    pub code_point: u32,
    /// x 坐标
    pub x: f64,
    /// y 坐标
    pub y: f64,
    /// 字符宽度
    pub width: f64,
    /// 行索引
    pub line_index: u32,
    /// 是否为标点挤压
    pub is_squeezed: u8,
    /// 是否为中西文间距
    pub is_cjk_latin_spacing: u8,
}

/// FFI版本的排版结果
#[repr(C)]
pub struct FFITypesetResult {
    /// glyph数组指针
    pub glyphs_ptr: *mut FFIGlyphInfo,
    /// glyph数量
    pub glyph_count: u32,
    /// 每行段数数组指针
    pub line_counts_ptr: *mut u32,
    /// 行数
    pub line_count: u32,
    /// 总高度
    pub total_height: f64,
}

impl From<GlyphInfo> for FFIGlyphInfo {
    fn from(g: GlyphInfo) -> Self {
        FFIGlyphInfo {
            code_point: g.char as u32,
            x: g.x,
            y: g.y,
            width: g.width,
            line_index: g.line_index as u32,
            is_squeezed: 0,
            is_cjk_latin_spacing: 0,
        }
    }
}

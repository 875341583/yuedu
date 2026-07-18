# 阅界 · YueDu

<p align="center">
  <strong>专注中文排版体验的跨平台开源阅读器</strong>
</p>

<p align="center">
  <a href="./LICENSE">License: MPL-2.0</a>
  ·
  <a href="#下载安装">下载安装</a>
  ·
  <a href="#功能特性">功能特性</a>
  ·
  <a href="#插件系统">插件系统</a>
  ·
  <a href="#构建指南">构建指南</a>
  ·
  <a href="#项目架构">项目架构</a>
</p>

---

## 简介

**阅界**是一款跨平台开源阅读器，核心差异化优势是**深度中文排版**——标点挤压、避头尾、中西文间距、段落间距等中文书籍排版细节均由自研引擎处理，而非依赖系统默认的简陋换行。

项目采用 **Flutter 框架 + Rust 排版引擎** 架构：Native 平台通过 FFI 调用 Rust 引擎获得高性能排版，Web 平台自动降级为纯 Dart 引擎。支持 Windows、Android、Web 三端。

### 为什么选择阅界？

- 📖 **专业中文排版** — 标点挤压（行首行尾标点压缩）、避头尾规则、中英文自动加间距，印刷级阅读体验
- ⚡ **高性能引擎** — Rust 编写的排版引擎通过 FFI 接入，15MB 大文件流畅阅读
- 📂 **多格式支持** — TXT、EPUB、PDF、MOBI、DOCX、PPTX、XLSX、OFD（文本类自动识别 GBK / UTF-8 编码）
- 🗂️ **大文件按需加载** — 64KB 滑动窗口架构，百兆文件也不卡顿
- 🖖 **跟手翻页** — 除无动画模式外，滑动/覆盖/淡入/翻转 4 种翻页效果均随手指实时联动
- 📱 **横竖屏自由** — 所有格式阅读页均支持横屏/竖屏切换，PPT/PDF 独立方向控制
- 📄 **PDF 双视图** — 连续滚动与单页分页两种模式可随时切换，支持任意 PDF（文本型/扫描型/加密）
- 🖍 **高亮与笔记** — 阅读时长按文字可选取区段，5 色高亮 / 加笔记 / 复制；目录面板集中查看与跳转
- 🧩 **插件系统** — 内置文件分类与高亮插件，框架可扩展翻译/搜索/本地 AI 等能力
- 🌙 **深色模式** — 全局深色主题，护眼夜读
- 💾 **阅读进度持久化** — 自动保存阅读位置、字号、行高、翻页模式等偏好
- 🔓 **开源免费** — MPL-2.0 协议，社区版完全免费

---

## 下载安装

### Android（首发平台）

从 [Releases](../../releases) 页面下载最新的 `YueDu-vX.Y.Z.apk`，直接安装即可。

> 文件名因 GitHub API 限制使用 ASCII 格式；当前支持 arm64-v8a / armeabi-v7a / x86_64 三种架构，自带 Rust 排版引擎与 PDFium。

### Windows / Web（规划中）

- Windows 构建受 pdfrx 的 pdfium.dll 下载问题影响，当前环境不稳定；代码路径已准备就绪，可在具备完整环境的机器上 `flutter build windows --release`。
- Web 版本尚未构建发布，可参照下方构建指南本地运行。

---

## 功能特性

### 排版引擎

| 特性 | 说明 |
|------|------|
| 标点挤压 | 行首行尾标点自动压缩，避免标点占位浪费空间 |
| 避头尾 | 逗号、句号等标点不会出现在行首，符合中文排版规范 |
| 中西文间距 | 中文字符与英文/数字之间自动添加 1/4 em 间距 |
| 段落间距 | 支持自定义段间距，空行段落自动识别 |
| 精确分页 | 基于实际排版高度分页，非字符数估算 |
| 行分割 | CJK 字符任意位置可换行，英文单词整词换行 |

### 文件格式

| 格式 | 编码检测 | 章节目录 | 大文件支持 | 备注 |
|------|----------|----------|------------|------|
| TXT  | GBK / UTF-8 自动识别 | 按换行段落 | 64KB 滑动窗口 | 排版引擎重排，支持高亮 |
| EPUB | UTF-8 | OPF + NCX 解析 | 全量加载 | 排版引擎重排，支持高亮 |
| PDF  | — | 按页解析 | Pdfium 页面渲染 | 双视图：滚动 / 分页翻页 |
| MOBI | Windows-1252 兼容 | 按标题识别 | 全量加载 | PalmDOC RLE + Huffman 解压 |
| DOCX | UTF-8 | — | 全量加载 | word/document.xml 文本提取 |
| XLSX | UTF-8 | — | 全量加载 | sharedStrings + sheet 单元格 |
| PPTX | UTF-8 | — | 逐幻灯片 | 独立展示页，横/竖屏可切换 + 5 种翻页模式 |
| OFD  | UTF-8 | — | 全量加载 | 国标 GB/T 33190，扫描 TextCode |

> 当前高亮功能在 TXT/EPUB/MOBI/DOCX/XLSX/OFD 等小文件模式启用；大文件模式（GB 级 TXT）暂不支持持久化高亮，避免跨窗口偏移复杂度。

### 阅读体验

- **沉浸式阅读** — 隐藏所有 UI 元素，专注内容
- **跟手翻页** — 5 种动画模式（滑动/覆盖/淡入/翻转/无动画）均随手指实时联动，TXT/EPUB/MOBI/DOCX/XLSX/OFD/PPT 通用
- **横竖屏自由** — 所有格式阅读页均支持横屏/竖屏切换；TXT/EPUB/MOBI/DOCX/XLSX/OFD 跟随系统方向，PPT/PDF 提供独立方向控制（自动/横屏/竖屏三选一）
- **PDF 双视图** — 连续滚动与单页分页可随时切换，常驻浮动控件栏一键切换视图与方向，页码浮标可点击呼出菜单
- **PPTX 展示** — 独立页，横/竖屏自由切换，5 种翻页模式按幻灯片原始顺序逐页展示
- **高亮与笔记** — 长按阅读页文字进入选区模式，拖动选取区段后弹出工具栏：5 色高亮 / 添加笔记 / 复制 / 取消；已高亮的区段用对应颜色半透明底色渲染；目录面板新增"高亮"Tab 集中查看与跳转
- **字号 / 行高调整** — 实时预览，偏好自动保存
- **深色模式** — 跟随系统或手动切换
- **阅读进度** — 自动记忆，重新打开恢复位置

---

## 插件系统

阅界内置插件框架，采用「内置代码模块 + 配置驱动」架构：插件代码随 App 编译，用户通过插件中心启用/禁用、配置参数。Flutter AOT 限制下不支持运行时动态加载代码，因此插件以「框架 + 内置模块」方式提供，后续可扩展本地导入与 URL 下载（配置导入已预留）。

### 已有插件

| 插件 | 类型 | 默认 | 说明 |
|------|------|------|------|
| 文件分类 | 文件管理 | 启用 | 按格式自动分组书架，支持自定义标签管理书籍，长按书籍打标签 |
| 阅读高亮与笔记 | 阅读增强 | 启用 | 长按文字选取区段，5 色高亮或加笔记，目录面板集中查看与跳转 |

### 规划中插件

- 翻译（在线 API 划词翻译）
- 搜索释义（本地词典 / 在线百科）
- 本地 AI 小模型（离线推理引擎）

> 插件中心入口位于书架页右上角扩展菜单，可启用/禁用插件、查看设置、导入本地插件配置或通过 URL 下载（预留能力）。

---

## 项目架构

```
yuedu/
├── lib/                          # Flutter Dart 代码
│   ├── main.dart                 # 应用入口（含 PluginManager 初始化）
│   ├── models/
│   │   ├── book.dart             # Book / Chapter 数据模型
│   │   ├── bookmark.dart         # 书签模型
│   │   └── highlight.dart        # 高亮与笔记模型（5 色预设）
│   ├── pages/
│   │   ├── bookshelf_page.dart   # 书架页（首页，含分类视图与标签管理）
│   │   ├── reader_page.dart      # 阅读页（TXT/EPUB/MOBI/DOCX/XLSX/OFD，含高亮选区）
│   │   ├── pdf_reader_page.dart  # PDF 阅读页（双视图 + 浮动控件栏）
│   │   ├── pptx_reader_page.dart # PPT 幻灯片展示页（方向 + 翻页模式）
│   │   └── plugin_center_page.dart # 插件中心
│   ├── services/
│   │   ├── bookshelf_service.dart # 书库管理（导入/存储/读取）
│   │   ├── epub_parser.dart       # EPUB 解析器
│   │   ├── bookmark_service.dart  # 书签服务
│   │   ├── highlight_service.dart # 高亮与笔记服务
│   │   ├── tag_service.dart       # 标签服务（插件用）
│   │   └── file_service.dart      # 文件读取（条件导入）
│   ├── plugins/                   # 插件系统
│   │   ├── plugin.dart            # 插件接口与元数据
│   │   ├── plugin_manager.dart    # 插件管理器（注册/启用/持久化）
│   │   └── builtin/
│   │       ├── file_category_plugin.dart
│   │       └── highlight_plugin.dart
│   ├── typeset/
│   │   ├── engine.dart            # 排版引擎接口
│   │   ├── native_engine.dart     # Rust FFI 引擎（Native）
│   │   ├── web_engine.dart        # Dart 引擎（Web）
│   │   └── typeset_engine_provider.dart # 引擎选择器
│   ├── utils/
│   │   └── encoding.dart          # GBK 分块解码器
│   └── widgets/
│       ├── typeset_renderer.dart  # 排版渲染（含高亮层绘制）
│       └── toc_bookmark_panel.dart # 目录/书签/高亮三 Tab 面板
├── engine/                        # Rust 排版引擎
├── android/                       # Android 平台配置
├── windows/                       # Windows 平台配置
└── build.ps1                      # 一键构建脚本
```

### 技术栈

| 层 | 技术 | 说明 |
|----|------|------|
| UI 框架 | Flutter 3.24 | 跨平台渲染 |
| 排版引擎 | Rust → FFI | Native 平台高性能排版 |
| Web 引擎 | Dart | 纯 Dart 实现，无需 FFI |
| 编码处理 | 自研分块解码器 | GBK / UTF-8 自动识别，O(n) 复杂度 |
| 数据持久化 | SharedPreferences | 阅读进度、设置偏好、书签、高亮、插件启用状态 |
| 插件系统 | 内置模块 + 配置驱动 | 框架可扩展，支持启用/禁用与参数配置 |
| 开源协议 | MPL-2.0 | 社区版免费，商业版提供增量同步服务 |

### 排版引擎双轨制

```
┌─────────────────────────────────────┐
│          Flutter UI Layer           │
│     (bookshelf_page / reader_page)  │
├─────────────┬───────────────────────┤
│  Native     │      Web              │
│  Rust FFI   │   Dart Engine         │
│  (高性能)    │  (兼容性优先)          │
└─────────────┴───────────────────────┘
```

- **Native 平台**（Windows / Android）：通过 `dart:ffi` 调用 Rust 编译的动态库，享受原生性能
- **Web 平台**：因浏览器不支持 FFI，自动切换为纯 Dart 实现的排版引擎，功能一致但性能略低

---

## 构建指南

### 环境要求

- Flutter 3.24+
- Rust（stable）
- Android NDK（Android 构建需要）
- Visual Studio 2022（Windows 构建需要）

### 1. 克隆仓库

```bash
git clone https://github.com/875341583/yuedu.git
cd yuedu
flutter pub get
```

### 2. 构建 Rust 排版引擎

```bash
cd engine

# Windows DLL
cargo build --release
# 产物：engine/target/release/typeset_engine.dll

# Android .so（需安装 cargo-ndk）
cargo install cargo-ndk
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o ../android/app/src/main/jniLibs build --release
```

### 3. 构建 Flutter 应用

```bash
# Windows
flutter build windows --release

# Android APK
flutter build apk --release

# Web
flutter build web --release
```

### 一键构建脚本

```powershell
# Windows
.\build.ps1 windows

# Android
.\build.ps1 apk

# Web
.\build.ps1 web
```

---

## 开发路线

### 已完成 ✅

- [x] 书架管理（导入 / 删除 / 阅读记录，8 种格式标签）
- [x] TXT 导入（GBK / UTF-8 编码自动识别）
- [x] EPUB 导入（OPF / NCX 章节目录解析）
- [x] PDF 导入（pdfrx/PDFium 页面渲染，双视图：连续滚动 + 单页分页）
- [x] MOBI 导入（PalmDOC RLE + Huffman 解压，修复 compression 与 0x80-0xBF backref 双 bug）
- [x] DOCX 导入（word/document.xml 文本提取，UTF-8 解码修复）
- [x] PPTX 导入（独立展示页，按幻灯片原始顺序逐页，横/竖屏可切换）
- [x] XLSX 导入（sharedStrings + worksheets 单元格提取，UTF-8 解码修复）
- [x] OFD 导入（GB/T 33190 国标格式，扫描 TextCode，UTF-8 解码修复）
- [x] Rust 排版引擎（标点挤压 / 避头尾 / 中西文间距）
- [x] 精确字体度量（TextPainter 预度量 + FFI 宽度表）
- [x] 跟手翻页重构（5 种模式：滑动 / 覆盖 / 淡入 / 翻转 / 无动画，除无动画外均随手指实时联动）
- [x] 阅读体验增强（阅读主题 / 设置面板 / 进度拖拽）
- [x] 书签与目录（章节跳转 + 键盘快捷键）
- [x] 大文件 64KB 滑动窗口按需加载
- [x] 阅读设置持久化（字号 / 行高 / 深色模式 / 翻页模式 / PDF 视图模式 / PPT 方向与翻页模式）
- [x] 深色模式
- [x] Android 首发发布（v0.4.0）
- [x] 横竖屏自由（所有格式阅读页支持横/竖屏切换，PPT/PDF 独立方向控制：自动/横屏/竖屏三选一）
- [x] PPT 翻页模式（5 种：滑动/覆盖/淡入/翻转/无动画，与主阅读页一致）
- [x] PDF 浮动控件栏（常驻视图切换 + 方向切换按钮，页码浮标可点击呼出菜单，首次进入提示）
- [x] 插件系统框架（Plugin 接口 + PluginManager + 持久化 + 插件中心 UI + 本地导入/URL 下载预留）
- [x] 文件分类内置插件（按格式分组 + 自定义标签管理书籍，默认启用）
- [x] v0.4.1 发布（乱码修复 + 横屏方向 + PDF 翻页可见性 + 插件系统）
- [x] 阅读高亮与笔记插件（长按选区 + 5 色高亮 + 笔记 + 选区工具栏 + 渲染层叠加 + 三 Tab 面板查看跳转）
- [x] v0.5.0 发布

### 计划中 📋

- [ ] Windows 稳定构建（解决 pdfium.dll 依赖）
- [ ] Web 版发布
- [ ] 自定义主题 / 字体
- [ ] CRDT 增量同步服务（商业版功能）
- [ ] CBZ / CBR 漫画格式支持
- [ ] TTS 朗读
- [ ] 翻译插件（在线 API 划词翻译）
- [ ] 搜索释义插件（本地词典 / 在线百科）
- [ ] 本地 AI 小模型嵌入（离线推理引擎）
- [ ] 高亮导出（Markdown / 纯文本）
- [ ] 高亮检索（按颜色 / 笔记内容过滤）
- [ ] 大文件高亮支持（byteOffset 锚定 + 文本指纹重定位）

---

## 商业模式

阅界采用 **Freemium** 模式：

| | 社区版（免费） | 商业版（付费） |
|---|---|---|
| 本地阅读 | ✅ 全功能 | ✅ 全功能 |
| 中文排版引擎 | ✅ | ✅ |
| 多格式支持 | ✅ | ✅ |
| 高亮与笔记 | ✅ | ✅ |
| 插件系统 | ✅ | ✅ |
| 阅读进度同步 | ❌ | ✅ CRDT 增量同步 |
| 多设备同步 | ❌ | ✅ |
| 云端书库 | ❌ | ✅ |

> 同步服务使用 CRDT（无冲突复制数据类型），支持离线编辑 + 多端自动合并，无需中心化冲突解决。

---

## 许可证

本项目基于 [MPL-2.0](./LICENSE) 协议开源。

- ✅ 个人使用、修改、分发
- ✅ 商业使用
- ⚠️ 修改后的文件需以 MPL-2.0 开源
- ✅ 可与闭源项目组合使用（新增文件无需开源）

---

## 致谢

- [Flutter](https://flutter.dev) — UI 框架
- [Rust](https://www.rust-lang.org) — 排版引擎
- [archive](https://pub.dev/packages/archive) — EPUB (ZIP) 解压
- [gbk_codec](https://pub.dev/packages/gbk_codec) — GBK 编码参考
- [file_picker](https://pub.dev/packages/file_picker) — 文件选择
- [pdfrx](https://pub.dev/packages/pdfrx) — PDFium 页面渲染

---

<p align="center">
  Made with ❤️ for Chinese readers
</p>

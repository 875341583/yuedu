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
- 📂 **多格式支持** — TXT（自动识别 GBK / UTF-8 编码）、EPUB
- 🗂️ **大文件按需加载** — 64KB 滑动窗口架构，百兆文件也不卡顿
- 🌙 **深色模式** — 全局深色主题，护眼夜读
- 💾 **阅读进度持久化** — 自动保存阅读位置、字号、行高等偏好
- 🔓 **开源免费** — MPL-2.0 协议，社区版完全免费

---

## 下载安装

### Android

从 [Releases](../../releases) 页面下载最新 APK，直接安装即可。

> 当前支持 arm64-v8a / armeabi-v7a / x86_64 三种架构。

### Windows

从 [Releases](../../releases) 页面下载 `yuedu-windows-x64.zip`，解压后运行 `yuedu.exe`。

### Web

访问在线 Demo（部署后更新链接），或在本地运行：

```bash
flutter run -d chrome --web-port=8888
```

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

| 格式 | 编码检测 | 章节目录 | 大文件支持 |
|------|----------|----------|------------|
| TXT | GBK / UTF-8 自动识别 | 按换行段落 | 64KB 滑动窗口 |
| EPUB | UTF-8 | OPF + NCX 解析 | 全量加载 |

### 阅读体验

- **沉浸式阅读** — 隐藏所有 UI 元素，专注内容
- **翻页交互** — 点击左右区域翻页，进度条拖拽跳转
- **字号 / 行高调整** — 实时预览，偏好自动保存
- **深色模式** — 跟随系统或手动切换
- **阅读进度** — 自动记忆，重新打开恢复位置

---

## 项目架构

```
yuedu/
├── lib/                          # Flutter Dart 代码
│   ├── main.dart                 # 应用入口
│   ├── models/
│   │   └── book.dart             # Book / Chapter 数据模型
│   ├── pages/
│   │   ├── bookshelf_page.dart   # 书架页（首页）
│   │   └── reader_page.dart      # 阅读页
│   ├── services/
│   │   ├── bookshelf_service.dart # 书库管理（导入/存储/读取）
│   │   ├── epub_parser.dart       # EPUB 解析器
│   │   └── file_service.dart      # 文件读取（条件导入）
│   ├── typeset/
│   │   ├── engine.dart            # 排版引擎接口
│   │   ├── native_engine.dart     # Rust FFI 引擎（Native）
│   │   ├── web_engine.dart        # Dart 引擎（Web）
│   │   └── typeset_engine_provider.dart # 引擎选择器
│   ├── utils/
│   │   └── encoding.dart          # GBK 分块解码器
│   └── widgets/
│       └── typeset_renderer.dart  # 排版渲染组件
├── engine/                        # Rust 排版引擎
│   ├── src/
│   │   ├── lib.rs                 # FFI 导出
│   │   ├── cjk.rs                 # CJK 排版（标点挤压/避头尾/间距）
│   │   ├── linebreak.rs           # 行分割算法
│   │   └── types.rs               # 数据类型
│   └── Cargo.toml
├── android/                       # Android 平台配置
│   └── app/src/main/jniLibs/      # Rust 编译的 .so 文件
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
| 数据持久化 | SharedPreferences | 阅读进度、设置偏好 |
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

- [x] 书架管理（导入 / 删除 / 阅读记录）
- [x] TXT 导入（GBK / UTF-8 编码自动识别）
- [x] EPUB 导入（OPF / NCX 章节目录解析）
- [x] Rust 排版引擎（标点挤压 / 避头尾 / 中西文间距）
- [x] 大文件 64KB 滑动窗口按需加载
- [x] 阅读设置持久化（字号 / 行高 / 深色模式）
- [x] 深色模式
- [x] Windows / Android / Web 三端发布

### 计划中 📋

- [ ] 精确字体度量（替换等宽近似为实际字形宽度）
- [ ] CRDT 增量同步服务（商业版功能）
- [ ] 更多格式支持（PDF / MOBI）
- [ ] 自定义主题 / 字体
- [ ] 书签与笔记
- [ ] TTS 朗读

---

## 商业模式

阅界采用 **Freemium** 模式：

| | 社区版（免费） | 商业版（付费） |
|---|---|---|
| 本地阅读 | ✅ 全功能 | ✅ 全功能 |
| 中文排版引擎 | ✅ | ✅ |
| 多格式支持 | ✅ | ✅ |
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

---

<p align="center">
  Made with ❤️ for Chinese readers
</p>
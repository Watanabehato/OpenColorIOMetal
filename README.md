# OpenColorIOMetal

Swift 6 与 Metal 原生色彩管理项目，基于 OpenColorIO 的固定提交
`5a808fb57a94c7229640a97835c420c9a1fbd1fe`（2.6.0-dev）。目标包含完整内置配置、
色彩空间之间的转换、原生 `.ocio` 配置支持、Debug CLI 和默认静态 macOS Framework。
迁移仍在进行；实际支持范围和未完成项见 [Compatibility.md](Documentation/Compatibility.md)。

生产运行时只有 Swift 和 Metal，并使用 Foundation。没有 C++/Objective-C 包装层、
OpenColorIO 动态库或 Python 运行依赖。开发工具通过固定版本的上游源码导出解析 Metal
着色器、原始 LUT 数据和独立 CPU 测试向量；不会把所有色彩转换烘焙成统一精度的 3D LUT。

## GitHub Actions 构建

推送 `codex/**`、`main` 分支或手动运行 `Swift 6 Metal build`。
工作流在 Linux 构建固定上游参考工具并生成原生转换归档，在 macOS 使用 Swift 6 编译。

产物 `OpenColorIOMetal-macOS-universal` 包含：

- `Release/OpenColorIOMetal.framework`：默认静态库，arm64 + x86_64，最低 macOS 13。
- `Debug/ocio-metal` 和 `.dSYM`：通用架构 Debug CLI，包含未优化的 Debug 运行库。
- `Debug/OpenColorIOMetal.framework`：对应的未优化静态 Framework，便于单步调试。
- `Debug/Catalogue`：色彩配置、Metal 着色器、LUT 和数值验证数据。
- 覆盖、Metal 编译和可用时的 GPU 数值对照报告。

离线 Metal 编译与真实 GPU 数值验证分别报告。GitHub 托管的 macOS 虚拟机如果没有 Metal
设备，报告会明确标记 GPU 验证未完成；不会把跳过当成数值一致性通过。

## CLI

```sh
./Debug/ocio-metal info --archive ./Debug/Catalogue
./Debug/ocio-metal configs --archive ./Debug/Catalogue
./Debug/ocio-metal spaces --archive ./Debug/Catalogue
./Debug/ocio-metal convert --archive ./Debug/Catalogue \
  --src 'ACEScg' --dst 'sRGB - Display' --rgba '0.18,0.18,0.18,1'
./Debug/ocio-metal validate --archive ./Debug/Catalogue
./Debug/ocio-metal validate --gpu --archive ./Debug/Catalogue
```

`--config` 指定配置 ID，省略时采用上游默认 CG 配置。
空间名称、别名和角色按配置解析。`--binary` 读写小端 Float32 RGBA，支持文件或标准输入输出。

## Framework 集成

静态 Framework 在 Xcode 中选择 **Do Not Embed** 并链接 Metal.framework。
静态库不会自动加载资源：将 `OpenColorIOMetal.framework/Resources/Catalogue`
复制到应用资源中，或为 `OCIOCatalogue(contentsOf:)` 传入明确的目录 URL。

```swift
import OpenColorIOMetal

let catalogue = try OCIOCatalogue(contentsOf: archiveURL)
let engine = try MetalColorEngine(catalogue: catalogue)
let processor = try engine.processor(source: "ACEScg", destination: "sRGB - Display")
let pixels = try processor.processRGBA([0.18, 0.18, 0.18, 1])
```

`ColorProcessor` 也支持应用已有 Metal command buffer 的异步编码。
源/目标空间不能仅凭名称跨配置等同；转换必须选择同一份配置。

本地开发可运行 `swift test`、`bash Scripts/build-framework.sh`、
`CONFIGURATION=Debug bash Scripts/build-framework.sh`、`bash Scripts/build-cli.sh`；
先下载 CI 的 `native-metal-catalogue` 到 `Sources/OpenColorIOMetal/Resources/Catalogue`。
直接构建 Framework 可设置 `FRAMEWORK_LINKAGE=dynamic`；发布和 CI 默认保持静态。

遵循上游 BSD-3-Clause 许可，详见 [LICENSE](LICENSE) 和 [UPSTREAM.json](UPSTREAM.json)。

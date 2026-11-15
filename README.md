# EchoScribe

离线实时录音转写 App（类似讯飞听见的开源替代）：边录音边出字，支持句尾自动定稿、标点与说话人区分，录音文件本地管理。

## 技术选型

- **客户端**：Flutter（Android 手机 / Windows 桌面，同一套 Dart 代码；Android 为主目标）
- **ASR 引擎**：[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（Next-gen Kaldi，Apache-2.0）
  - 通过 pub.dev 官方包 `sherpa_onnx` 集成（各平台自带预编译 onnxruntime，零原生代码）
  - 流式转写：streaming Zipformer（partial → final 定稿机制）
  - 当前模型：`sherpa-onnx-x-asr-960ms-streaming-zipformer-transducer-zh-en-punct-int8`（中英双语、自带标点输出、int8 量化，约 128MB）
  - 说话人分轨：pyannote segmentation + 3D-Speaker CAM++ zh-en 声纹 embedding（离线非流式，录音停止后后台 isolate 运行，约 34MB；支持指定人数聚类与对已有录音重新分析）
  - 规划能力：SenseVoice 文件转写、silero-vad、GTCRN 降噪
- **麦克风采集**：`record` 包（16kHz 单声道 PCM16 流）
- **系统声音 / 内录**：`audio_io`（WASAPI loopback，同样输出 16kHz 单声道 PCM16，与麦克风共用同一转写管线）
  - 本仓库内置打过补丁的 fork（`third_party/audio_io`）：上游 0.6.1 用 VAD Process_Loopback 排除自身进程，该激活方式在部分机器上失败；EchoScribe 不播放音频，无自排除需求，fork 改用普通 endpoint loopback（Win10/Win11 均可用）。上游提供选项后可移除该 override
- **文件导入转写**：`packages/audio_decoder` 自研插件（miniaudio 解码 WAV/MP3/FLAC → 16kHz 单声道 PCM16），后台 isolate 复用流式识别器整段转写，进度条可视，导入后自动跑说话人分析；m4a/aac 暂不支持（miniaudio 无内置解码器，需先转 WAV/MP3）

## MVP 数据流

```
麦克风 record / 系统声音 audio_io loopback（均为 16k mono PCM16 stream）
 ├─→ WAV 落盘（边录边写，停止时回填 RIFF 头长度）
 └─→ Float32 → sherpa_onnx OnlineRecognizer
       ├─ getResult   → partial 实时上屏（灰色斜体）
       └─ isEndpoint → reset → 定稿段落（含标点 + 时间范围）

停止录音后（自动、后台 isolate）：
 WAV → pyannote 分割 + 声纹 embedding + 聚类 → 说话人时间段
     → 与定稿段落按时间重叠归属 → 「说话人N：……」上屏并写入 sidecar
```

## 环境准备

1. **Flutter SDK**（stable，含 Windows 桌面支持；Windows 构建需 VS2022 "使用 C++ 的桌面开发" 工具链）
   - 国内建议设置镜像环境变量后再执行 `flutter pub get`：
     ```powershell
     $env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
     $env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
     ```
2. **下载模型**（ASR 约 128MB + 说话人分轨约 34MB，不入库，`.gitignore` 已排除）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/download_model.ps1
   # 网络不畅时走代理：
   powershell -ExecutionPolicy Bypass -File scripts/download_model.ps1 -Proxy http://127.0.0.1:6666
   ```

## 运行

```powershell
flutter pub get
flutter run -d windows    # Windows 桌面
# Android：安装 Android SDK / JDK 后 flutter run -d <device-id>
```

### Android APK

```powershell
flutter build apk --release --target-platform android-arm64
# 产物：build\app\outputs\flutter-apk\app-release.apk（约 250MB，模型内置）
```

- 工具链：JDK 21（`D:\software\jdk-21`）+ Android SDK（`D:\software\Android\Sdk`，platform-36 / build-tools 36 / NDK 28.2.13676358），已通过 `flutter config --android-sdk/--jdk-dir` 持久化
- Gradle 发行包走腾讯镜像、插件依赖走阿里云镜像（`android/settings.gradle.kts`）；`kotlin.incremental=false` 规避本机 Kotlin 2.4 增量缓存写盘失败
- Android 端功能：麦克风录音转写、说话人分轨、标签/检索、文件导入转写（`audio_decoder` 以 NDK 编译 miniaudio，WAV/MP3/FLAC）；系统内录为 Windows 专属（WASAPI），Android 上自动隐藏该选项
- release 当前用 debug 签名（自装可用）；对外发布前需配置正式 keystore

- 录音文件保存在 `文档\EchoScribe\recordings\`（16kHz 单声道 WAV + 同名 `.json` 元数据）
- 首次点击录音按钮会加载模型（数秒），之后复用
- 模型以 asset 打包进应用，运行时拷贝到应用数据目录使用

## Roadmap

- [x] MVP：录音 + 流式转写上屏（partial/final）
- [x] 句尾定稿 + 标点（模型自带标点输出）
- [x] 录音库管理（列表、查看全文、重命名、删除；转写以同名 `.json` sidecar 持久化）
- [x] 说话人分轨（录音停止后自动后台分析；定稿按句尾标点切句后逐句归属说话人；支持指定人数聚类（自动检测在声线相近时易合并）与对已有录音重新分析，不用重录）
- [x] 系统声音 / 内录采集（WASAPI loopback 直采系统输出，转写视频/会议不再经过扬声器与房间混响，声纹区分度显著更好；录音页可切换 麦克风/系统声音，来源记入 sidecar 并在录音库标记「内录」）
- [x] 标签 / 全文检索（标签存 sidecar，条目菜单编辑、按标签 chips 筛选；标题+转写内容大小写不敏感搜索。文件夹并入标签——同一筛选场景且支持多选）
- [x] 文件导入转写（录音库「导入音频转写」选择 WAV/MP3/FLAC，后台解码+识别+说话人分析，来源标记「导入」）


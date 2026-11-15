# EchoScribe

离线实时录音转写 App（类似讯飞听见的开源替代）：边录音边出字，支持句尾自动定稿、标点与说话人区分，录音文件本地管理。

## 技术选型

- **客户端**：Flutter（Windows 桌面 / Android，同一套 Dart 代码）
- **ASR 引擎**：[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（Next-gen Kaldi，Apache-2.0）
  - 通过 pub.dev 官方包 `sherpa_onnx` 集成（各平台自带预编译 onnxruntime，零原生代码）
  - 流式转写：streaming Zipformer（partial → final 定稿机制）
  - 当前模型：`sherpa-onnx-x-asr-960ms-streaming-zipformer-transducer-zh-en-punct-int8`（中英双语、自带标点输出、int8 量化，约 128MB）
  - 规划能力：SenseVoice 文件转写、silero-vad、说话人分轨、GTCRN 降噪
- **麦克风采集**：`record` 包（16kHz 单声道 PCM16 流）

## MVP 数据流

```
record (16k mono PCM16 stream)
 ├─→ WAV 落盘（边录边写，停止时回填 RIFF 头长度）
 └─→ Float32 → sherpa_onnx OnlineRecognizer
       ├─ getResult   → partial 实时上屏（灰色斜体）
       └─ isEndpoint → reset → 定稿段落（含标点）
```

## 环境准备

1. **Flutter SDK**（stable，含 Windows 桌面支持；Windows 构建需 VS2022 "使用 C++ 的桌面开发" 工具链）
   - 国内建议设置镜像环境变量后再执行 `flutter pub get`：
     ```powershell
     $env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
     $env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
     ```
2. **下载模型**（约 128MB，不入库，`.gitignore` 已排除）：
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

- 录音文件保存在 `文档\EchoScribe\recordings\`（16kHz 单声道 WAV + 同名 `.json` 元数据）
- 首次点击录音按钮会加载模型（数秒），之后复用
- 模型以 asset 打包进应用，运行时拷贝到应用数据目录使用

## Roadmap

- [x] MVP：录音 + 流式转写上屏（partial/final）
- [x] 句尾定稿 + 标点（模型自带标点输出）
- [x] 录音库管理（列表、查看全文、重命名、删除；转写以同名 `.json` sidecar 持久化）
- [ ] 说话人分轨
- [ ] 标签 / 文件夹 / 全文检索
- [ ] 文件导入转写

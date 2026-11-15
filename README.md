# EchoScribe

离线实时录音转写 App（类似讯飞听见的开源替代）：边录音边出字，支持句尾自动定稿、标点与说话人区分，录音文件本地管理。

## 技术选型

- **ASR 引擎**：[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（Next-gen Kaldi，Apache-2.0）
  - 流式转写：streaming Zipformer（边录边出字，partial → final 定稿机制）
  - 文件转写：SenseVoice
  - 辅助能力：silero-vad、标点模型、说话人分轨、GTCRN 降噪
- **形态**：移动端 App（跨平台方案待定：Flutter / RN / 原生）

## Roadmap

- [ ] MVP：录音 + 流式转写上屏（partial/final）
- [ ] 句尾定稿 + 标点
- [ ] 录音库管理（列表、重命名、删除）
- [ ] 说话人分轨
- [ ] 标签 / 文件夹 / 全文检索
- [ ] 文件导入转写

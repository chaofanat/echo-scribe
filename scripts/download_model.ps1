# Downloads the models used by EchoScribe into assets/models/:
#   1. Streaming ASR model (bilingual zh-en zipformer, ~128 MB)
#   2. Speaker diarization models (pyannote segmentation ~7 MB +
#      3D-Speaker embedding ~40 MB)
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/download_model.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/download_model.ps1 -Proxy http://127.0.0.1:6666
param(
    [string]$Proxy = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$modelsDir = Join-Path (Join-Path $root "assets") "models"
# Windows' own bsdtar; Git's GNU tar would misread `D:\...` paths as remotes.
$tarExe = Join-Path $env:SystemRoot "System32\tar.exe"

function Invoke-Download {
    param([string]$Url, [string]$Dest)
    if (Test-Path $Dest) { return }
    Write-Host "Downloading $Url"
    $curlArgs = @("--fail", "--retry", "3", "-L", "-C", "-", "-o", $Dest, $Url)
    if ($Proxy -ne "") { $curlArgs = @("--proxy", $Proxy) + $curlArgs }
    & curl.exe @curlArgs
    if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit $LASTEXITCODE): $Url" }
}

function Expand-Tarbz2 {
    param([string]$Archive, [string]$DestDir)
    Write-Host "Extracting $Archive to $DestDir ..."
    & $tarExe -xjf $Archive -C $DestDir
    if ($LASTEXITCODE -ne 0) { throw "Extract failed (tar exit $LASTEXITCODE)" }
}

New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null

# --- 1. Streaming ASR model -------------------------------------------------
$asr = "sherpa-onnx-x-asr-960ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05"
$asrDir = Join-Path $modelsDir $asr
$asrRequired = @("encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt")
$asrMissing = @($asrRequired | Where-Object { -not (Test-Path (Join-Path $asrDir $_)) })

if ($asrMissing.Count -eq 0) {
    Write-Host "ASR model already present: $asrDir"
} else {
    $asrArchive = Join-Path $modelsDir "$asr.tar.bz2"
    Invoke-Download -Url "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$asr.tar.bz2" -Dest $asrArchive
    Expand-Tarbz2 -Archive $asrArchive -DestDir $modelsDir
    $asrMissing = @($asrRequired | Where-Object { -not (Test-Path (Join-Path $asrDir $_)) })
    if ($asrMissing.Count -gt 0) { throw "ASR model files missing after extract: $($asrMissing -join ', ')" }
    Remove-Item $asrArchive -ErrorAction SilentlyContinue
    Write-Host "ASR model ready: $asrDir"
}

# --- 2. Speaker diarization models ------------------------------------------
# Pyannote segmentation (tar.bz2, extracts to its own directory).
$seg = "sherpa-onnx-pyannote-segmentation-3-0"
$segDir = Join-Path $modelsDir $seg
$segModel = Join-Path $segDir "model.onnx"

if (Test-Path $segModel) {
    Write-Host "Segmentation model already present: $segDir"
} else {
    $segArchive = Join-Path $modelsDir "$seg.tar.bz2"
    Invoke-Download -Url "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/$seg.tar.bz2" -Dest $segArchive
    Expand-Tarbz2 -Archive $segArchive -DestDir $modelsDir
    if (-not (Test-Path $segModel)) { throw "Segmentation model missing after extract: $segModel" }
    Remove-Item $segArchive -ErrorAction SilentlyContinue
    Write-Host "Segmentation model ready: $segModel"
}

# 3D-Speaker embedding extractor (a single .onnx file).
$emb = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
$embFile = Join-Path $modelsDir $emb

if (Test-Path $embFile) {
    Write-Host "Embedding model already present: $embFile"
} else {
    Invoke-Download -Url "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/$emb" -Dest $embFile
    if (-not (Test-Path $embFile)) { throw "Embedding model missing after download: $embFile" }
    Write-Host "Embedding model ready: $embFile"
}

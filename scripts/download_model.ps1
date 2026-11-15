# Downloads the streaming ASR model used by EchoScribe into assets/models/.
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/download_model.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/download_model.ps1 -Proxy http://127.0.0.1:6666
param(
    [string]$Proxy = ""
)

$ErrorActionPreference = "Stop"

$model = "sherpa-onnx-x-asr-960ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05"
$url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$model.tar.bz2"

$root = Split-Path -Parent $PSScriptRoot
$modelsDir = Join-Path $root "assets" | Join-Path -ChildPath "models"
$targetDir = Join-Path $modelsDir $model
$required = @("encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt")

$missing = @($required | Where-Object { -not (Test-Path (Join-Path $targetDir $_)) })
if ($missing.Count -eq 0) {
    Write-Host "Model already present: $targetDir"
    exit 0
}

New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null
$archive = Join-Path $modelsDir "$model.tar.bz2"

if (-not (Test-Path $archive)) {
    Write-Host "Downloading $url"
    $curlArgs = @("--fail", "--retry", "3", "-L", "-C", "-", "-o", $archive, $url)
    if ($Proxy -ne "") { $curlArgs = @("--proxy", $Proxy) + $curlArgs }
    & curl.exe @curlArgs
    if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit $LASTEXITCODE)" }
}

Write-Host "Extracting to $modelsDir ..."
# Windows' own bsdtar; Git's GNU tar would misread `D:\...` paths as remotes.
$tarExe = Join-Path $env:SystemRoot "System32\tar.exe"
& $tarExe -xjf $archive -C $modelsDir
if ($LASTEXITCODE -ne 0) { throw "Extract failed (tar exit $LASTEXITCODE)" }

$missing = @($required | Where-Object { -not (Test-Path (Join-Path $targetDir $_)) })
if ($missing.Count -gt 0) {
    throw "Model files missing after extract: $($missing -join ', ')"
}

Remove-Item $archive -ErrorAction SilentlyContinue
Write-Host "Model ready: $targetDir"

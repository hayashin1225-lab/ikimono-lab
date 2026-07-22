[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$productRoot = Split-Path -Parent $PSScriptRoot
$testFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.test.js' |
    Sort-Object -Property Name |
    ForEach-Object { $_.FullName }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js が見つかりません。Node.js 20 以降を導入してから再実行してください。'
}

Push-Location -LiteralPath $productRoot
try {
    & node --test @testFiles
    if ($LASTEXITCODE -ne 0) {
        throw "自動テストが失敗しました。終了コード: $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

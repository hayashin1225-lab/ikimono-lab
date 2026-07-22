Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$implementation = Join-Path $PSScriptRoot 'fake-gh.ps1'
if (-not (Test-Path -LiteralPath $implementation -PathType Leaf)) {
  [Console]::Error.WriteLine("Fake gh implementation is missing: $implementation")
  exit 78
}

$previousArguments = $env:FAKE_GH_ARGV_JSON
$forwardedArguments = @($args | ForEach-Object { [string]$_ })
$env:FAKE_GH_ARGV_JSON = ConvertTo-Json -InputObject $forwardedArguments -Compress
$previousPreference = $ErrorActionPreference
try {
  $ErrorActionPreference = 'Continue'
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $implementation 2>&1
  $code = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousPreference
  if ($null -eq $previousArguments) { Remove-Item Env:\FAKE_GH_ARGV_JSON -ErrorAction SilentlyContinue } else { $env:FAKE_GH_ARGV_JSON = $previousArguments }
}

foreach ($line in @($output)) { Write-Output $line }
exit $code

param(
    [string]$InputScript = 'EveLayoutManager.ps1',
    [string]$IniFile = 'prefs.ini',
    [string]$FallbackIniFile = 'prefs.example.ini',
    [string]$OutputDir = 'dist\standalone',
    [string]$OutputExe = 'EveLayoutManager.exe',
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$inputScriptPath = Join-Path $projectRoot $InputScript
$iniFilePath = Join-Path $projectRoot $IniFile
$fallbackIniFilePath = Join-Path $projectRoot $FallbackIniFile
$outputDirPath = Join-Path $projectRoot $OutputDir
$outputExePath = Join-Path $outputDirPath $OutputExe
$cacheFilePath = Join-Path $projectRoot 'esi-name-cache.json'

if (-not (Test-Path -LiteralPath $inputScriptPath)) {
    throw "Input PowerShell script not found: $inputScriptPath"
}

$configSourcePath = $null
if (Test-Path -LiteralPath $iniFilePath) {
    $configSourcePath = $iniFilePath
}
elseif (Test-Path -LiteralPath $fallbackIniFilePath) {
    $configSourcePath = $fallbackIniFilePath
}
else {
    throw "Neither $IniFile nor $FallbackIniFile was found."
}

if ($Clean -and (Test-Path -LiteralPath $outputDirPath)) {
    Remove-Item -LiteralPath $outputDirPath -Recurse -Force
}

if (-not (Test-Path -LiteralPath $outputDirPath)) {
    New-Item -ItemType Directory -Path $outputDirPath | Out-Null
}

$ps2exeCommand = Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue
if (-not $ps2exeCommand) {
    throw @"
PS2EXE is not installed.

Install it in PowerShell with:
Install-Module -Name ps2exe -Scope CurrentUser

Then run:
.\Build-Standalone.ps1
"@
}

Write-Host "Building executable from $InputScript ..."
Invoke-PS2EXE `
    -InputFile $inputScriptPath `
    -OutputFile $outputExePath `
    -NoConsole `
    -Title 'EVE Layout Manager' `
    -Product 'EVE Layout Manager' `
    -Company 'Local Build' `
    -Copyright 'Local Build'

Copy-Item -LiteralPath $configSourcePath -Destination (Join-Path $outputDirPath 'prefs.ini') -Force

if (Test-Path -LiteralPath $cacheFilePath) {
    Copy-Item -LiteralPath $cacheFilePath -Destination (Join-Path $outputDirPath 'esi-name-cache.json') -Force
}

Write-Host ''
Write-Host 'Standalone package created:'
Write-Host "  $outputDirPath"
Write-Host ''
Write-Host 'Contents:'
Write-Host "  $OutputExe"
Write-Host '  prefs.ini'
if (Test-Path -LiteralPath $cacheFilePath) {
    Write-Host '  esi-name-cache.json'
}
Write-Host ''
Write-Host "Config source used: $([System.IO.Path]::GetFileName($configSourcePath))"

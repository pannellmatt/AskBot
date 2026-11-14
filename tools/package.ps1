# Builds dist\AskBot-<version>.zip: the files the .toc loads plus the docs, inside an
# AskBot\ folder, ready to unzip into Interface\AddOns or share.
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File tools\package.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$toc = Join-Path $root "AskBot.toc"
$version = (Select-String -Path $toc -Pattern '^## Version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()

$dist = Join-Path $root "dist"
$staging = Join-Path $dist "staging"
$stage = Join-Path $staging "AskBot"
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force $stage | Out-Null

# Every .lua file the .toc lists, plus the .toc and docs (tests, media and tools stay out).
$luaFiles = Get-Content $toc | Where-Object { $_ -match '^\s*[^#\s].*\.lua\s*$' } | ForEach-Object { $_.Trim() }
foreach ($f in @("AskBot.toc", "README.md", "INSTALL.txt", "LICENSE.md") + $luaFiles) {
    Copy-Item (Join-Path $root $f) $stage
}

$zip = Join-Path $dist "AskBot-$version.zip"
if (Test-Path $zip) { Remove-Item $zip }
# Windows' bsdtar writes zips with forward-slash paths, which every unzipper handles.
& "$env:SystemRoot\System32\tar.exe" -a -c -f $zip -C $staging AskBot
if ($LASTEXITCODE -ne 0) { throw "tar failed" }
Remove-Item -Recurse -Force $staging

Write-Host "Built $zip"

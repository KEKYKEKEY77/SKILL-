param(
  [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.codex\skills'),
  [string]$PluginCacheRoot = (Join-Path $env:USERPROFILE '.codex\plugins\cache'),
  [string]$LibraryRoot = (Join-Path $env:USERPROFILE '.skills-manager\skills')
)

$ErrorActionPreference = 'Stop'
$mappingPath = Join-Path $PSScriptRoot 'descriptions.json'
if (-not (Test-Path -LiteralPath $mappingPath)) { throw "找不到 descriptions.json" }
$descriptions = Get-Content -LiteralPath $mappingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$runFolder = Join-Path $PSScriptRoot ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $runFolder -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$changed = 0
$skipped = 0
$failures = New-Object System.Collections.Generic.List[string]

function Update-File([string]$path, [string]$kind, [string]$description) {
  $resolved = [IO.Path]::GetFullPath($path)
  if (-not $visited.Add($resolved)) { return }
  try {
    $bytes = [IO.File]::ReadAllBytes($resolved)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    $content = [Text.Encoding]::UTF8.GetString($bytes)
    if ($content.Length -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($kind -eq 'skill') {
      $front = [regex]::Match($content, '\A---\r?\n(?<head>.*?)\r?\n---', [Text.RegularExpressions.RegexOptions]::Singleline)
      if (-not $front.Success) { throw '缺少 YAML frontmatter' }
      $head = $front.Groups['head'].Value
      $pattern = '(?m)^description:[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*'
      if (-not [regex]::IsMatch($head, $pattern)) { throw '缺少 description' }
      $newHead = [regex]::Replace($head, $pattern, ('description: "' + $description + '"'), 1)
      $newHead = [regex]::Replace($newHead, '(?m)^(\s*short-description:\s*).+$', ('${1}"' + $description + '"'), 1)
      $updated = $content.Substring(0, $front.Groups['head'].Index) + $newHead + $content.Substring($front.Groups['head'].Index + $front.Groups['head'].Length)
    } else {
      if (-not [regex]::IsMatch($content, '(?m)^\s*short_description:')) { throw '缺少 short_description' }
      $updated = [regex]::Replace($content, '(?m)^(\s*short_description:\s*).+$', ('${1}"' + $description + '"'), 1)
    }
    if ($updated -eq $content) { return }
    $backup = Join-Path $runFolder (([string]$script:changed).PadLeft(4, '0') + '-' + [IO.Path]::GetFileName($resolved))
    [IO.File]::Copy($resolved, $backup, $true)
    $encoding = if ($hasBom) { $utf8Bom } else { $utf8 }
    [IO.File]::WriteAllText($resolved, $updated, $encoding)
    Add-Content -LiteralPath (Join-Path $runFolder 'files.tsv') -Value ($backup + "`t" + $resolved) -Encoding UTF8
    $script:changed++
  } catch {
    $script:failures.Add($resolved + ': ' + $_.Exception.Message)
  }
}

foreach ($root in @($SkillsRoot, $PluginCacheRoot, $LibraryRoot)) {
  if (-not (Test-Path -LiteralPath $root)) { continue }
  Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'SKILL.md' -ErrorAction SilentlyContinue | ForEach-Object {
    $skillDir = $_.DirectoryName
    $name = Split-Path $skillDir -Leaf
    $description = $descriptions.PSObject.Properties[$name].Value
    if (-not $description) { $script:skipped++; return }
    Update-File $_.FullName 'skill' $description
    $uiPath = Join-Path $skillDir 'agents\openai.yaml'
    if (Test-Path -LiteralPath $uiPath) { Update-File $uiPath 'ui' $description }
  }
}

Write-Host "完成：修改 $changed 个文件；未收录技能 $skipped 个；错误 $($failures.Count) 个。"
Write-Host "备份：$runFolder"
if ($failures.Count) {
  $failures | Set-Content -LiteralPath (Join-Path $runFolder 'errors.txt') -Encoding UTF8
  $failures | ForEach-Object { Write-Warning $_ }
  exit 1
}

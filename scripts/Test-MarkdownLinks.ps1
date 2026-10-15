<#
.SYNOPSIS
    Checks that every relative Markdown link in the repository points at a file or folder that exists, and that a
    #heading anchor exists in the target Markdown file.
.DESCRIPTION
    Offline: http(s), mailto and other schemes are skipped (CI checks those separately). Links inside code spans and
    fenced code blocks are ignored. VitePress links that start with / are resolved against docs/ (the site root).
    Exits 1 and lists every dead link when any is found.
.PARAMETER Root
    Repository root. Default: the folder above this script.
.EXAMPLE
    ./scripts/Test-MarkdownLinks.ps1
#>
#Requires -Version 7.4

[CmdletBinding()]
param(
    [string]$Root = (Join-Path -Path $PSScriptRoot -ChildPath '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootPath = (Resolve-Path -LiteralPath $Root).ProviderPath
$skip = '(^|[\\/])(node_modules|\.git|\.vitepress[\\/](dist|cache)|recordings)([\\/]|$)'
$files = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Filter '*.md' | Where-Object { $_.FullName.Substring($rootPath.Length) -notmatch $skip })

function Get-HeadingSlug {
    param([string]$Heading)
    $text = [regex]::Replace($Heading, '`([^`]*)`', '$1')
    $text = [regex]::Replace($text, '\[([^\]]*)\]\([^)]*\)', '$1')
    $text = $text.Trim().ToLowerInvariant()
    $text = [regex]::Replace($text, '[^\p{L}\p{N}\s\-_]', '')
    return ($text -replace '\s', '-')
}

$anchorCache = @{}
function Get-Anchor {
    param([string]$Path)
    if (-not $anchorCache.ContainsKey($Path)) {
        $set = [System.Collections.Generic.HashSet[string]]::new()
        $inFence = $false
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
            if ($inFence) { continue }
            if ($line -match '^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$') { $null = $set.Add((Get-HeadingSlug $Matches[1])) }
            foreach ($m in [regex]::Matches($line, '<a\s+(?:name|id)="([^"]+)"')) { $null = $set.Add($m.Groups[1].Value) }
        }
        $anchorCache[$Path] = $set
    }
    return $anchorCache[$Path]
}

$dead = [System.Collections.Generic.List[string]]::new()
$checked = 0
$pattern = '!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)'
foreach ($file in $files) {
    $dir = Split-Path -Path $file.FullName -Parent
    $relative = $file.FullName.Substring($rootPath.Length).TrimStart('\', '/')
    $inFence = $false
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNo++
        if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        $text = [regex]::Replace($line, '`[^`]*`', '')
        foreach ($m in [regex]::Matches($text, $pattern)) {
            $target = $m.Groups[1].Value
            if ($target -match '^[A-Za-z][A-Za-z0-9+.\-]*:' -or $target.StartsWith('//')) { continue }
            $checked++
            $pathPart = $target
            $anchor = ''
            $hash = $target.IndexOf('#')
            if ($hash -ge 0) { $pathPart = $target.Substring(0, $hash); $anchor = $target.Substring($hash + 1) }
            $pathPart = [uri]::UnescapeDataString($pathPart)
            if ($pathPart.Contains('?')) { $pathPart = $pathPart.Substring(0, $pathPart.IndexOf('?')) }
            $resolved = $file.FullName
            if ($pathPart) {
                $base = if ($pathPart.StartsWith('/')) { Join-Path $rootPath 'docs' } else { $dir }
                $candidate = [System.IO.Path]::GetFullPath((Join-Path $base $pathPart.TrimStart('/')))
                if (-not (Test-Path -LiteralPath $candidate)) {
                    # VitePress: a link without extension may be a page.
                    if (Test-Path -LiteralPath ($candidate + '.md')) { $candidate += '.md' }
                    elseif (Test-Path -LiteralPath (Join-Path $candidate 'index.md')) { $candidate = Join-Path $candidate 'index.md' }
                    else { $dead.Add("${relative}:${lineNo} -> $target (file not found)"); continue }
                }
                $resolved = $candidate
            }
            if ($anchor -and $resolved.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
                if (-not (Get-Anchor $resolved).Contains($anchor.ToLowerInvariant())) { $dead.Add("${relative}:${lineNo} -> $target (heading not found)") }
            }
        }
    }
}

"$($files.Count) Markdown file(s), $checked relative link(s) checked."
if ($dead.Count -gt 0) {
    $dead | ForEach-Object { "DEAD $_" }
    exit 1
}
'All relative links resolve.'

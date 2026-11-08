<#
.SYNOPSIS
    Single-Go-runtime check for Windows artifacts (bundle/package gate).

.DESCRIPTION
    netbird-embed ships its Go side as a c-shared library. Loading TWO Go runtimes
    into one process corrupts the Go GC (random crashes instead of a clean error),
    so this is enforced as a hard gate (plan-v3 §3.3 item 4 / §7 last acceptance).

    Detection, three layers of evidence (any hit => "this file carries Go runtime"):
      1) the `go1.` buildinfo string that every Go >= 1.12 binary embeds
      2) Go runtime names `runtime.` (survive stripping: they live in the pclntab)
      3) nm symbol table / objdump .gopclntab section (fallback)

    Rules:
      * 0 Go artifacts  -> pass (with -Strict it fails, to catch "scanned the wrong dir")
      * exactly 1       -> pass (optionally asserted with -ExpectName)
      * 2 or more       -> fail, exit 1

.EXAMPLE
    pwsh -File scripts/check-single-go-runtime.ps1

.EXAMPLE
    pwsh -File scripts/check-single-go-runtime.ps1 -ExpectName netbird_embed artifacts
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Paths = @(),

    [switch]$Strict,

    [string]$ExpectName,

    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)

function Write-Info([string]$Text) {
    if (-not $Quiet) { Write-Host $Text }
}

function Write-Bad([string]$Text) {
    Write-Host $Text -ForegroundColor Red
}

# Reads the whole file as Latin-1 text (1 byte == 1 char) and does an ordinal
# substring search. Peak memory ~2x file size; fine for a build-machine check.
function Test-ContainsText([string]$FilePath, [string]$Needle) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    } catch {
        return $false
    }
    $text = $Latin1.GetString($bytes)
    return ($text.IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0)
}

function Get-GoEvidence([string]$FilePath) {
    if (-not (Test-ContainsText $FilePath "go1.")) {
        return $null
    }
    if (Test-ContainsText $FilePath "runtime.") {
        return "go1.* + runtime.*"
    }

    $nm = Get-Command nm -ErrorAction SilentlyContinue
    if ($nm) {
        try {
            $symbols = & nm -a --defined-only $FilePath 2>$null
            if ($symbols -match 'runtime\.') { return "go1.* + nm runtime.*" }
        } catch {
            # nm on a PE file may not exist / may error; fall through
        }
    }

    $objdump = Get-Command objdump -ErrorAction SilentlyContinue
    if ($objdump) {
        try {
            $sections = & objdump -h $FilePath 2>$null
            if ($sections -match 'gopclntab|go\.buildinfo') { return "go1.* + .gopclntab/.go.buildinfo" }
        } catch {
            # ignore
        }
    }

    return $null
}

function Get-Candidates([string[]]$Roots) {
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($path in $Roots) {
        $resolved = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $Root $path }
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            $result.Add((Resolve-Path -LiteralPath $resolved).Path)
        } elseif (Test-Path -LiteralPath $resolved -PathType Container) {
            Get-ChildItem -LiteralPath $resolved -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @(".dll", ".so", ".dylib", ".exe", ".node") } |
                ForEach-Object { $result.Add($_.FullName) }
        } else {
            Write-Bad ("  !! path not found: " + $resolved)
        }
    }
    return $result
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1048576) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1024) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    return ("$Bytes B")
}

if ($Paths.Count -eq 0) {
    $defaults = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath (Join-Path $Root "artifacts")) { $defaults.Add((Join-Path $Root "artifacts")) }
    if (Test-Path -LiteralPath (Join-Path $Root "target")) { $defaults.Add((Join-Path $Root "target")) }
    if ($defaults.Count -eq 0) {
        Write-Bad "no artifacts/ and no target/: build first, or pass paths explicitly."
        exit 2
    }
    $Paths = $defaults.ToArray()
}

Write-Info ""
Write-Info "=== single Go runtime check ================================="
Write-Info ("  scanning: " + ($Paths -join ", "))

$hits = New-Object System.Collections.Generic.List[string]
foreach ($candidate in (Get-Candidates $Paths)) {
    $evidence = Get-GoEvidence $candidate
    if ($null -ne $evidence) {
        $size = (Get-Item -LiteralPath $candidate).Length
        $hits.Add($candidate)
        Write-Info ("  [GO]  " + $candidate.PadRight(58) + " " + (Format-Size $size).PadLeft(10) + "  " + $evidence)
    }
}

Write-Info ""
if ($hits.Count -eq 0) {
    Write-Bad "  !! no Go runtime found."
    Write-Bad "     If the build should contain one, you scanned the wrong directory."
    if ($Strict) { exit 1 }
    exit 0
}

if ($hits.Count -gt 1) {
    Write-Bad ("  !! $($hits.Count) Go runtimes found - two in one process corrupts the Go GC:")
    foreach ($hit in $hits) { Write-Bad ("       - " + $hit) }
    Write-Bad "     Fix: keep exactly one (normally netbird_embed.dll); split mesh into its own"
    Write-Bad "          process, or go back to a single statically linked copy (plan-v3 §3.3)."
    exit 1
}

if (-not [string]::IsNullOrEmpty($ExpectName)) {
    if ((Split-Path -Leaf $hits[0]) -like ("*" + $ExpectName + "*")) {
        Write-Info ("  OK: single Go runtime is " + $hits[0] + "  (matches -ExpectName " + $ExpectName + ")")
    } else {
        Write-Bad ("  !! single Go runtime is " + $hits[0] + " but -ExpectName requires " + $ExpectName)
        exit 1
    }
} else {
    Write-Info ("  OK: exactly one Go runtime - " + $hits[0])
}

exit 0

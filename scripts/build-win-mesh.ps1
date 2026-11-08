<#
.SYNOPSIS
    P0-A build + size report for the Windows mesh stack (netbird-embed -> Go c-shared -> Rust).

.DESCRIPTION
    Why this script exists (and why build.rs alone is not enough):

      * netbird-embed 0.3.1 ships a build.rs that runs
            go build -buildmode=c-shared -o <OUT_DIR>\netbird_embed.dll .
        with NO -ldflags="-s -w". The DLL it drops in OUT_DIR is therefore the
        fat one (~tens of MB of Go runtime + DWARF/symbols).
      * plan-v3 §5 requires a measured before/after number, per platform, plus
        artifacts/size-report.json with a budget verdict.

    So this script does BOTH builds from the same Go sources:

        A) plain            -> artifacts/netbird_embed.unstripped.dll
        B) -trimpath -s -w  -> artifacts/netbird_embed.dll          (the shippable one)

    then builds the Rust side (cargo) and records every artifact size.
    NOTE: the DLL that cargo links lives in target/.../build/netbird-embed-*/out/
    and is the *unstripped* one, because cargo cannot pass -ldflags to build.rs.
    Replacing that file with the stripped build is safe (strip only drops symbols,
    not code); see docs/p0/win-p0a-runbook.md "size alignment" for the exact step,
    and the permanent fix (vendor + patch build.rs).

.EXAMPLE
    pwsh -File scripts/build-win-mesh.ps1

.EXAMPLE
    pwsh -File scripts/build-win-mesh.ps1 -GoLib C:\src\netbird-embed\go-lib -SkipRust
#>
[CmdletBinding()]
param(
    # Path to netbird-embed's go-lib directory. Auto-discovered when omitted
    # (vendor/netbird-embed/go-lib, then ~/.cargo/registry/src/.../netbird-embed-0.3.1/go-lib).
    [string]$GoLib,

    # Where DLLs + size-report.json go.
    [string]$OutDir = "artifacts",

    # Skip the cargo build (Go-only size measurement).
    [switch]$SkipRust,

    # GOARCH for the Go build.
    [string]$GoArch = "amd64",

    # plan-v3 §5: total package budget that triggers the "split process / on-demand
    # download" strategy when exceeded.
    [int]$BudgetMb = 120,

    # Keep artifacts/go-build/ (the copied go-lib) for debugging.
    [switch]$KeepWorkdir
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Section([string]$Text) {
    Write-Host ""
    Write-Host ("=== " + $Text + " " + ("=" * [Math]::Max(0, 66 - $Text.Length))) -ForegroundColor Cyan
}

function Write-Step([string]$Text) {
    Write-Host ("  -> " + $Text)
}

function Write-Fail([string]$Text) {
    Write-Host ("  !! " + $Text) -ForegroundColor Red
}

function Get-FileBytes([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return (Get-Item -LiteralPath $Path).Length
}

function Format-Mb([long]$Bytes) {
    return ("{0:N2} MB" -f ($Bytes / 1MB))
}

function Get-LatestFile([string]$Root, [string]$Filter) {
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $items = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if (-not $items) { return $null }
    return $items[0]
}

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
$Root = Split-Path -Parent $PSScriptRoot
$OutPath = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $Root $OutDir }

Write-Section "P0-A build-win-mesh"
Write-Section "environment"
Write-Step ("powershell " + $PSVersionTable.PSVersion.ToString())
Write-Step ("repo root  " + $Root)

$goInfo = $null
$goOk = $false
try {
    $goInfo = ((& go version) 2>$null) -join " "
    # $LASTEXITCODE is only meaningful when the native call actually ran
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($goInfo)) { $goOk = $true }
} catch {
    $goOk = $false
}
if (-not $goOk) {
    Write-Fail "go not found in PATH. netbird-embed needs Go >= 1.25."
    Write-Fail "  winget install GoLang.Go   (or https://go.dev/dl/)"
    exit 2
}
Write-Step ("go          " + $goInfo)

$goMatch = [regex]::Match($goInfo, 'go(\d+)\.(\d+)')
if ($goMatch.Success) {
    $goMajor = [int]$goMatch.Groups[1].Value
    $goMinor = [int]$goMatch.Groups[2].Value
    if ($goMajor -lt 1 -or ($goMajor -eq 1 -and $goMinor -lt 25)) {
        Write-Fail ("go " + $goMajor + "." + $goMinor + " is too old; netbird-embed 0.3.1 requires >= 1.25")
        exit 2
    }
}

# cgo on Windows needs a real gcc (MSYS2 mingw64 or x86_64-w64-mingw32-gcc).
$gcc = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $gcc) {
    $gcc = Get-Command x86_64-w64-mingw32-gcc -ErrorAction SilentlyContinue
}
if (-not $gcc) {
    Write-Fail "gcc not found. Go c-shared on Windows needs MinGW-w64 (MSVC does not work for cgo)."
    Write-Fail "  MSYS2: pacman -S mingw-w64-x86_64-gcc   (then add C:\msys64\mingw64\bin to PATH)"
    exit 2
}
Write-Step ("gcc         " + $gcc.Source)

if (-not $SkipRust) {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) {
        Write-Fail "cargo not found (rustup toolchain 1.88 required by cordis-rs 0.11)."
        exit 2
    }
    Write-Step ("cargo       " + (& cargo --version))
}

# ---------------------------------------------------------------------------
# 1. locate netbird-embed go-lib
# ---------------------------------------------------------------------------
Write-Section "locate go-lib"

function Resolve-GoLib([string]$Explicit, [string]$RepoRoot) {
    if (-not [string]::IsNullOrEmpty($Explicit)) {
        $candidate = $Explicit
        if (-not (Test-Path -LiteralPath (Join-Path $candidate "go.mod"))) {
            throw ("-GoLib " + $Explicit + " does not contain go.mod")
        }
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    $vendored = Join-Path $RepoRoot "vendor\netbird-embed\go-lib"
    if (Test-Path -LiteralPath (Join-Path $vendored "go.mod")) {
        return (Resolve-Path -LiteralPath $vendored).Path
    }

    $registry = Join-Path $env:USERPROFILE ".cargo\registry\src"
    if (Test-Path -LiteralPath $registry) {
        $found = Get-ChildItem -LiteralPath $registry -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -Filter "netbird-embed-*" -ErrorAction SilentlyContinue } |
            Where-Object { $_.Name -eq "netbird-embed-0.3.1" } |
            ForEach-Object { Join-Path $_.FullName "go-lib" } |
            Where-Object { Test-Path -LiteralPath (Join-Path $_ "go.mod") }
        if ($found) {
            return (Resolve-Path -LiteralPath @($found)[0]).Path
        }
    }

    throw "go-lib not found. Pass -GoLib <path\to\netbird-embed-x.y.z\go-lib> (run 'cargo fetch' first)."
}

try {
    $GoLibPath = Resolve-GoLib $GoLib $Root
} catch {
    Write-Fail $_.Exception.Message
    exit 2
}
Write-Step ("go-lib      " + $GoLibPath)

# ---------------------------------------------------------------------------
# 2. copy go-lib into the workspace (never build inside the cargo registry:
#    go build may rewrite go.sum / download modules)
# ---------------------------------------------------------------------------
Write-Section "stage go sources"
if (-not (Test-Path -LiteralPath $OutPath)) {
    New-Item -ItemType Directory -Path $OutPath -Force | Out-Null
}
$WorkDir = Join-Path $OutPath "go-build"
if (Test-Path -LiteralPath $WorkDir) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
Copy-Item -LiteralPath $GoLibPath -Destination $WorkDir -Recurse -Force
Write-Step ("staged      " + $WorkDir)

$env:CGO_ENABLED = "1"
$env:GOOS = "windows"
$env:GOARCH = $GoArch

function Invoke-GoBuild([string]$WorkingDir, [string]$OutputFile, [string[]]$ExtraArg) {
    if ($null -eq $ExtraArg) { $ExtraArg = @() }   # @(...) + $null would append a null argv
    Push-Location -LiteralPath $WorkingDir
    try {
        $goArgs = @("build", "-buildmode=c-shared", "-trimpath") + $ExtraArg + @("-o", $OutputFile, ".")
        Write-Step ("go " + ($goArgs -join " "))
        & go @goArgs
        if ($LASTEXITCODE -ne 0) {
            throw ("go build failed (exit " + $LASTEXITCODE + ")")
        }
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# 3. build A: plain (what build.rs does today)
# ---------------------------------------------------------------------------
Write-Section "build A: plain (no strip) - this is what netbird-embed's build.rs produces"
$dllPlain = Join-Path $OutPath "netbird_embed.unstripped.dll"
try {
    Invoke-GoBuild $WorkDir $dllPlain @()
} catch {
    Write-Fail $_.Exception.Message
    Write-Fail "first run needs network: 'go mod download' pulls netbirdio/netbird."
    exit 2
}
$plainBytes = Get-FileBytes $dllPlain
Write-Step ("size        " + (Format-Mb $plainBytes))

# ---------------------------------------------------------------------------
# 4. build B: stripped (the shippable one)
# ---------------------------------------------------------------------------
Write-Section "build B: -ldflags=`"-s -w`" (shippable)"
$dllStripped = Join-Path $OutPath "netbird_embed.dll"
try {
    Invoke-GoBuild $WorkDir $dllStripped @("-ldflags=-s -w")
} catch {
    Write-Fail $_.Exception.Message
    exit 2
}
$strippedBytes = Get-FileBytes $dllStripped
$savedBytes = $plainBytes - $strippedBytes
$savedPercent = if ($plainBytes -gt 0) { [Math]::Round(100.0 * $savedBytes / $plainBytes, 1) } else { 0.0 }
Write-Step ("size        " + (Format-Mb $strippedBytes) + "   (saved " + (Format-Mb $savedBytes) + ", " + $savedPercent + "%)")

$header = Join-Path $OutPath "netbird_embed.h"
if (Test-Path -LiteralPath $header) {
    Write-Step ("header      " + $header)
}

# ---------------------------------------------------------------------------
# 5. rust side
# ---------------------------------------------------------------------------
$cargoDll = $null
$probeExe = $null
if (-not $SkipRust) {
    Write-Section "cargo build (release)"
    Push-Location -LiteralPath $Root
    try {
        Write-Step "cargo build --release -p crossdesk-mesh"
        & cargo build --release -p crossdesk-mesh
        if ($LASTEXITCODE -ne 0) { throw "cargo build -p crossdesk-mesh failed" }

        Write-Step "cargo build --release -p motif-probe --features mesh"
        & cargo build --release -p motif-probe --features mesh
        if ($LASTEXITCODE -ne 0) { throw "cargo build -p motif-probe failed" }
    } catch {
        Write-Fail $_.Exception.Message
        Write-Fail "go/gcc are fine (both Go builds above succeeded) - this is a Rust-side failure."
        exit 2
    } finally {
        Pop-Location
    }

    $cargoDll = Get-LatestFile (Join-Path $Root "target") "netbird_embed.dll"
    $probeExe = Get-LatestFile (Join-Path $Root "target") "motif-probe.exe"
}
$cargoDllBytes = if ($cargoDll) { $cargoDll.Length } else { 0 }
$probeExeBytes = if ($probeExe) { $probeExe.Length } else { 0 }

# ---------------------------------------------------------------------------
# 6. size report
# ---------------------------------------------------------------------------
Write-Section "size report"
$runtimeDllBytes = if ($cargoDllBytes -gt 0) { $cargoDllBytes } else { $strippedBytes }
$totalBytes = $runtimeDllBytes + $probeExeBytes
$totalMb = [Math]::Round($totalBytes / 1MB, 2)
$verdict = if ($totalMb -le $BudgetMb) { "OK" } else { "OVER_BUDGET" }

$report = [ordered]@{
    schema           = "crossdesk.size-report/1"
    generated_at     = (Get-Date).ToString("o")
    host             = [ordered]@{
        powershell = $PSVersionTable.PSVersion.ToString()
        go         = ($goInfo -join " ")
        gcc        = $gcc.Source
        goarch     = $GoArch
    }
    items            = [ordered]@{
        netbird_embed_dll_unstripped = [ordered]@{
            path  = $dllPlain
            bytes = $plainBytes
            mb    = [Math]::Round($plainBytes / 1MB, 2)
            note  = "what netbird-embed 0.3.1 build.rs produces (no -ldflags)"
        }
        netbird_embed_dll_stripped   = [ordered]@{
            path  = $dllStripped
            bytes = $strippedBytes
            mb    = [Math]::Round($strippedBytes / 1MB, 2)
            note  = "go build -ldflags=\"-s -w\" -trimpath; this is the shippable one"
        }
        strip_saving                 = [ordered]@{
            bytes   = $savedBytes
            mb      = [Math]::Round($savedBytes / 1MB, 2)
            percent = $savedPercent
        }
        cargo_linked_dll             = [ordered]@{
            path  = $(if ($cargoDll) { $cargoDll.FullName } else { "" })
            bytes = $cargoDllBytes
            mb    = [Math]::Round($cargoDllBytes / 1MB, 2)
            note  = "unstripped by design (cargo cannot pass -ldflags to build.rs); replace with netbird_embed_dll_stripped"
        }
        motif_probe_exe              = [ordered]@{
            path  = $(if ($probeExe) { $probeExe.FullName } else { "" })
            bytes = $probeExeBytes
            mb    = [Math]::Round($probeExeBytes / 1MB, 2)
            note  = "Rust: strip=symbols + lto=thin + codegen-units=1 already applied by [profile.release]"
        }
    }
    budget           = [ordered]@{
        budget_mb       = $BudgetMb
        measured_total_mb = $totalMb
        verdict         = $verdict
        note            = "plan-v3 §5: > budget triggers split-process / on-demand download"
    }
    next_steps       = @(
        "bash scripts/check-single-go-runtime.sh   # or pwsh -File scripts/check-single-go-runtime.ps1",
        "copy artifacts/netbird_embed.dll over the cargo-linked DLL (size alignment, runbook §4)",
        "target\release\motif-probe.exe --with-mesh --motif-target <overlay_ip:7777>"
    )
}

$reportPath = Join-Path $OutPath "size-report.json"
$report | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $reportPath -Encoding utf8
Write-Step ("report      " + $reportPath)

if (-not $KeepWorkdir -and (Test-Path -LiteralPath $WorkDir)) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 7. summary
# ---------------------------------------------------------------------------
Write-Section "summary"
Write-Host ("  netbird_embed.dll  plain       " + (Format-Mb $plainBytes))
Write-Host ("  netbird_embed.dll  stripped    " + (Format-Mb $strippedBytes) + "  (saved " + $savedPercent + "%)")
if ($cargoDllBytes -gt 0) {
    Write-Host ("  target-linked dll             " + (Format-Mb $cargoDllBytes) + "  <- replace with stripped build")
}
if ($probeExeBytes -gt 0) {
    Write-Host ("  motif-probe.exe               " + (Format-Mb $probeExeBytes))
}
Write-Host ("  package total (dll + exe)     " + $totalMb + " MB / budget " + $BudgetMb + " MB  -> " + $verdict) -ForegroundColor $(if ($verdict -eq "OK") { "Green" } else { "Yellow" })

Write-Host ""
Write-Host "Next: docs/p0/win-p0a-runbook.md" -ForegroundColor Cyan
Write-Host "  1. bash scripts/check-single-go-runtime.sh" -ForegroundColor Cyan
Write-Host "  2. .\target\release\motif-probe.exe --with-mesh --motif-target <overlay_ip:7777>" -ForegroundColor Cyan
Write-Host "  3. .\target\release\motif-probe.exe --proxy-port <port from step 2> --json-stdout" -ForegroundColor Cyan

if ($verdict -ne "OK") {
    exit 1
}
exit 0

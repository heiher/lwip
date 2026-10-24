# Native Windows x64 / x86 / ARM64 build via clang-cl; independent from the MSYS2 Makefile.
# PowerShell 5.1+: powershell -NoProfile -ExecutionPolicy Bypass -File .\build-msvc.ps1 -Target lib
# CMD shortcut: build-msvc.bat -Target lib -Arch x86 -VSVersion 2022
# Targets: lib (default), verify, clean.
# verify re-runs the static machine-type checks on the already-built library.
param(
    [ValidateSet('lib', 'verify', 'clean')]
    [string]$Target = 'lib',
    [ValidateSet('latest', '2026', '2022', '2019', '2017')]
    [string]$VSVersion = 'latest',
    [ValidateSet('x64', 'x86', 'arm64')]
    [string]$Arch = 'x64'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
# Preserve the established x64 output paths. Use separate folders for x86 and
# native ARM64 so no architecture ever overwrites another's artifacts.
$BuildDir = if ($Arch -eq 'x64') {
    Join-Path $Root 'build-msvc'
} elseif ($Arch -eq 'x86') {
    Join-Path $Root 'build-msvc\x86'
} else {
    Join-Path $Root 'build-msvc\arm64'
}
$ObjDir = Join-Path $BuildDir 'obj'
$LibPath = Join-Path $BuildDir 'lwip.lib'
$MachineType = if ($Arch -eq 'x64') { '8664' } elseif ($Arch -eq 'x86') { '14C' } else { 'AA64' }

function Invoke-Native([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable failed with exit code $LASTEXITCODE"
    }
}

function Get-PeMachineTypes([string]$Path) {
    # Every COFF member of a library declares its machine type in its file
    # header. Cross-compilation mistakes (ARM64EC sneaking in, stale x64
    # objects reused) show up here.
    $out = & dumpbin.exe /nologo /headers $Path
    @($out | Where-Object { $_ -match '^\s*([0-9A-Fa-f]+) machine' } | ForEach-Object { $Matches[1].ToUpper() })
}

function Assert-PeMachine([string]$Path, [string]$Expected) {
    $machines = Get-PeMachineTypes $Path
    if ($machines.Count -eq 0) { throw "No machine type found in $Path" }
    $bad = @($machines | Where-Object { $_ -ne $Expected })
    if ($bad.Count -gt 0) {
        throw "$Path contains unexpected machine types ($($bad -join ', ')); expected $Expected only."
    }
}

function Initialize-MSVC {
    # A pre-configured matching-architecture Native Tools prompt is supported.
    $clang = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
    $lib = Get-Command lib.exe -ErrorAction SilentlyContinue
    $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($VSVersion -eq 'latest' -and $clang -and $lib -and $dumpbin -and
        $env:VSCMD_ARG_TGT_ARCH -eq $Arch) { return }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw 'vswhere.exe not found. Install Visual Studio / Build Tools with Desktop development with C++.'
    }
    $versionRanges = @{
        '2017' = '[15.0,16.0)'
        '2019' = '[16.0,17.0)'
        '2022' = '[17.0,18.0)'
        '2026' = '[18.0,19.0)'
    }
    $vsargs = @('-latest', '-products', '*', '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath')
    if ($VSVersion -ne 'latest') { $vsargs += @('-version', $versionRanges[$VSVersion]) }
    $install = & $vswhere @vsargs
    if ($LASTEXITCODE -ne 0 -or -not $install) {
        throw "Visual Studio $VSVersion with MSVC $Arch tools not found."
    }
    $vcvars = Join-Path $install 'VC\Auxiliary\Build\vcvarsall.bat'
    if (-not (Test-Path -LiteralPath $vcvars)) { throw "Missing vcvarsall.bat: $vcvars" }

    # vcvarsall argument for the requested target. ARM64 is native when the
    # host CPU is ARM64, otherwise x64_arm64 performs genuine (non-ARM64EC)
    # cross compilation of native ARM64 objects.
    $vcvarsArg = if ($Arch -eq 'arm64') {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64_arm64' }
    } else {
        $Arch
    }

    Write-Host "Loading MSVC $Arch environment: $vcvars $vcvarsArg"
    # Avoid cmd.exe /s /c quoting ambiguities with paths such as "Program Files".
    # PowerShell invokes the generated .cmd directly, then imports its environment.
    $tempBase = Join-Path ([IO.Path]::GetTempPath()) ("lwip-msvc-env-{0}" -f [guid]::NewGuid().ToString('N'))
    $tempBatch = "$tempBase.cmd"
    $tempLog = "$tempBase.log"
    $batchLines = @(
        '@echo off',
        ('call "' + $vcvars + '" ' + $vcvarsArg + ' > "' + $tempLog + '" 2>&1'),
        'if errorlevel 1 (',
        ('    type "' + $tempLog + '"'),
        '    exit /b 1',
        ')',
        'set'
    )
    try {
        Set-Content -LiteralPath $tempBatch -Value $batchLines -Encoding Default
        $lines = & $tempBatch
        if ($LASTEXITCODE -ne 0) { throw "vcvarsall.bat failed (exit code $LASTEXITCODE)." }
    } finally {
        foreach ($temporary in @($tempBatch, $tempLog)) {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
        }
    }
    foreach ($line in $lines) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    if ($env:VSCMD_ARG_TGT_ARCH -ne $Arch) { throw "Expected MSVC $Arch target environment." }
    foreach ($name in @('clang-cl.exe', 'lib.exe', 'dumpbin.exe')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "$name not found in MSVC environment." }
    }
    Assert-CompilerTarget
}

function Assert-CompilerTarget {
    # vcvarsall succeeds even when the requested target toolset is not
    # installed (the matching bin directory is then simply absent from PATH
    # and cl.exe silently falls back to another host/target). Compile a
    # probe and require the object machine type to match before any real
    # sources are built.
    $tempBase = Join-Path ([IO.Path]::GetTempPath()) ('lwip-msvc-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath "$tempBase.c" -Encoding Ascii -Value 'int lwip_msvc_probe(void){return 0;}'
        Invoke-Native 'clang-cl.exe' (@('/nologo', '/c', "/Fo$tempBase.obj", "$tempBase.c"))
        $machines = Get-PeMachineTypes "$tempBase.obj"
        if (($machines | Where-Object { $_ -ne $MachineType }).Count -gt 0) {
            throw ("cl.exe produced machine type(s) {0} instead of {1}. " +
                "The MSVC {2} target toolset appears to be missing or misconfigured.") -f
                ($machines -join ', '), $MachineType, $Arch
        }
    } finally {
        Remove-Item "$tempBase*" -Force -ErrorAction SilentlyContinue
    }
}

$CommonDefines = @(
    '/D_CRT_SECURE_NO_WARNINGS',
    '/D_CRT_NONSTDC_NO_WARNINGS',
    '/D_WINSOCK_DEPRECATED_NO_WARNINGS'
)
$Includes = @(
    "/I$Root\src\include", "/I$Root\src\ports\include"
)
$Cflags = @(
    '/nologo', '/std:c11', '/O2', '/W3', '/MD',
    "--target=$(if ($Arch -eq 'x64') { 'x86_64-pc-windows-msvc' } elseif ($Arch -eq 'x86') { 'i686-pc-windows-msvc' } else { 'aarch64-pc-windows-msvc' })",
    '-Wno-unused-command-line-argument'
) + $Includes + $CommonDefines

function Build-Library {
    # A fresh object directory prevents an accidentally partial archive.
    if (Test-Path -LiteralPath $ObjDir) { Remove-Item -Recurse -Force -LiteralPath $ObjDir }
    if (Test-Path -LiteralPath $LibPath) { Remove-Item -Force -LiteralPath $LibPath }
    New-Item -ItemType Directory -Force -Path $ObjDir | Out-Null

    # The whole tree compiles on Windows as-is: the unix port sources and
    # headers are empty shells under _WIN32, and the win32 port (sys_arch,
    # sio, mem override) activates instead, matching the MSYS2 Makefile that
    # also wildcards every source under src/.
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $Root 'src') -Recurse -File -Filter '*.c' |
        Sort-Object FullName)
    $objects = @()
    foreach ($src in $sources) {
        $rel = $src.FullName.Substring($Root.Length + 1) -replace '[\\/]', '_'
        $obj = Join-Path $ObjDir ($rel + '.obj')
        Write-Host "  CC  $rel"
        Invoke-Native 'clang-cl.exe' ($Cflags + @('/c', "/Fo$obj", $src.FullName))
        $objects += $obj
    }

    Write-Host '  LIB lwip.lib'
    Invoke-Native 'lib.exe' (@('/nologo', "/OUT:$LibPath") + $objects)
}

function Invoke-Verify {
    if (-not (Test-Path -LiteralPath $LibPath)) { throw 'Missing static library for verification.' }
    Assert-PeMachine $LibPath $MachineType
    Write-Host "  CHECK machine types in lwip.lib ($MachineType)"
}

switch ($Target) {
    'lib' {
        Initialize-MSVC
        Build-Library
        Invoke-Verify
    }
    'verify' {
        Initialize-MSVC
        Invoke-Verify
    }
    'clean' {
        if (Test-Path -LiteralPath $BuildDir) {
            Remove-Item -Recurse -Force -LiteralPath $BuildDir
        }
        Write-Host "CLEAN $BuildDir"
    }
}

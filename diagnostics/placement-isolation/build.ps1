<#
.SYNOPSIS
Build, verify on WARP, and package the standalone Xbox D3D12 isolation app.
.DESCRIPTION
Requires an x64 VS 2022 developer shell, Windows SDK tools and C++ UWP support.
Engine is a patched source checkout; only its SDK-only isolation core is built.
#>
param(
    [Parameter(Mandatory = $true)][string]$Engine,
    [string]$Output = "build/placement-isolation"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$Repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$Engine = (Resolve-Path $Engine).Path
$Output = [IO.Path]::GetFullPath($Output)
$Core = Join-Path $Engine "src/hardware/r_d3d12/isolation"
$Generated = Join-Path $Output "generated"
$Shaders = Join-Path $Generated "isolation_shaders"
$Logs = Join-Path $Output "logs"
$Install = Join-Path $Output "install"
$Stage = Join-Path $Output "package-stage"

if ($env:VSCMD_ARG_TGT_ARCH -ne 'x64') { throw "Use an x64 Visual Studio 2022 developer shell." }
foreach ($Tool in 'cl.exe', 'fxc.exe', 'msbuild.exe', 'MakeAppx.exe', 'MakePri.exe', 'SignTool.exe') {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) { throw "Required Windows build tool missing: $Tool" }
}
foreach ($File in 'isolation.h', 'isolation.cpp', 'observe.hlsl') {
    if (-not (Test-Path (Join-Path $Core $File))) { throw "Patched isolation source missing: $Core/$File" }
}
foreach ($Directory in $Output, $Shaders, $Logs, $Install, $Stage) {
    New-Item -ItemType Directory -Force $Directory | Out-Null
}
# This is a generated package staging directory, never the engine checkout.
Get-ChildItem $Stage -Force | Remove-Item -Recurse -Force

function Exec([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Command" }
}

foreach ($Entry in 'ObserveBytes', 'ObserveUInt') {
    Exec { fxc.exe /nologo /O3 /T cs_5_0 /E $Entry /Vn "g_$Entry" /Fh (Join-Path $Shaders "$Entry.h") (Join-Path $Core 'observe.hlsl') }
}

$Console = Join-Path $Output 'placement-isolation.exe'
Push-Location $Output
try {
    Exec {
        cl.exe /nologo /std:c++17 /O2 /EHsc /W4 /MD /DWIN32_LEAN_AND_MEAN /DNOMINMAX `
            "/I$Core" "/I$Generated" (Join-Path $PSScriptRoot 'console.cpp') (Join-Path $Core 'isolation.cpp') `
            "/Fe:$Console" /link d3d12.lib dxgi.lib dxguid.lib
    }
} finally { Pop-Location }

function RunProbe([string]$Name, [string[]]$Arguments, [int]$ExpectedExit) {
    $Log = Join-Path $Logs "$Name.txt"
    Write-Host "Running $Name; complete observations: $Log"
    & $Console @Arguments *> $Log
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne $ExpectedExit) { throw "$Name failed or crashed: expected exit $ExpectedExit, got $ExitCode; see $Log" }
    $Lines = @(Get-Content $Log)
    $Summary = @($Lines | Where-Object { $_ -match '^HOST_RESULT ' })
    if ($Summary.Count -ne 1) { throw "$Name did not complete exactly one suite." }
    Write-Host $Summary[0]
    if ($Summary[0] -notmatch 'selfTestsFailed=0 deviceFailed=0 debugErrors=0$') { throw "$Name reported a validation/device/oracle error." }
    if ($Summary[0] -notmatch 'cases=([1-9][0-9]*) ') { throw "$Name ran no cases." }
    $Begins = @($Lines | Where-Object { $_ -match '^RRDIAG BEGIN ' })
    $CoreSummaries = @($Lines | Where-Object { $_ -match '^SUMMARY ' })
    if ($Begins.Count -ne 1 -or $CoreSummaries.Count -ne 1) { throw "$Name is missing unique core begin/end markers." }
    if ($CoreSummaries[0] -notmatch '^SUMMARY (cases=[0-9]+ mismatches=[0-9]+ unavailable=[0-9]+ selfTestsFailed=[0-9]+ deviceFailed=[01] debugErrors=[01])(?: |$)' -or
        $Summary[0] -cne "HOST_RESULT $($Matches[1])") { throw "$Name core/host summaries disagree." }
    if (-not ($Lines | Where-Object { $_ -match 'SETTINGS debugRequested=1 debugApplied=1 gbvRequested=1 gbvApplied=1 dredRequested=[01] dredApplied=1 configuredBeforeDevice=1' })) {
        throw "$Name did not actually enable the required SDK debug layer, GPU validation and DRED configuration."
    }
    return ,$Lines
}

function VerifyHealthy([string]$Name, [string[]]$Lines) {
    $Summary = @($Lines | Where-Object { $_ -match '^HOST_RESULT ' })[0]
    if ($Summary -notmatch 'mismatches=0 ') { throw "$Name detected a memory mismatch." }
    $Coverage = @{}
    $Current = $null
    $Phases = @{}
    $Endpoints = @{}
    $Controls = @{}
    $SelfTest = $false
    $Ends = 0
    $Starts = 0
    foreach ($Line in $Lines) {
        if ($Line -match '^CASE ') {
            ++$Starts
            $Current = $null
            $Phases = @{}
            $Endpoints = @{}
            $Controls = @{}
            $SelfTest = $false
            if ($Line -match '\bcoverage=primary observer=(shader|copy|toggle) layout=(adjacent|gap4096|committed) width=(64|256) format=RGBA8 state=(COMMON|COPY_DEST|COPY_SOURCE|PIXEL_SHADER_RESOURCE) order=sentinel-first repetition=([12])\b') {
                $Current = "$($Matches[2])/$($Matches[3])/$($Matches[1])/$($Matches[4])/$($Matches[5])"
            }
        }
        if ($Line -match '^SELF_TEST name=(shader-pack-and-baseline|copy-baseline) result=pass knownPatterns=asymmetric,all-zero,all-255$') {
            $SelfTest = $true
        }
        if ($Line -match '^OBSERVE_ENDPOINTS target=(sentinel|owner) phase=([^ ]+) firstExpected=([0-9a-f]{8}) firstA=([0-9a-f]{8}) firstB=([0-9a-f]{8}) lastIndex=([0-9]+) lastExpected=([0-9a-f]{8}) lastA=([0-9a-f]{8}) lastB=([0-9a-f]{8})$') {
            if ($Matches[3] -cne $Matches[4] -or $Matches[3] -cne $Matches[5] -or $Matches[7] -cne $Matches[8] -or $Matches[7] -cne $Matches[9]) {
                throw "$Name first/last logical texel differs: $Line"
            }
            $Endpoints["$($Matches[1])/$($Matches[2])"] = $true
        }
        if ($Line -match '\bRAW_CONTROL target=(sentinel|owner) exact=pass padded=pass remap=pass uploadCPU=pass guard=pass\b') {
            $Controls[$Matches[1]] = $true
        }
        if ($Line -match '\bCASE_END\b') {
            ++$Ends
            if ($Line -match 'mismatch=0 unavailable=0' -and $Current) {
                foreach ($Required in @(
                    'sentinel/baseline-repeat', 'sentinel/owner-CPU-create-before-activation',
                    'sentinel/owner-alias-activation', 'sentinel/owner-transition-COPY_DEST-no-upload',
                    'sentinel/owner-upload', 'sentinel/owner-transition-COPY_SOURCE-no-copy',
                    'owner/owner-readback-exact-and-padded', 'sentinel/owner-readback',
                    'sentinel/owner-transition-PIXEL_SHADER_RESOURCE', 'sentinel/owner-transition-NON_PIXEL_SHADER_RESOURCE',
                    'owner/owner-shader-load', 'sentinel/owner-shader-load', 'sentinel/owner-release-after-fence',
                    'sentinel/owner-recreate-before-activation', 'sentinel/owner-recreate-alias-activation')) {
                    if (-not $Phases.ContainsKey($Required) -or -not $Endpoints.ContainsKey($Required)) {
                        throw "$Name primary case $Current missing full observation/endpoints $Required"
                    }
                }
                if (-not ($Phases.ContainsKey('sentinel/baseline-no-owner') -or $Phases.ContainsKey('sentinel/baseline-owner-already-exists')) -or
                    -not $Controls.ContainsKey('sentinel') -or -not $Controls.ContainsKey('owner') -or -not $SelfTest) {
                    throw "$Name primary case $Current lacks its baseline or both raw controls."
                }
                $Coverage[$Current] = $true
            }
            $Current = $null
        }
        if ($Line -match '\bOBSERVE target=') {
            if ($Line -notmatch '\bchanged=0\b' -or $Line -notmatch '\boutputsEqual=1\b' -or $Line -notmatch '\bremapEqual=1\b' -or
                $Line -notmatch '\bprefixTailChanges=0,0\b') {
                throw "$Name observer/control disagreement: $Line"
            }
            if ($Line -match '\bOBSERVE target=(sentinel|owner) phase=([^ ]+)') { $Phases["$($Matches[1])/$($Matches[2])"] = $true }
            if ($Line -match '\bmethod=shader\b' -and $Line -notmatch 'sourceBefore=NON_PIXEL_SHADER_RESOURCE sourceAfter=NON_PIXEL_SHADER_RESOURCE') {
                throw "$Name shader observation changed its source state: $Line"
            }
        }
    }
    # One complete healthy baseline for every requested layout and observer is mandatory.
    foreach ($Tuple in 'adjacent/64', 'adjacent/256', 'gap4096/64', 'gap4096/256', 'committed/256') {
        foreach ($Observer in 'shader', 'copy', 'toggle') {
            foreach ($State in 'COMMON', 'COPY_DEST', 'COPY_SOURCE', 'PIXEL_SHADER_RESOURCE') {
                foreach ($Repeat in 1, 2) {
                    if (-not $Coverage.ContainsKey("$Tuple/$Observer/$State/$Repeat")) {
                        throw "$Name missing healthy primary baseline $Tuple/$Observer/$State/$Repeat"
                    }
                }
            }
        }
    }
    foreach ($Target in 'sentinel', 'owner') {
        if (-not ($Lines | Where-Object { $_ -match "RAW_CONTROL target=$Target exact=pass padded=pass remap=pass" })) {
            throw "$Name missing independently mapped exact/padded $Target raw control."
        }
    }
    $ExpectedCases = [int]([regex]::Match($Summary, '\bcases=([0-9]+)\b').Groups[1].Value)
    $Matrices = @($Lines | Where-Object { $_ -match '^MATRIX ' })
    if ($Matrices.Count -ne 1 -or $Matrices[0] -notmatch 'repeats=2 primaryLayouts=5 primaryObservers=3 primaryInitialStates=4') {
        throw "$Name did not run the complete repeated matrix."
    }
    $ProjectedCases = [int]([regex]::Match($Matrices[0], '\bprojectedCases=([0-9]+)\b').Groups[1].Value)
    if ($Starts -ne $Ends -or $Ends -ne $ExpectedCases -or $Ends -ne $ProjectedCases -or $Ends -lt 204) {
        throw "$Name case begin/end/result counts disagree."
    }
    Write-Host "Verified ${Name}: all 15 primary layout/observer baselines across four states and two repeats, independent raw controls and matching observations. Optional unavailable cases remain visible in the log."
}

foreach ($Dred in 'off', 'on') {
    $Name = "warp-dred-$Dred"
    $Lines = RunProbe $Name @('--warp', '--debug', '--gpu-validation', "--dred-$Dred") 0
    VerifyHealthy $Name $Lines
}
foreach ($Target in 'sentinel', 'owner') {
    $Name = "negative-$Target"
    $Lines = RunProbe $Name @('--warp', '--debug', '--gpu-validation', '--dred-on', '--quick', '--repeats', '1', "--negative-$Target") 2
    if (-not ($Lines | Where-Object { $_ -ceq "NEGATIVE_ORACLE_REJECTED:isolation-$Target" })) {
        throw "$Name did not reject real GPU corruption of the requested target."
    }
    if (-not ($Lines | Where-Object { $_ -match '\bINJECTION target=.*\brealGPUWrite=1\b' }) -or
        -not ($Lines | Where-Object { $_ -match "OBSERVE target=$Target .*\bchanged=[1-9][0-9]*\b" })) {
        throw "$Name lacks the GPU injection or changed-target observation."
    }
    $Other = if ($Target -eq 'sentinel') { 'owner' } else { 'sentinel' }
    if ($Lines | Where-Object { $_ -match "OBSERVE target=$Other .*\bchanged=[1-9][0-9]*\b" }) {
        throw "$Name also corrupted the wrong target."
    }
}

# Compile only the same core plus the tiny CoreApplication host, never the game.
$Sdk = $env:WindowsSDKVersion.TrimEnd('\')
if (-not $Sdk) { throw "The developer shell did not select a Windows SDK." }
Exec {
    msbuild.exe (Join-Path $PSScriptRoot 'Isolation.vcxproj') /m /nologo /p:Configuration=Release /p:Platform=x64 `
        "/p:EngineRoot=$Engine" "/p:ShaderIncludeRoot=$Generated" "/p:IsolationOutput=$Output" "/p:WindowsTargetPlatformVersion=$Sdk"
}

$ManifestPath = Join-Path $PSScriptRoot 'Package.appxmanifest'
[xml]$Manifest = Get-Content $ManifestPath
if ($Manifest.Package.Identity.Name -cne 'RingRacersD3D12Isolation' -or
    $Manifest.Package.Identity.Publisher -cne 'CN=danwo' -or
    $Manifest.Package.Applications.Application.EntryPoint -cne 'RingRacersD3D12Isolation.Source') {
    throw 'Isolation manifest identity/entrypoint changed unexpectedly.'
}
Copy-Item $ManifestPath (Join-Path $Stage 'AppxManifest.xml') -Force
Copy-Item (Join-Path $Output 'uwp/RingRacersD3D12Isolation.exe') $Stage -Force
Get-ChildItem (Join-Path $Output 'uwp') -Filter '*.winmd' | Copy-Item -Destination $Stage -Force
New-Item -ItemType Directory -Force (Join-Path $Stage 'Assets'), (Join-Path $Stage 'Licenses') | Out-Null
# Original repository artwork; no game assets or runtime libraries are packaged.
Copy-Item (Join-Path $Repo 'uwp/Assets/StoreLogo.png') (Join-Path $Stage 'Assets/StoreLogo.png') -Force
Copy-Item (Join-Path $Repo 'uwp/Assets/Square150x150Logo.scale-200.png') (Join-Path $Stage 'Assets/Square150x150Logo.scale-200.png') -Force
Copy-Item (Join-Path $Repo 'uwp/Assets/Square44x44Logo.scale-200.png') (Join-Path $Stage 'Assets/Square44x44Logo.scale-200.png') -Force
$License = @('COPYING', 'LICENSE', 'LICENSE.txt') | ForEach-Object { Join-Path $Engine $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $License) { throw 'The patched upstream source has no GPL license file.' }
Copy-Item $License (Join-Path $Stage 'Licenses/GPL.txt') -Force
@'
Ring Racers D3D12 isolation diagnostics: GPL-2.0-or-later.
Source: https://github.com/ZebulanStanphill/ringracers-uwp
SDK-only core source is included in patches/ringracers-uwp.patch.
The package reuses the original UWP wrapper icons from uwp/Assets.
The wrapper is based on https://github.com/worleydl/ringracers-uwp
Upstream Ring Racers: https://github.com/KartKrewDev/RingRacers
'@ | Set-Content -Encoding utf8 (Join-Path $Stage 'Licenses/NOTICE.txt')

$VCLibsRoot = Join-Path $env:VSINSTALLDIR 'SDKs/Microsoft.VCLibs/14.0/Appx/Retail/x64'
$VCLibs = @(Get-ChildItem $VCLibsRoot -Filter 'Microsoft.VCLibs.x64.14.00.appx' -ErrorAction Stop)
if ($VCLibs.Count -ne 1) { throw 'The x64 UWP VCLibs dependency was not found in Visual Studio.' }
New-Item -ItemType Directory -Force (Join-Path $Install 'Dependencies/x64') | Out-Null
Copy-Item $VCLibs[0].FullName (Join-Path $Install 'Dependencies/x64') -Force

$Package = Join-Path $Install 'RingRacersD3D12Isolation_1.0.0.0_x64.msix'
$PriConfig = Join-Path $Output 'priconfig.xml'
Exec { MakePri.exe createconfig /o /cf $PriConfig /dq en-US }
[xml]$PriXml = Get-Content $PriConfig
# One installable package: retain the images' scale qualifiers without splitting resource packs.
foreach ($Packaging in @($PriXml.SelectNodes("//*[local-name()='packaging']"))) {
    $Packaging.ParentNode.RemoveChild($Packaging) | Out-Null
}
$PriXml.Save($PriConfig)
Exec { MakePri.exe new /o /pr $Stage /cf $PriConfig /mn (Join-Path $Stage 'AppxManifest.xml') /of (Join-Path $Stage 'resources.pri') }
Exec { MakeAppx.exe pack /o /d $Stage /p $Package }
$Cert = New-SelfSignedCertificate -Type Custom -Subject 'CN=danwo' -KeyUsage DigitalSignature `
    -FriendlyName 'Ring Racers D3D12 Isolation CI' -CertStoreLocation 'Cert:\CurrentUser\My' `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
$Pfx = Join-Path $Output 'isolation-ci.pfx'
try {
    Export-PfxCertificate -Cert $Cert -FilePath $Pfx -Password (ConvertTo-SecureString 'ci' -AsPlainText -Force) | Out-Null
    Export-Certificate -Cert $Cert -FilePath (Join-Path $Install 'RingRacersD3D12Isolation.cer') | Out-Null
    Exec { SignTool.exe sign /fd SHA256 /f $Pfx /p ci $Package }
} finally {
    Remove-Item $Pfx -Force -ErrorAction SilentlyContinue
    Remove-Item "Cert:\CurrentUser\My\$($Cert.Thumbprint)" -ErrorAction SilentlyContinue
}

$Archive = [IO.Compression.ZipFile]::OpenRead($Package)
try {
    foreach ($Required in 'AppxManifest.xml', 'AppxSignature.p7x', 'RingRacersD3D12Isolation.exe', 'resources.pri', 'Licenses/GPL.txt', 'Licenses/NOTICE.txt') {
        if (-not $Archive.GetEntry($Required)) { throw "Install package is missing $Required" }
    }
    if ($Archive.Entries | Where-Object { $_.Name -match '^(SDL|libEGL|libGLES|ringracers)\.(dll|lib)$' }) {
        throw 'Standalone package unexpectedly contains a game/runtime dependency.'
    }
} finally { $Archive.Dispose() }
Copy-Item (Join-Path $PSScriptRoot 'README.md') (Join-Path $Install 'README.md') -Force
Write-Host "Verified WARP logs: $Logs"
Write-Host "Installable standalone Xbox package: $Install"

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
foreach ($File in 'isolation.h', 'isolation.cpp', 'minimal_repro.cpp', 'observe.hlsl') {
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

function Find-VCLibsDependency([string[]]$SdkRoots) {
    $ExpectedName = 'Microsoft.VCLibs.140.00'
    $ExpectedPublisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    $Attempted = @()
    foreach ($Root in @($SdkRoots | Where-Object { $_ } | Select-Object -Unique)) {
        # ExtensionSdkDir may name either the extension collection or this SDK.
        $ManifestPath = Join-Path $Root 'Microsoft.VCLibs/14.0/SDKManifest.xml'
        $DirectManifest = Join-Path $Root 'SDKManifest.xml'
        if (Test-Path -LiteralPath $DirectManifest -PathType Leaf) { $ManifestPath = $DirectManifest }
        $Attempted += $ManifestPath
        if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { continue }

        [xml]$SdkManifest = Get-Content -LiteralPath $ManifestPath -Raw
        $Sdk = $SdkManifest.DocumentElement
        $FrameworkIdentity = ''
        foreach ($Attribute in 'FrameworkIdentity-Retail-x64', 'FrameworkIdentity-Retail', 'FrameworkIdentity') {
            $FrameworkIdentity = $Sdk.GetAttribute($Attribute)
            if ($FrameworkIdentity) { break }
        }
        $PublisherPattern = [regex]::Escape($ExpectedPublisher)
        if ($FrameworkIdentity -notmatch '(?:^|,)\s*Name\s*=\s*Microsoft\.VCLibs\.140\.00\s*(?:,|$)' -or
            $FrameworkIdentity -notmatch "Publisher\s*=\s*['`"]?$PublisherPattern['`"]?\s*$") {
            throw "SDK manifest does not identify the UWP VCLibs framework: $ManifestPath"
        }
        $MinimumVersionMatch = [regex]::Match($FrameworkIdentity, '(?:^|,)\s*MinVersion\s*=\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\s*(?:,|$)')
        if (-not $MinimumVersionMatch.Success) { throw "SDK manifest is missing the framework minimum version: $ManifestPath" }
        $MinimumVersion = [version]$MinimumVersionMatch.Groups[1].Value
        $RelativePackage = $Sdk.GetAttribute('AppX-Retail-x64')
        if (-not $RelativePackage -or [IO.Path]::IsPathRooted($RelativePackage)) {
            throw "SDK manifest is missing a relative AppX-Retail-x64 path: $ManifestPath"
        }
        $SdkDirectory = [IO.Path]::GetFullPath((Split-Path $ManifestPath))
        $RelativePackage = $RelativePackage.Replace('\', [IO.Path]::DirectorySeparatorChar).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $PackagePath = [IO.Path]::GetFullPath((Join-Path $SdkDirectory $RelativePackage))
        $SdkPrefix = $SdkDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $PackagePath.StartsWith($SdkPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
            throw "SDK x64 retail package is missing or outside its SDK directory: $PackagePath"
        }

        $DependencyArchive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
        try {
            $Entry = $DependencyArchive.GetEntry('AppxManifest.xml')
            if (-not $Entry -or -not $DependencyArchive.GetEntry('AppxSignature.p7x')) {
                throw "VCLibs package is missing its manifest or signature: $PackagePath"
            }
            $Reader = [IO.StreamReader]::new($Entry.Open())
            try { [xml]$DependencyManifest = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
            $Identity = $DependencyManifest.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
            $Framework = $DependencyManifest.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Properties']/*[local-name()='Framework']")
            $Universal = $DependencyManifest.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Dependencies']/*[local-name()='TargetDeviceFamily'][@Name='Windows.Universal']")
            if (-not $Identity -or $Identity.GetAttribute('Name') -cne $ExpectedName -or
                $Identity.GetAttribute('Publisher') -cne $ExpectedPublisher -or $Identity.GetAttribute('ProcessorArchitecture') -cne 'x64' -or
                [version]$Identity.GetAttribute('Version') -lt $MinimumVersion -or
                -not $Framework -or $Framework.InnerText.Trim() -ine 'true' -or -not $Universal) {
                throw "SDK package is not the expected x64 UWP VCLibs framework: $PackagePath"
            }
        } finally { $DependencyArchive.Dispose() }
        Write-Host "Validated x64 UWP VCLibs dependency from $ManifestPath"
        return $PackagePath
    }
    throw "The x64 UWP VCLibs SDK was not found. Checked: $($Attempted -join '; ')"
}

foreach ($Entry in 'ObserveBytes', 'ObserveUInt') {
    Exec { fxc.exe /nologo /O3 /T cs_5_0 /E $Entry /Vn "g_$Entry" /Fh (Join-Path $Shaders "$Entry.h") (Join-Path $Core 'observe.hlsl') }
}

$Console = Join-Path $Output 'placement-isolation.exe'
Push-Location $Output
try {
    Exec {
        cl.exe /nologo /std:c++17 /O2 /Zi /EHsc /W4 /MD /DWIN32_LEAN_AND_MEAN /DNOMINMAX `
            "/I$Core" "/I$Generated" (Join-Path $PSScriptRoot 'console.cpp') (Join-Path $Core 'isolation.cpp') (Join-Path $Core 'minimal_repro.cpp') `
            "/Fe:$Console" /link /DEBUG:FULL "/PDB:$(Join-Path $Output 'placement-isolation.pdb')" d3d12.lib dxgi.lib dxguid.lib
    }
} finally { Pop-Location }

# Runs the legacy 408-case matrix (only used for its injection self-tests).
function RunLegacyProbe([string]$Name, [string[]]$Arguments, [int]$ExpectedExit) {
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

function Get-Fields([string]$Line) {
    $Fields = @{}
    foreach ($Match in [regex]::Matches($Line, '([A-Za-z0-9_]+)=(\S+)')) { $Fields[$Match.Groups[1].Value] = $Match.Groups[2].Value }
    return $Fields
}

# Every stage ran and completed, no crash was captured, the watchdog stayed silent, and each first-use probe finished.
function Assert-Supervision([string]$Name, [string[]]$Lines) {
    if (@($Lines | Where-Object { $_ -match '^(SEH|WATCHDOG) ' }).Count) { throw "$Name logged an SEH exception or a WATCHDOG report." }
    $Stages = 'P1', 'P2', 'P3', 'P4', 'P5', 'A', 'B', 'C', 'W', 'D'
    foreach ($StageId in $Stages) {
        $Begins = @($Lines | Where-Object { $_ -ceq "STAGE_BEGIN stage=$StageId" })
        $Ends = @($Lines | Where-Object { $_ -match "^STAGE_END stage=$StageId result=" })
        if ($Begins.Count -ne 1 -or $Ends.Count -ne 1 -or $Ends[0] -cne "STAGE_END stage=$StageId result=completed") {
            throw "$Name stage $StageId did not begin once and end with result=completed: $($Ends -join ' | ')"
        }
    }
    if (@($Lines | Where-Object { $_ -match '^STAGE_END ' }).Count -ne $Stages.Count) { throw "$Name logged an unexpected number of stages." }
    foreach ($Probe in 'P1', 'P2', 'P3', 'P4', 'P5') {
        $ProbeEnds = @($Lines | Where-Object { $_ -match "^PROBE_END id=$Probe completed=" })
        if ($ProbeEnds.Count -ne 1) { throw "$Name probe $Probe has no unique PROBE_END." }
        if ($ProbeEnds[0] -ceq "PROBE_END id=$Probe completed=1") { continue }
        # WARP may refuse P5's hand-built heap properties; then CreateHeap, and only CreateHeap, may fail.
        $Failed = @($Lines | Where-Object { $_ -match "^PROBE id=$Probe step=\S+ result=FAIL " })
        if ($Probe -cne 'P5' -or $Failed.Count -ne 1 -or $Failed[0] -notmatch '^PROBE id=P5 step=create-heap result=FAIL hr=0x[0-9a-f]{8}$') {
            throw "$Name probe $Probe did not complete: $($Failed -join ' | ')"
        }
        Write-Host "$Name probe P5: WARP refused CreateHeap with hand-built node masks 0 ($($Failed[0]))."
    }
}

function Find-LineIndex([string[]]$Lines, [string]$Pattern, [int]$Start = 0) {
    for ($Index = $Start; $Index -lt $Lines.Count; $Index++) { if ($Lines[$Index] -match $Pattern) { return $Index } }
    return -1
}

# Runs the default suite and checks that the log is complete and self-consistent.
function RunDefaultProbe([string]$Name, [string[]]$Arguments, [int]$ExpectedExit) {
    $Log = Join-Path $Logs "$Name.txt"
    Write-Host "Running $Name; complete observations: $Log"
    & $Console @Arguments *> $Log
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne $ExpectedExit) { throw "$Name failed or crashed: expected exit $ExpectedExit, got $ExitCode; see $Log" }
    $Lines = @(Get-Content $Log)
    $Results = @($Lines | Where-Object { $_ -match '^HOST_RESULT ' })
    $Summaries = @($Lines | Where-Object { $_ -match '^MAP_SUMMARY ' })
    $ReproSummaries = @($Lines | Where-Object { $_ -match '^REPRO_SUMMARY ' })
    if ($Results.Count -ne 1 -or $Summaries.Count -ne 1 -or $ReproSummaries.Count -ne 1) { throw "$Name did not complete exactly one default suite." }
    Write-Host $Summaries[0]
    $Counts = Get-Fields $Summaries[0]
    $HostFields = Get-Fields $Results[0]
    foreach ($Key in 'reproFailures', 'mapCasesWithOutsideWrites', 'unavailable', 'committedCpuChanged', 'copyOrderFailures', 'selfTestsFailed',
                     'deviceFailed', 'mapCasesRun', 'committedDefaultChanged', 'uploadSourceDamaged', 'injectionsAttempted', 'injectionsDetected', 'debugErrors',
                     'defaultControlsCompleted', 'sehStages', 'stagesIncomplete', 'probesCompleted', 'watchdogReports') {
        if (-not $Counts.ContainsKey($Key) -or $Counts[$Key] -cne $HostFields[$Key]) { throw "$Name core/host summaries disagree on $Key." }
    }
    if ($Counts['reproFailures'] -cne (Get-Fields $ReproSummaries[0])['failures']) { throw "$Name repro summary disagrees with MAP_SUMMARY." }
    if ($Counts['selfTestsFailed'] -cne '0' -or $Counts['deviceFailed'] -cne '0' -or $Counts['debugErrors'] -cne '0') { throw "$Name reported a validation/device/oracle error." }
    if (@($Lines | Where-Object { $_ -match '^(API_FAILURE|REPRO_API_FAILURE|REPRO_FATAL_WAIT|FATAL_WAIT|DEVICE_REMOVED|REPRO_DEVICE_REMOVED|SELF_TEST_FAIL) ' }).Count) {
        throw "$Name logged an API, device or self-test failure."
    }
    if (-not ($Lines | Where-Object { $_ -match 'SETTINGS debugRequested=1 debugApplied=1 gbvRequested=1 gbvApplied=1 dredRequested=0 dredApplied=0 configuredBeforeDevice=1 dredUntouched=1' })) {
        throw "$Name did not enable the SDK debug layer and GPU validation, or touched the DRED settings (the default path must leave them alone)."
    }
    Assert-Supervision $Name $Lines
    return ,$Lines
}

# WARP is the reference implementation: nothing may change outside any texture, every
# copy must be ordered, and the same code paths must have actually run.
function VerifyDefaultHealthy([string]$Name, [string[]]$Lines) {
    $Counts = Get-Fields (@($Lines | Where-Object { $_ -match '^MAP_SUMMARY ' })[0])
    foreach ($Zero in 'reproFailures', 'mapCasesWithOutsideWrites', 'committedCpuChanged', 'committedDefaultChanged', 'uploadSourceDamaged', 'injectionsAttempted', 'injectionsDetected') {
        if ($Counts[$Zero] -cne '0') { throw "$Name expected $Zero=0 on WARP, got $($Counts[$Zero])." }
    }
    if ($Counts['copyOrderFailures'] -cne '0/0/0/0') { throw "$Name copy-order failures on WARP: $($Counts['copyOrderFailures'])." }
    foreach ($Variant in 'custom', 'default') {
        $Passes = @($Lines | Where-Object { $_ -match "^REPRO variant=$Variant step=\S+ word0=[0-9a-f]{8} expected=[0-9a-f]{8} result=PASS$" })
        if ($Passes.Count -lt 4) { throw "$Name minimal repro variant $Variant ran $($Passes.Count) passing checks, expected at least 4." }
        if ($Lines | Where-Object { $_ -match "^REPRO variant=$Variant .* result=FAIL$" }) { throw "$Name minimal repro variant $Variant failed." }
    }
    $Begin = @($Lines | Where-Object { $_ -match '^MAP_BEGIN cases=([0-9]+) ' })
    if ($Begin.Count -ne 1) { throw "$Name has no unique MAP_BEGIN." }
    $Cases = [int]([regex]::Match($Begin[0], 'cases=([0-9]+)').Groups[1].Value)
    $Ends = @($Lines | Where-Object { $_ -match '^MAP_CASE_END ' })
    $Released = @($Lines | Where-Object { $_ -match '^MAP_STEP id=[0-9]+ step=release ' })
    if ($Ends.Count -ne $Cases -or [int]$Counts['mapCasesRun'] -lt 3 -or $Released.Count -ne [int]$Counts['mapCasesRun']) {
        throw "$Name map case begin/end/release counts disagree (cases=$Cases ends=$($Ends.Count) run=$($Counts['mapCasesRun']) released=$($Released.Count))."
    }
    foreach ($Canonical in 1, 2, 3) {
        if (-not ($Lines | Where-Object { $_ -match "^MAP_CASE_END id=$Canonical complete=1 " })) { throw "$Name canonical map case $Canonical did not complete." }
    }
    foreach ($Line in $Lines) {
        if ($Line -match '^MAP_STEP ' -and $Line -notmatch ' before=0 inside=[0-9]+ after=0 ') { throw "$Name map step changed memory outside the texture: $Line" }
        if ($Line -match '^COMMITTED_CPU placement=\S+ step=\S+ changedTexels=[1-9]') { throw "$Name committed CPU texture changed: $Line" }
    }
    $Default = @($Lines | Where-Object { $_ -match '^COMMITTED_DEFAULT ' })
    if ($Default.Count -ne 1 -or $Default[0] -notmatch 'uploadSourceIntact=1 uploadSourceIntactFinal=1 .*changedTexels=0 ') { throw "$Name default-heap committed control failed or did not run." }
    foreach ($Placement in 'committed', 'placed') {
        if (-not ($Lines | Where-Object { $_ -match "^COMMITTED_CPU placement=$Placement step=to_COMMON changedTexels=0 " })) {
            throw "$Name committed CPU test ($Placement) did not run to completion."
        }
    }
    foreach ($Variant in 'D1', 'D2', 'D3', 'D4') {
        if (-not ($Lines | Where-Object { $_ -ceq "COPY_ORDER_SUMMARY variant=$Variant failures=0/20" })) { throw "$Name copy-order variant $Variant did not pass 20/20." }
    }
    # P1: after queue creation the very next API calls are the custom-heap query and CreateHeap, then the buffer.
    $Queue = Find-LineIndex $Lines '^PROBE id=P1 step=create-queue result=ok '
    if ($Queue -lt 0 -or $Lines[$Queue + 1] -cne 'CALL stage=P1 api=GetCustomHeapProperties' -or $Lines[$Queue + 2] -cnotmatch '^PROBE_HEAP id=P1 ' -or
        $Lines[$Queue + 3] -cnotmatch '^CALL stage=P1 api=CreateHeap what=custom-heap size=327680 type=4 .* alignment=65536 flags=0x0$' -or
        $Lines[$Queue + 4] -cnotmatch '^PROBE id=P1 step=create-heap ') {
        throw "$Name probe P1 is not 'create queue, then CreateHeap(CUSTOM, 327680) as the first use'."
    }
    # Nothing is logged between CreatePlacedResource(test texture) and the observation that follows it.
    for ($Index = 0; $Index -lt $Lines.Count - 1; $Index++) {
        if ($Lines[$Index] -match '^CALL stage=B api=CreatePlacedResource what=texture id=([0-9]+) ') {
            $CaseId = $Matches[1]
            if ($Lines[$Index + 1] -cnotmatch "^MAP_STEP id=$CaseId step=create ") { throw "$Name logged between CreatePlacedResource(texture) and its snapshot in map case ${CaseId}: $($Lines[$Index + 1])" }
        }
        elseif ($Lines[$Index] -match '^CALL stage=A api=CreatePlacedResource variant=custom what=texture ') {
            if ($Lines[$Index + 1] -cnotmatch '^REPRO variant=custom step=create_texture ') { throw "$Name logged between the repro's CreatePlacedResource(texture) and its observation: $($Lines[$Index + 1])" }
        }
    }
    foreach ($StageId in 'A', 'B', 'C', 'W', 'D') {
        if (-not ($Lines | Where-Object { $_ -match "^CALL stage=$StageId api=" })) { throw "$Name has no CALL breadcrumbs for stage $StageId." }
    }
    Write-Host "Verified ${Name}: minimal repro, $($Counts['mapCasesRun']) map cases with no writes outside the textures, committed CPU/default controls and four copy-order variants."
}

function Assert-CrashDetails([string]$Name, [string[]]$Lines) {
    if (-not ($Lines | Where-Object { $_ -match '^SEH_ACCESS accessKind=write accessValue=0x1 accessTarget=0x0$' })) { throw "$Name did not identify the deliberate write to nullptr." }
    if (-not ($Lines | Where-Object { $_ -match '^SEH_REGISTERS architecture=x64 Rip=0x[0-9a-f]+ Rsp=0x[0-9a-f]+' })) { throw "$Name did not capture exception registers." }
    if (-not ($Lines | Where-Object { $_ -match '^SEH_FRAME index=0 .*module=placement-isolation\.exe .*offset=0x[0-9a-f]+ .*peValid=1 source=exception-context$' })) { throw "$Name exception frame 0 is not in the console executable." }
}

$Lines = RunDefaultProbe 'warp-default' @('--warp', '--debug', '--gpu-validation') 0
VerifyDefaultHealthy 'warp-default' $Lines

# Each selectable Xbox experiment gets an independent console process in CI.
function RunSelectedExperiment([string]$Experiment, [string[]]$ExpectedStages, [bool]$DredOff) {
    $Name = "warp-$Experiment"
    $Log = Join-Path $Logs "$Name.txt"
    $Arguments = @('--warp', '--debug', '--gpu-validation', '--experiment', $Experiment)
    if ($DredOff) { $Arguments += '--dred-off' }
    & $Console @Arguments *> $Log
    if ($LASTEXITCODE -ne 0) { throw "$Name failed: exit $LASTEXITCODE; see $Log" }
    $Lines = @(Get-Content $Log)
    $Summaries = @($Lines | Where-Object { $_ -match '^MAP_SUMMARY ' })
    $Hosts = @($Lines | Where-Object { $_ -match '^HOST_RESULT ' })
    if ($Summaries.Count -ne 1 -or $Hosts.Count -ne 1) { throw "$Name missing unique core/host completion." }
    $Counts = Get-Fields $Summaries[0]
    $HostFields = Get-Fields $Hosts[0]
    foreach ($Key in $HostFields.Keys) { if ($Counts[$Key] -cne $HostFields[$Key]) { throw "$Name core/host $Key disagrees." } }
    foreach ($Key in 'reproFailures', 'mapCasesWithOutsideWrites', 'committedCpuChanged', 'committedDefaultChanged', 'uploadSourceDamaged',
                    'selfTestsFailed', 'deviceFailed', 'debugErrors', 'sehStages', 'stagesIncomplete', 'watchdogReports') {
        if ($Counts[$Key] -cne '0') { throw "$Name expected $Key=0, got $($Counts[$Key])." }
    }
    if ($Counts['copyOrderFailures'] -cne '0/0/0/0') { throw "$Name copy failures." }
    if (@($Lines | Where-Object { $_ -match '^(SEH|WATCHDOG|API_FAILURE|REPRO_API_FAILURE|REPRO_FATAL_WAIT|FATAL_WAIT|DEVICE_REMOVED|REPRO_DEVICE_REMOVED|SELF_TEST_FAIL) ' }).Count) { throw "$Name contains an exception, validation or device failure." }
    $Begins = @($Lines | Where-Object { $_ -match '^STAGE_BEGIN stage=' })
    $Ends = @($Lines | Where-Object { $_ -match '^STAGE_END stage=' })
    if ($Begins.Count -ne $ExpectedStages.Count -or $Ends.Count -ne $ExpectedStages.Count) { throw "$Name executed stages outside its selection." }
    for ($Index = 0; $Index -lt $ExpectedStages.Count; $Index++) {
        if ($Begins[$Index] -cne "STAGE_BEGIN stage=$($ExpectedStages[$Index])" -or $Ends[$Index] -cne "STAGE_END stage=$($ExpectedStages[$Index]) result=completed") {
            throw "$Name wrong stage order/completion."
        }
    }
    $SettingPattern = if ($DredOff) { 'dredRequested=0 dredApplied=1 configuredBeforeDevice=1 dredUntouched=0' } else { 'dredRequested=0 dredApplied=0 configuredBeforeDevice=1 dredUntouched=1' }
    if (-not ($Lines | Where-Object { $_ -match "SETTINGS debugRequested=1 debugApplied=1 gbvRequested=1 gbvApplied=1 $SettingPattern" })) { throw "$Name wrong debug/GBV/DRED configuration." }
    if ($Experiment -ceq 'crash' -and $Counts['probesCompleted'] -cne '1') { throw "$Name did not complete P1." }
    if ($Experiment -ceq 'copy') {
        foreach ($Variant in 'D1', 'D2', 'D3', 'D4') { if (-not ($Lines | Where-Object { $_ -ceq "COPY_ORDER_SUMMARY variant=$Variant failures=0/20" })) { throw "$Name did not run all 20 iterations for $Variant." } }
    }
    if ($Experiment -ceq 'memory') {
        if ($Counts['defaultControlsCompleted'] -cne '1') { throw "$Name did not finish its warmup/control." }
        if ([int]$Counts['mapCasesRun'] -lt 29 -or @($Lines | Where-Object { $_ -match '^MAP_CASE_END ' }).Count -ne [int]$Counts['mapCasesRun']) { throw "$Name did not run the full memory map." }
        foreach ($Placement in 'committed', 'placed') {
            if (-not ($Lines | Where-Object { $_ -match "^COMMITTED_CPU placement=$Placement step=to_COMMON changedTexels=0 " })) { throw "$Name committed CPU test ($Placement) incomplete." }
            $Phases = @($Lines | Where-Object { $_ -match "^COMMITTED_CPU_PHASE placement=$Placement target=\S+ cpuReadState=COMMON$" })
            $Returns = @($Lines | Where-Object { $_ -match "^COMMITTED_CPU_RETURN placement=$Placement target=\S+ state=COMMON fenced=1$" })
            if ($Phases.Count -ne 5 -or $Returns.Count -ne 5) { throw "$Name did not fence each $Placement texture back to COMMON." }
        }
        if (-not ($Lines | Where-Object { $_ -match '^COMMITTED_DEFAULT uploadSourceIntact=1 uploadSourceIntactFinal=1 .*changedTexels=0 ' })) { throw "$Name default committed/source control missing or failed." }
    }
    Write-Host "Verified ${Name}: independent process, selected stages $($ExpectedStages -join ','), clean WARP results."
}
RunSelectedExperiment 'crash' @('P1') $false
RunSelectedExperiment 'copy' @('D') $false
RunSelectedExperiment 'memory' @('W', 'B', 'C') $true

# SEH self-test: a deterministic nullptr write exercises context, unwind and
# process-stop behavior. No D3D12 production stage may follow the exception.
$Name = 'self-test-seh'
$Log = Join-Path $Logs "$Name.txt"
Write-Host "Running $Name; complete observations: $Log"
& $Console @('--warp', '--quick', '--self-test-seh') *> $Log
if ($LASTEXITCODE -ne 0) { throw "$Name failed: exit $LASTEXITCODE; see $Log" }
$Lines = @(Get-Content $Log)
$SehLines = @($Lines | Where-Object { $_ -match '^SEH ' })
if ($SehLines.Count -ne 1 -or $SehLines[0] -cnotmatch '^SEH stage=self-test code=0xc0000005 .*module=placement-isolation\.exe offset=0x[0-9a-f]+ ') {
    throw "$Name did not log exactly one access violation in the self-test stage: $($SehLines -join ' | ')"
}
if (-not ($Lines | Where-Object { $_ -ceq 'STAGE_END stage=self-test result=seh' })) { throw "$Name self-test stage did not end with result=seh." }
if (@($Lines | Where-Object { $_ -match '^WATCHDOG ' }).Count) { throw "$Name logged a WATCHDOG report." }
if (@($Lines | Where-Object { $_ -match '^STAGE_BEGIN stage=' }).Count -ne 1 -or
    @($Lines | Where-Object { $_ -match '^STAGE_END stage=' }).Count -ne 1) {
    throw "$Name ran a production stage after the exception."
}
if (-not ($Lines | Where-Object { $_ -match '^HOST_RESULT .* sehStages=1 stagesIncomplete=1 probesCompleted=0 watchdogReports=0$' })) { throw "$Name host result does not report exactly one crashed stage and no production probes." }
# Rich-record checks below are tied to the core's stable log fields, not an
# optimization-dependent exact fault PC or register value.
Assert-CrashDetails $Name $Lines
if (-not ($Lines | Where-Object { $_ -ceq 'PIPELINE_STOP stage=self-test reason=seh noLaterStages=1 separateProcessRequired=1' })) { throw "$Name did not mark the pipeline as stopped." }
$CrashCounts = Get-Fields (@($Lines | Where-Object { $_ -match '^MAP_SUMMARY ' })[0])
foreach ($Key in 'mapCasesRun', 'defaultControlsCompleted') { if ($CrashCounts[$Key] -cne '0') { throw "$Name executed $Key after fault." } }
if ($CrashCounts['pipelineStopped'] -cne '1') { throw "$Name missing pipelineStopped=1." }
Write-Host "Verified ${Name}: access violation captured with context; no later stage ran."

# Injection self-test: the harness itself clears one DWORD just past each texture; the map
# suite must report exactly that DWORD, once, at the right offset, and nothing else.
$Lines = RunDefaultProbe 'negative-map-outside' @('--warp', '--debug', '--gpu-validation', '--quick', '--negative-map-outside') 2
if (-not ($Lines | Where-Object { $_ -ceq 'NEGATIVE_ORACLE_REJECTED:isolation-map-outside' })) { throw 'negative-map-outside did not reject the injected write.' }
$Injections = @{}
$OutsideWords = @{}
foreach ($Line in $Lines) {
    if ($Line -match '^MAP_INJECTION id=([0-9]+) rel=([0-9]+) ') { $Injections[$Matches[1]] = [long]$Matches[2] }
    elseif ($Line -match '^MAP_WORD id=([0-9]+) step=(\S+) rel=(-?[0-9]+) relEnd=(-?[0-9]+) old=[0-9a-f]{8} new=([0-9a-f]{8})$') {
        $WordId = $Matches[1]; $WordStep = $Matches[2]; $WordRel = [long]$Matches[3]; $WordEnd = [long]$Matches[4]; $WordNew = $Matches[5]
        if ($WordRel -lt 0 -or $WordEnd -ge 0) {
            if (-not $OutsideWords.ContainsKey($WordId)) { $OutsideWords[$WordId] = @() }
            $OutsideWords[$WordId] += ,@($WordStep, $WordRel, $WordNew)
        }
    }
}
if ($Injections.Count -lt 2) { throw "negative-map-outside injected only $($Injections.Count) case(s)." }
foreach ($Id in $Injections.Keys) {
    $Found = @($OutsideWords[$Id])
    if ($Found.Count -ne 1 -or $Found[0][0] -cne 'activate' -or $Found[0][1] -ne $Injections[$Id] -or $Found[0][2] -cne '00000000') {
        throw "negative-map-outside case $Id did not report exactly the injected word at rel=$($Injections[$Id])."
    }
}
if ($OutsideWords.Count -ne $Injections.Count) { throw 'negative-map-outside reported outside writes in a case that was not injected.' }

foreach ($Target in 'sentinel', 'owner') {
    $Name = "negative-$Target"
    $Lines = RunLegacyProbe $Name @('--warp', '--debug', '--gpu-validation', '--dred-on', '--legacy-suite', '--quick', '--repeats', '1', "--negative-$Target") 2
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
$NativePdb = Join-Path $Output 'uwp/RingRacersD3D12Isolation.pdb'
if (-not (Test-Path $NativePdb -PathType Leaf) -or (Get-Item $NativePdb).Length -eq 0) { throw 'Native UWP PDB was not generated.' }
New-Item -ItemType Directory -Force (Join-Path $Install 'Symbols') | Out-Null
Copy-Item $NativePdb (Join-Path $Install 'Symbols') -Force
Copy-Item (Join-Path $Output 'placement-isolation.pdb') (Join-Path $Install 'Symbols') -Force
Copy-Item $Console (Join-Path $Install 'Symbols') -Force
Copy-Item (Join-Path $Output 'uwp/RingRacersD3D12Isolation.exe') (Join-Path $Install 'Symbols') -Force

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

$VCLibsSdkRoots = @()
if ($env:ExtensionSdkDir) { $VCLibsSdkRoots += $env:ExtensionSdkDir.Split(';', [StringSplitOptions]::RemoveEmptyEntries) }
if (${env:ProgramFiles(x86)}) { $VCLibsSdkRoots += Join-Path ${env:ProgramFiles(x86)} 'Microsoft SDKs/Windows Kits/10/ExtensionSDKs' }
if ($env:VSINSTALLDIR) { $VCLibsSdkRoots += Join-Path $env:VSINSTALLDIR 'SDKs' }
$VCLibs = Find-VCLibsDependency $VCLibsSdkRoots
New-Item -ItemType Directory -Force (Join-Path $Install 'Dependencies/x64') | Out-Null
Copy-Item -LiteralPath $VCLibs -Destination (Join-Path $Install 'Dependencies/x64') -Force

$Package = Join-Path $Install ('RingRacersD3D12Isolation_' + $Manifest.Package.Identity.Version + '_x64.msix')
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

# D3D12 placement isolation

This standalone Xbox UWP app characterises a Direct3D 12 memory-corruption
problem on Xbox One X: creating or transitioning a placed texture changes
bytes in a neighbouring resource that lies outside the size
`GetResourceAllocationInfo` reports. It does not launch Ring Racers or load its
assets, SDL, engine, arenas, or globals. Its separate package identity is
`RingRacersD3D12Isolation`, so installing it does not replace the game or
change game saves.

The app runs everything automatically in **one pass**, then shows a completion
message. A device failure or crash ends only the stage it happened in (that
stage's GPU objects stay alive until process exit) and the next stage starts on a
new device. Unsupported cases are reported as unavailable; unavailable is not a
pass. Keep the app open until the completion message appears.

The DRED settings (`ID3D12DeviceRemovedExtendedDataSettings`) are deliberately
**not touched** on this path: an earlier build died on the Xbox before its first
CUSTOM heap use without ever configuring DRED, and the probes below must run under
those same conditions. The legacy suite and the console options `--dred-on` /
`--dred-off` still configure DRED before the first device.

## Install and collect the log

Install the standalone MSIX on the Xbox along with its signing certificate and
the x64 dependency packages shipped with the build. Launch the app, wait for the
completion message, then use Xbox Device Portal's application `LocalState` for
this app to retrieve `placement-isolation-log.txt`. Send that single file with
the Xbox model and OS/build. Also say **what the app did**: whether it *closed by
itself* (crash), *stayed on the "running" message without finishing* (hang), or
showed a *dialog or error*, and for a hang roughly how long you waited. Even when
the app disappears, the last lines of the log say where it was (see below).

## Stages, breadcrumbs, watchdog and crash capture

The default suite runs these stages in order. Each begins with `STAGE_BEGIN
stage=<id>` and ends with `STAGE_END stage=<id> result=completed|seh|device-failed|unavailable`
(`seh`: the stage raised a structured exception; `device-failed`: device creation
failed, the device was removed or a GPU wait timed out; `unavailable`: no suitable
adapter or CPU-visible memory). A probe step that merely returns a failing
`HRESULT` does not make its stage `device-failed`.

| Stage | What | Device |
| --- | --- | --- |
| `P1`..`P5` | first-use probes | one brand-new device each |
| `A` | minimal repro | its own fresh device |
| `B` | map suite | shared by `B`, `C` and `D`; replaced by a fresh device after an `seh` or `device-failed` stage |
| `C` | committed CPU-visible tests | (shared) |
| `D` | copy ordering | (shared) |

**Breadcrumbs.** Before every D3D12/DXGI call, and in the setup paths of the map,
committed and copy-order stages, a line is written (and flushed) just before the
call:

```
CALL stage=<P1..P5|A|B|C|D> api=<name> <key arguments>
```

`CreateHeap` shows size, heap type, CPU page property, memory pool, creation and
visible node masks, alignment and flags; `CreatePlacedResource` shows the heap
offset, dimension, width/height/format and initial state. The last `CALL` line
before the log ends is the call that crashed or hung. Nothing is logged between
`CreatePlacedResource(test texture)` and its immediate snapshot (map suite and
repro); the breadcrumb comes before the call. Copy ordering logs breadcrumbs for
the first repetition of each variant only.

**Watchdog.** A thread in the core checks every second. If no log line has been
written for 5 seconds it writes, and again at 10, 15, ... seconds:

```
WATCHDOG idleSeconds=<n> lastLine=<first 160 characters of the last logged line>
```

It never terminates anything. It tracks the last line in its own wrapper around
the log sink, takes no lock while calling the sink, and stops before the final
summary. A hang therefore shows `WATCHDOG` lines (if the app kept running) whose
`lastLine` is the last `CALL`.

**Crash capture.** Each stage runs through a small MSVC `__try`/`__except` guard (a
plain function pointer and `void*`, no C++ objects in the `__try` function). On a
structured exception, including a C++ exception that escapes the stage:

```
SEH stage=<id> code=0x<code> address=0x<address> module=<file name> offset=0x<address - module base> handler=stage-guard thread=<tid>
```

The stage's objects are leaked on purpose and the next stage runs on a new device.
`SetUnhandledExceptionFilter` writes the same line (`handler=unhandled-filter`)
for exceptions on other threads and then lets the process continue to its normal
fate. A process killed by the system without an exception leaves no `SEH` line;
the last `CALL` line still names the call. The console-only option
`--self-test-seh` adds a first stage `self-test` that writes to `nullptr`; CI
checks the `SEH stage=self-test code=0xc0000005` line and that every later stage
still completes.

**[P] First-use probes** (`minimal_repro.cpp`). The earlier Xbox run ended between
`REPRO_ALLOC` and `REPRO_LAYOUT`, inside the first `CreateHeap(CUSTOM)` or
`CreatePlacedResource(buffer)`, with no failing `HRESULT` logged. Each probe
creates a brand-new device (same adapter choice, no DRED or debug-layer
configuration) and then:

| Probe | After device and queue creation, the first API use is |
| --- | --- |
| `P1` | `CreateHeap` (CUSTOM from `GetCustomHeapProperties(UPLOAD)`, 327680 bytes, alignment 65536, flags 0); then a 64 KB `ROW_MAJOR` placed buffer at 262144 (`GENERIC_READ`), `Map`, write and read one word |
| `P2` | an empty command list submitted and waited on, then the same as `P1` |
| `P3` | `CreateHeap(DEFAULT, 65536)`, then the same as `P1` |
| `P4` | `CreateCommittedResource` of a 64 KB buffer in the CUSTOM WRITE_BACK/L0 properties (`GENERIC_READ`) instead of a heap, `Map`, write and read |
| `P5` | as `P1`, with the heap properties built by hand: CUSTOM, WRITE_BACK, L0, creation and visible node masks 0 instead of the query's 1/1 |

```
PROBE_BEGIN id= variant= warp=
PROBE_ADAPTER id= description= vendor= device= warp=
PROBE_HEAP id= source=GetCustomHeapProperties(UPLOAD)|hand-built
PROBE id=<P1..P5> step=<step> result=ok|FAIL hr=0x<hr>
PROBE_END id=<P1..P5> completed=0|1
```

Steps: `create-device`, `create-queue`, (`P2`: `create-allocator`, `create-list`,
`close-list`, `create-fence`, `create-event`, `signal`, `set-event`, `empty-submit`),
(`P3`: `create-default-heap`), `create-heap` and `create-placed-buffer` (`P4`:
`create-committed-buffer`), `map`, `write-read`. The first failing step ends the
probe with `completed=0`. A probe that dies leaves its last `CALL` line. Reading
the set of probes that die: if `P1` dies but `P2` and `P3` survive, the first
CUSTOM heap use needs a device that has already done other work; if `P4`
survives while `P1` dies, committed CUSTOM memory works but a placed buffer in a
CUSTOM heap does not; if `P5` survives while `P1` dies, the node masks matter
(0/0 against the query's 1/1).

## What runs

**[A] Minimal repro** (`minimal_repro.cpp`, after the probes, its own
fresh device; readable, commented, d3d12/dxgi only, suitable to hand to
Microsoft). A 256x256 RGBA8 one-mip texture is placed at offset 0 and a 64 KB
buffer at the texture's `SizeInBytes` (adjacent, no overlap) holding a known
pattern. The texture is only created and transitioned
(`COMMON→COPY_DEST→COPY_SOURCE`, fenced), and the buffer is checked after each
step. Variant `custom` uses a CUSTOM WRITE_BACK/L0 heap with a persistently
mapped buffer read by the CPU; variant `default` uses a DEFAULT heap and a GPU
copy of the buffer's first 16 bytes to a READBACK buffer.

```
REPRO variant=<custom|default> step=<step> word0=<hex> expected=<hex> result=PASS|FAIL
REPRO_DETAIL variant= step= changedWords= firstChangedWord=      (only on FAIL)
REPRO_ALLOC / REPRO_LAYOUT / REPRO_HEAP / REPRO_ADAPTER ...      (context)
REPRO_SUMMARY failures=<n>
```

**[B] Map suite** observes every byte the driver touches. For each case a CUSTOM
heap of `align(O + S + 128K, 64K)` is created, a ROW_MAJOR buffer *window* `W`
covers the whole heap (read only by the CPU, filled with a pattern), and the
test resource is placed inside it at `O` (65536 unless noted). Overlapping
placed resources are legal; `W` is only an instrument. `W` is re-read after
`create` (immediately after `CreatePlacedResource`, before any logging), then
after each fenced GPU step: `activate` (aliasing barrier), `to_COPY_DEST`,
`upload` (unique word per texel), `to_COPY_SOURCE`, `to_PIXEL_SHADER_RESOURCE`,
`to_RENDER_TARGET`/`clear_rtv` (RT cases), `to_UNORDERED_ACCESS` (UAV cases),
`to_COPY_DEST_2`, `to_COMMON`, and `release`. Matrix (29 cases): canonical 2D
RGBA8 256x256 three times, 2D sizes, mip chains, formats (R8, R32_UINT,
RGBA16F, BC1), RT/UAV flags, 1D, 2D array, 3D, other offsets, and a 256 KB
buffer control.

```
MAP_CASE id= name= dim= width= height= depthOrArray= mips= format= flags= requestedAlignment= offset=
MAP_ALLOC id= size=S alignment= explicitAlign64KSize= copyableTotal= info1_offset0= info1_offset1= info1_total=
MAP_STEP id= step= before= inside= after= insideFirstRel= insideLastRel= afterFirstRel=
MAP_WORD id= step= rel= relEnd=(rel-S) old= new=         (outside [O,O+S) always; inside except on upload; 64 per step)
MAP_LAYOUT id= subresource= firstTexelRel= lastTexelRel= minRel= maxRel=   (after upload; DWORD-element formats)
MAP_LAYOUT_MISSING / MAP_LAYOUT_DUPLICATE id= count=
MAP_CASE_END id= complete= outsideChangedVsOriginal= stepsWithOutsideWrites=
```

`before`/`inside`/`after` count changed DWORDs in `[0,O)`, `[O,O+S)`, `[O+S,H)`;
`Rel` is a byte offset relative to `O`.

**[C] Committed CPU-visible test.** A committed (and, for comparison, a placed)
256x256 RGBA8 texture in a CUSTOM WRITE_BACK/L0 heap is written with
`WriteToSubresource`, then read back with `ReadFromSubresource` after each fenced
transition (`COPY_DEST`, `COPY_SOURCE`, `PIXEL_SHADER_RESOURCE`, `COPY_DEST`,
`COMMON`):

```
COMMITTED_CPU placement=<committed|placed> step= changedTexels= firstIndex= lastIndex=
COMMITTED_CPU_TEXEL placement= step= index= x= y= expected= actual=      (up to 16)
COMMITTED_DEFAULT uploadSourceIntact= uploadSourceIntactFinal= lastTexel= expected= changedTexels= firstChanged= uploadLastTexel=
```

`COMMITTED_DEFAULT` uploads to a default-heap committed texture, re-reads the
UPLOAD buffer on the CPU after the fence (is the source damaged?), and copies the
texture to an exact-size READBACK buffer (is the destination damaged?).

**[D] Copy ordering.** 20 repetitions each of: D1 init copy then overlapping
payload copy in one list with no barrier (the pattern that failed in the game);
D2 the same in two `ExecuteCommandLists` with a fence between; D3 one list with a
UAV barrier (null resource) between; D4 payload copied to a non-overlapping
buffer (control). Payload is 82432 bytes.

```
COPY_ORDER variant= repetition= result=PASS|FAIL badBytes= firstBadOffset= guardBadBytes=
COPY_ORDER_SUMMARY variant= failures=<n>/20
```

The last log line of the core is

```
MAP_SUMMARY reproFailures= mapCasesWithOutsideWrites= unavailable= committedCpuChanged= copyOrderFailures=D1/D2/D3/D4 selfTestsFailed= deviceFailed= mapCasesRun= committedDefaultChanged= uploadSourceDamaged= injectionsAttempted= injectionsDetected= debugErrors= pendingResourcesRetained= sehStages= stagesIncomplete= probesCompleted= watchdogReports=
```

(`pendingResourcesRetained` counts leaked devices.) The host appends
`HOST_FINISHED ...`. The log is prefixed `mode=default` per line, and the core
starts with `SUPERVISOR sehGuard= watchdogSeconds= selfTestSeh= dredUntouched=`.

## Build from source and verify

Use an x64 Visual Studio 2022 developer shell with C++ UWP support, Windows SDK
tools (`fxc`, `MakePri`, `MakeAppx`, and `SignTool`), and the Microsoft VCLibs
14.0 extension SDK.

```powershell
python tests/prepare-source.py build/probe-source
./diagnostics/placement-isolation/build.ps1 -Engine build/probe-source
```

The output is `build/placement-isolation/install/`, with full WARP logs in
`build/placement-isolation/logs/`. The script builds the console harness and
runs it on WARP with the debug layer and GPU-based validation. WARP is the
reference: it must show `REPRO_SUMMARY failures=0`, no write outside any map
case, no changed texel in the committed tests, and all copy-order variants
passing; every `STAGE_END` must be `completed`, `PROBE_END completed=1` for
`P1`..`P5` (WARP may refuse only `P5`'s `CreateHeap`), and there must be no `SEH`
or `WATCHDOG` line; the script fails otherwise. It also checks that `P1` makes
`CreateHeap` its first API use after queue creation and that nothing is logged
between `CreatePlacedResource(texture)` and its snapshot. A `--self-test-seh` run
must log `SEH stage=self-test code=0xc0000005` in `placement-isolation.exe` and
complete all later stages. It also runs injection self-tests: the
`--negative-map-outside` run has the harness clear the DWORD at `W[O+S]` after the
`create` snapshot and requires the next step to report exactly that word
(`rel=S`, `new=00000000`) once per case and nothing else; the legacy-suite
`--negative-sentinel` and `--negative-owner` runs check the old oracle. A control
failure means the diagnostic data path failed; it is not evidence about Xbox.

Console options (`placement-isolation.exe`): `--warp`, `--debug`,
`--gpu-validation`, `--quick` (canonical map case plus control), `--repro-only`
(just [A]), `--legacy-suite` (below), `--negative-map-outside`,
`--negative-sentinel`, `--negative-owner`, `--self-test-seh`, and `--dred-on` /
`--dred-off` (configure DRED before the first device; the default suite leaves it
untouched without them). Without `--warp` it uses the first
hardware D3D12 adapter, where findings are expected and exit code 1 is normal.

## Legacy suite

The original 408-case sentinel matrix (two DRED passes of 204 cases: sentinel and
owner textures, shader/copy/toggle observers, raw-buffer controls) is still in
`isolation.cpp` and runs only with `--legacy-suite` in the console harness. The
Xbox app does not run it.

## Reading the results

- `REPRO … result=FAIL` on `create_texture` means `CreatePlacedResource` alone
  changed the neighbour; on a transition step, the transition did.
- In the map suite, `MAP_WORD … rel=S` (first DWORD after the texture, `relEnd=0`)
  reveals a driver word just past the reported size; `MAP_STEP before=` words show
  writes below the texture. Compare cases for size/alignment/format dependence and
  `MAP_ALLOC info1_offset1` for what the driver itself thinks the minimum spacing is.
- `MAP_LAYOUT` shows where each subresource's texels landed in the heap; a
  `minRel`/`maxRel` span larger than `S`, or `MISSING` words, indicates data placed
  outside the allocation or compressed.
- `COMMITTED_CPU` changed texels (and `lastTexel` in `COMMITTED_DEFAULT`) show
  whether a committed texture's own last texel is overwritten, and
  `uploadSourceIntact=0` that the upload source, not the destination, is damaged.
- `COPY_ORDER` D1 failing while D2/D3 pass means overlapping same-list copies are
  not serialised without a barrier on this device.

Unavailable results are not clean. Neither a clean run nor these observations
identify a driver mechanism by themselves; they narrow the failing operation.

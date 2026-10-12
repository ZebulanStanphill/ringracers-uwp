# D3D12 placement isolation

This standalone Xbox UWP app characterises a Direct3D 12 memory-corruption
problem on Xbox One X: creating or transitioning a placed texture changes
bytes in a neighbouring resource that lies outside the size
`GetResourceAllocationInfo` reports. It does not launch Ring Racers or load its
assets, SDL, engine, arenas, or globals. Its separate package identity is
`RingRacersD3D12Isolation`, so installing it does not replace the game or
change game saves.

The app runs everything automatically in **one pass** with DRED forced off, then
shows a completion message. A device failure stops the suite (pending GPU
resources stay alive until process exit). Unsupported cases are reported as
unavailable; unavailable is not a pass. Keep the app open until the completion
message appears.

## Install and collect the log

Install the standalone MSIX on the Xbox along with its signing certificate and
the x64 dependency packages shipped with the build. Launch the app, wait for the
completion message, then use Xbox Device Portal's application `LocalState` for
this app to retrieve `placement-isolation-log.txt`. Send that single file with
the Xbox model and OS/build.

## What runs

**[A] Minimal repro** (`minimal_repro.cpp`, first thing in the process, its own
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
MAP_SUMMARY reproFailures= mapCasesWithOutsideWrites= unavailable= committedCpuChanged= copyOrderFailures=D1/D2/D3/D4 selfTestsFailed= deviceFailed= mapCasesRun= committedDefaultChanged= uploadSourceDamaged= injectionsAttempted= injectionsDetected= debugErrors= pendingResourcesRetained=
```

and the host appends `HOST_FINISHED ...`. The log is prefixed `mode=default` per line.

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
passing; the script fails otherwise. It also runs injection self-tests: the
`--negative-map-outside` run has the harness clear the DWORD at `W[O+S]` after the
`create` snapshot and requires the next step to report exactly that word
(`rel=S`, `new=00000000`) once per case and nothing else; the legacy-suite
`--negative-sentinel` and `--negative-owner` runs check the old oracle. A control
failure means the diagnostic data path failed; it is not evidence about Xbox.

Console options (`placement-isolation.exe`): `--warp`, `--debug`,
`--gpu-validation`, `--quick` (canonical map case plus control), `--repro-only`
(just [A]), `--legacy-suite` (below), `--negative-map-outside`,
`--negative-sentinel`, `--negative-owner`. Without `--warp` it uses the first
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

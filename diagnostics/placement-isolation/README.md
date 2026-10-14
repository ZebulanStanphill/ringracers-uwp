# D3D12 placement isolation

This standalone Xbox UWP diagnostic investigates the Xbox One X D3D12 placed-resource corruption, first-use access violation and copy-ordering anomalies. It uses only the Windows SDK, not the game, SDL, engine globals or game assets. Its separate package identity `RingRacersD3D12Isolation` leaves Ring Racers and its saves alone.

Version **1.1.0.0** runs one selected experiment per app process. A caught structured exception or device failure stops that process's diagnostic pipeline immediately: the app never tries another stage on a possibly damaged device or runtime. Unsupported cases are reported as unavailable; unavailable does not mean clean.

## Install and collect one log

Install the MSIX, its signing certificate and the included x64 VCLibs dependency through Xbox Device Portal. Then:

1. Launch **Ring Racers D3D12 Isolation** and choose **Crash details**. Wait for the completion message, acknowledge it and let the app close.
2. Launch again and choose **Copy ordering**. Wait, acknowledge and let the app close.
3. Launch again and choose **Texture memory**. Wait, acknowledge and let the app close.
4. Retrieve this app's `LocalState/placement-isolation-log.txt` through Xbox Device Portal and send that one file. Also note any launch that closed before completion or hung, and approximately how long it waited.

Each launch creates a new process; there is no automatic rerun inside a process. The first launch of this diagnostic version clears the previous log. Later launches append to it. `SESSION_BEGIN`, `SESSION_SELECTION` and `SESSION_END` record PID, experiment, package version, Xbox OS version and completion/failure counts. An abrupt termination can leave a session without its end marker; its last flushed breadcrumb still identifies the attempted call. If the selection dialog is canceled, no experiment runs.

The install artifact includes `Symbols/` with the native executable and matching PDB, plus console symbols. Keep these exact binaries with the log for remote or offline decoding. Private Xbox driver symbols are not supplied by this project.

## Experiments

**Crash details** runs only first-use probe `P1` on a fresh D3D12 device. It preserves the candidate failing sequence: queue creation, custom-heap query, `CreateHeap(CUSTOM, 327680)`, then the placed buffer. It leaves DRED settings untouched to match the observed failing run. It captures exception access type and target, register context, and a bounded stack unwound from the exception context, with module-relative addresses and PE identity. This distinguishes a null or bad pointer and the call path without asserting an internal driver cause.

**Copy ordering** runs only stage `D`, with DRED untouched. Each of D1–D4 has 20 repetitions: initialization followed by overlapping payload copies in one list; the copies separated by a completed fence; one list with an intervening null-resource UAV barrier; and a non-overlapping destination control. The legacy `CopyBufferRegion` API serializes conflicting copies implicitly. A fencing workaround does not establish that the application needed a barrier or identify the backend fault.

**Texture memory** explicitly disables DRED before its first device. It first runs stage `W`, a default-heap committed texture upload/readback with source-buffer integrity checks, as an intentional clean warmup and control. Then stage `B` maps the DWORD changes around 29 placed textures/buffer layouts using a persistently mapped CPU-visible buffer window. Stage `C` compares committed and placed CPU-visible textures. All `ReadFromSubresource` and `WriteToSubresource` calls occur in `COMMON`; each tested state transition returns to `COMMON`, with a completed fence, before a CPU read. Earlier diagnostic readings made while a texture was in another state must not be used as evidence.

The memory experiment's changed initialization and DRED configuration are deliberate ways to collect valid memory evidence despite the first-use crash. They are not a proven fix. A crash or device failure ends the remaining memory stages as well.

## Reading the records

- `STAGE_BEGIN stage=` and `STAGE_END stage= result=` mark each attempted stage. `result=seh` or `device-failed` stops the pipeline; later stages must be absent.
- Flushed `CALL stage= api=` breadcrumbs precede the D3D12/DXGI call, including resource descriptions, heap properties, offsets and initial states. No extra log call occurs between texture creation and its immediate map snapshot.
- `SEH` reports exception code, fault PC and module offset. `SEH_ACCESS` adds read/write/execute and target address. `SEH_REGISTERS` captures the x64 context. `SEH_FRAME` starts at the actual fault context and records bounded unwind frames. PE metadata identifies the exact module build. An unavailable unwind or module query is reported rather than invented.
- `WATCHDOG` records the last call after five seconds without progress, repeating while the app remains running. It does not terminate a hung driver call.
- `MAP_ALLOC` records allocation size/alignment and `MAP_STEP before/inside/after` counts changed DWORDs relative to the resource's reported allocation. `MAP_WORD` supplies offsets and before/after values. A map-window observation is not a direct texture-layout contract or a diagnosis of compression metadata.
- `COMMITTED_DEFAULT` checks the uploaded texture and the independent upload source. `COMMITTED_CPU` checks CPU texture content only in `COMMON`, after fencing. `COPY_ORDER_SUMMARY` gives failures out of 20 for each variant.
- `MAP_SUMMARY` is the core's result; `SESSION_END` is the Xbox host's result. Missing summaries, unavailable cases and API failures are not clean results. These observations narrow failing operations; they do not prove that every anomaly shares one cause.

## Build and verification

Use an x64 Visual Studio 2022 developer shell with C++ UWP support, Windows SDK tools (`fxc`, `MakePri`, `MakeAppx`, `SignTool`) and the Microsoft VCLibs 14.0 extension SDK:

```powershell
python tests/prepare-source.py build/probe-source
./diagnostics/placement-isolation/build.ps1 -Engine build/probe-source
```

The script publishes `build/placement-isolation/install/` and full WARP logs in `build/placement-isolation/logs/`. It runs the full console suite with SDK debug-layer and GPU-based validation, then each selectable experiment in its own console process. The memory selection explicitly disables DRED, as the Xbox host does. Healthy WARP must show clean source, destination and outside-allocation checks, all copy variants passing, and exactly the selected stages in order. The `--self-test-seh` run performs an actual deliberate null-pointer write: the oracle requires the captured access target/context and executable-origin frame, exactly one crashed stage, and no later stage. GPU sentinel/owner and map-window negative controls must still reject their intended corruption.

The console supports `--experiment all|crash|copy|memory` (default `all`), `--warp`, `--debug`, `--gpu-validation`, `--quick`, `--repro-only`, `--legacy-suite`, `--self-test-seh`, `--negative-map-outside`, `--negative-sentinel`, `--negative-owner`, `--repeats N`, and `--dred-on` / `--dred-off`. The Xbox host selects its DRED behavior explicitly as described above; for an equivalent console memory run, add `--dred-off`. The full console selection retains P1–P5, minimal repro `A`, map `B`, CPU textures `C`, default control `W` and copies `D`, but also stops at the first exception/device failure. The original 408-case sentinel matrix remains available only with `--legacy-suite` and is not run by the Xbox app.

WARP checks the diagnostic and its oracles. It does not validate Xbox hardware behavior or establish the internal runtime/driver cause.

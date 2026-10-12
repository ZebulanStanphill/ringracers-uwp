# D3D12 placement isolation suite

This standalone Xbox UWP app runs a finite placement-diagnostics matrix on
launch. It is intended to collect the comparison data needed to narrow the
Xbox D3D12 placed-resource issue in one run. It does not launch Ring Racers or
load its assets, SDL, engine, arenas, or globals. It creates private D3D12
devices, queues, and fences for the diagnostic cases. Its separate package
identity is `RingRacersD3D12Isolation`, so installing it does not replace the
game or change game saves.

The app runs 204 cases per pass: first with DRED disabled, then with
DRED enabled, using fresh devices for the two passes. A device failure stops
the suite because pending GPU resources must remain alive until process exit.
It reports unsupported
cases as unavailable; unavailable results are not passes. Keep the app open
until its on-screen final summary says the matrix is complete.

## Install and collect the log

Install the standalone MSIX on the Xbox along with its signing certificate and
the x64 dependency packages shipped with the build. Launch the app and wait
for the completion summary. Then use Xbox Device Portal's application
`LocalState` for this app to retrieve:

`placement-isolation-log.txt`

The log is written to the app's local state. Send that single file with a note
of the Xbox model and OS/build. Do not close the app before the completion
summary appears; an interrupted run leaves an incomplete log.

## Build from source

Use an x64 Visual Studio 2022 developer shell with C++ UWP support, Windows SDK
tools (`fxc`, `MakePri`, `MakeAppx`, and `SignTool`), and the Microsoft VCLibs
14.0 extension SDK. The build script finds the retail x64 dependency through
the installed SDK manifest and validates its UWP framework identity before
including it in the install artifact.

```powershell
python tests/prepare-source.py build/probe-source
./diagnostics/placement-isolation/build.ps1 -Engine build/probe-source
```

The default output is `build/placement-isolation/install/`, with full WARP logs
in `build/placement-isolation/logs/`.

## What the matrix compares

Each observer uses an independent fresh fixture. The shader observer keeps
the neighboring sentinel in `NON_PIXEL_SHADER_RESOURCE`; the stable copy
observer keeps it in `COPY_SOURCE`. A third observer toggles the sentinel
between `COPY_DEST` and `COPY_SOURCE`. It compares adjacent and guarded placements,
multiple owner/sentinel sizes and initial states, and ordering/repeat variants
supported by the device. The matrix also includes full-size owner and sentinel
raw-buffer controls, exact and padded readback allocations, a full owner
shader read, and independent readbacks to investigate last-word transport
faults. Raw transport controls use a separate upload buffer with identical
data, so their CPU read does not touch the later texture-upload source.

The stage observations cover CPU resource creation, alias activation,
transition to copy-destination without upload, upload, transition to
copy-source without a copy, owner readback, shader-resource transitions,
release, and recreation. Where supported, an additional CPU observation maps
a persistently mapped buffer sentinel on a custom write-back/L0 heap. That
observation has different heap and mapping properties from an opaque default
texture and should be interpreted separately.

For each case the log records device/capability information, requested and
applied debug/DRED settings, heap and resource footprints, buffer lengths,
guard/prefix checks, complete payload comparisons, payload hashes, and first
and last mismatch details. The companion Windows WARP harness runs with the
debug layer and GPU-based validation, including deliberate first-sentinel-word
and last-owner-word corruption controls that must be detected. A control
failure means the diagnostic data path failed; it is not evidence about Xbox
behavior.

## Reading the results

The first failing stage is useful only when the same case's baseline passed.
Interpret it as a boundary on when the observed bytes changed, not as proof of
an internal driver cause:

- Shader and copy observers both failing before owner upload points toward
  resource creation or alias activation handling.
- Only the copy observer failing points toward copy/readback or source-state
  dependence; the observers use different fixtures and states.
- An exact readback failing while a padded readback and shader observer pass
  points toward the transport or allocation tail.
- A CPU buffer observation failing immediately after CPU creation rules out
  the GPU-copy observer for that observation, while its mapping and heap
  properties remain distinct.
- A final-word mismatch by itself can come from readback-tail behavior; it
  does not establish that the owner texture was corrupted.

Unsupported API or capability combinations are reported as unavailable, not
clean. A mismatch in the raw-buffer controls is a diagnostic data failure.
Neither a clean run nor these observations identify a driver mechanism by
themselves; they provide evidence to narrow the failing operation for follow-up.

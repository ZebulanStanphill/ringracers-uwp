# Xbox light-table corruption diagnostic

These notes track the intermittent pure-white-as-black failure with VibeRant
D3D12 and Palette Rendering. The 4 KB placement guard stopped the reported
neighboring light-table corruption on Xbox One X, but a clean guard-only session
does not establish a driver bug or prove the guard fixed the underlying cause.
Encore and table updates are not prerequisites for the report.

## Placement-probe diagnostic branch

**This branch is diagnostic and is not for master.** It defaults
`RR_D3D12_TEXTURE_CANARIES` and `RR_D3D12_LIGHTTABLE_DIAGNOSTICS` to `1`;
define either as `0` to disable it. It includes ordinary game-texture
texture canaries and the opt-in `d3d12_placementprobe` command. The placement
probe uses private fresh heaps (and a committed-resource control), bypassing the
texture arena and upload ring. It tests whether a real D3D12 copy into an owner
can alter an adjacent sentinel under controlled placement conditions. It does
not claim a fix or prove the cause of the original light-table failure.

### Production canaries

Every shared-heap texture requests its reported `SizeInBytes`, rounded up to
4 KB, plus a 4 KB sentinel and a final 4 KB blind guard. The arena classes and
alignment-separated free lists are unchanged. A 32×32 RGBA8 canary sits after
the owner allocation; its raw words are `0xC4000000 ^ (uint32(canaryId) *
2654435761) ^ texelIndex`, for row-major indices 0–1023. A one-time fallback
warning disables new canaries if the device does not grant exactly 4 KB size
and alignment. Committed textures have no production canary. `allZero` means
every changed word is zero; it does not mean the entire sentinel was cleared.

The new layout retains a blind 4 KB after each production canary. Earlier
canaries had no guaranteed blind guard after the sentinel. In the Xbox log,
owner 207 occupied offset 2,154,496 for 16,384 bytes; sentinel 208 began at
2,170,880 and was 4,096 bytes; the next table began at 2,174,976, exactly at
the sentinel's end. The sentinel directly followed the owner, so the owner's
first 4 KB guard was the sentinel itself. Eight light-table creation checks
were clean. Each of 857 distinct canaries had exactly one changed word: its
first texel changed from the initialized pattern to zero. Separately, two
light tables later lost their first texel, changing from their CPU-expected
color to zero. These differences do not establish that owner 207 caused them.
The sentinel was initialized before the table upload, so
an upload-time overrun could have been overwritten by that table upload; later
sentinel operations or cross-writes also remain possible. The captured run
reported normal and small placements, no fallback/device errors or budget
exhaustion, a 636.83 MB peak texture heap, and 672 MB allocated across 42 heaps.
These observations do not establish an owner overrun.

Canary reads are asynchronous and bounded. Three readback pages each hold 64
slots of 8192 bytes (32 rows at 256-byte pitch). Checks copy at most 64 canaries
each frame, prioritizing completed owner uploads and a repeat approximately 60
frames later, then manual requests and a round-robin sweep. Buffers are mapped
only after the covering submission completes; unavailable pages defer checking
without a CPU wait or extra submission. The existing automatic light-table
diagnostics still submit and wait synchronously and can change reproduction
timing.

Readback slots retain unique canary IDs, never texture pointers. Owner retirement
cancels queued/manual comparisons, and a submitted result is discarded if its
ID is no longer live. The busy slot is retained until its fence completes;
canary resources and the whole owner block retire at the owner's pending fence.
A manual request covers the live set at invocation; subsequent creations belong
to later requests. Removed owners count as cancellations. A repeated command
replaces the outstanding request, and pre-request copies do not satisfy the new
request.

`UWP D3D12: canary summary:` reports cumulative created, checked, corrupt and
fallback counts plus the current live count, about every ten seconds and on
manual completion. A successful manual completion means every surviving
requested ID was compared; retired owners are cancellations. Allocation/Map
errors make checks unavailable, not successful comparisons.

`UWP D3D12: canary mismatch:` reports canary and owner IDs, dimensions, format,
mips, placement/alignment, `SizeInBytes`, copyable-footprint bytes, heap/block
and canary offsets, alignment gap, creation frame/fence, latest upload fence,
changed texel count and `allZero`. It prints up to sixteen `(x,y)
expected->observed` values as raw 32-bit words, not the palette probe's RRGGBBAA
notation. Identical corrupt contents log once; changed contents log an update,
with bounded texture history. `allZero` means every changed word is zero, not
that all 1024 words changed. `canary lighttable mismatch:` is a rate-limited
warning. D3D12 tiled layouts make texel indices unsuitable as a portable
physical byte-distance measurement.

### Isolated placement probe

Run `d3d12_placementprobe` with no arguments, in a menu or level. It exercises
`adjacent-normal` (256×256), `adjacent-small` (64×64), `guarded-normal`,
`guarded-small`, and `committed-control`. The adjacent cases place the sentinel
after the owner; guarded cases insert a 4 KB gap. Each placed case uses a
private fresh heap and a final 4 KB blind tail after the sentinel. The control
uses committed owner and sentinel resources. These cases avoid the shared
texture arena and staging ring.

Before creating the owner, the probe initializes the sentinel and compares two
independent readbacks twice. It then creates and activates the owner, uploads
to it, transitions it for pixel-shader resource use, and repeats sentinel
readbacks after each stage, including after a separate full owner readback.
Every case also checks a raw-buffer-to-readback copy. Logs use
`placementprobe start:`, `placementprobe check:` and `placementprobe case end:`
with the case, stage and result. Results are `clean`,
`mismatch` or `unavailable`; the first failing stage is meaningful only when
the baseline was clean. The two readbacks report whether their outputs match.
The optional WARP negative-control hook overwrites only the sentinel's first
word through a real copy, validating mismatch detection without establishing an
Xbox cause. Errors and unavailable comparisons are not passes.

### Xbox procedure

1. Install the new diagnostic branch build and enable the UWP profile, VibeRant
   D3D12, and Palette Rendering.
2. Run `d3d12_placementprobe` once, in a menu or level. Play Metropolis for
   several minutes. Optionally run `d3d12_canarycheck` while reproducing.
3. Send `E:\ringracers\latest-log.txt` and `uwp-profile.txt`, and report whether
   black or disappearing pixels appeared and when.

The probe and canaries are diagnostics; they make no rendering-fix claim.
WARP validates the probe machinery, including its deliberate overwrite, but
cannot establish Xbox behavior. A clean session alone is not proof of a fix.

## Guard workaround (before this diagnostic branch)

- **Fix (confirmed on Xbox One X):** every texture placed in a shared D3D12 heap
  has a 4 KB guard after it. On Xbox One X, adding the guard stopped the
  neighboring light-table corruption, but changed the placement layout. This
  alone does not prove a write past the reported allocation size.
- **Texture arena classes:** the texture arena uses quarter-octave classes
  P, 1.25P, 1.5P, 1.75P and 2P. Each request, including its 4 KB guard, rounds up
  to the next class, then to the placement alignment (4 KB or 64 KB). The largest
  arena block is 4 MB; larger textures fall back to committed resources. Chunks and
  free lists are separated by alignment, so bump allocation does not waste space
  on padding. The earlier power-of-two classes doubled common exact-fit textures
  (716 MB peak) and are historical only.
- **Static upload arena:** unchanged. It still uses power-of-two classes.
- **Diagnostics off by default:** the automatic light-table creation and timer
  checks, and the texture-event recording, are disabled by default (switch
  `kLightTableDiagnostics`). The manual `d3d12_paletteprobe` still checks the
  retained light-table bytes against the GPU. The CPU baseline costs 33 KiB per
  table even with automatic checks off; GPU readbacks happen only on command.
  Define `RR_D3D12_LIGHTTABLE_DIAGNOSTICS` to enable automatic checks and event
  history in a diagnostic build, as the Windows WARP harness does.

The procedure, log format and audit below preserve the earlier light-table
diagnostic investigation. The new placement-probe procedure above applies to the
current diagnostic branch; automatic light-table checks still require
`kLightTableDiagnostics` to be enabled.

## Xbox procedure (historical)

1. Install this branch's `ringracers-uwp` artifact. Start a fresh session with
   VibeRant D3D12 and Palette Rendering on.
2. Load and play the tracks that reproduced the failure, including an ordinary
   non-Encore race. Stay in each level for at least 20 seconds. Creation checks
   and automatic checks need no console command.
3. When white becomes black, leave Palette Rendering on, open the console, run
   `d3d12_paletteprobe`, close the console and let the scene draw. Do this before
   toggling Palette Rendering or restarting the level.
4. After capturing the failure, toggle Palette Rendering off/on, run the command
   again, and play for at least 10 seconds to capture the recovery. Keep the
   session log from startup through recovery.

These steps need the diagnostic build (`kLightTableDiagnostics` on). In the
default build, only the manual `d3d12_paletteprobe` step produces light-table
output.

Send the complete log if possible. Otherwise send every `UWP D3D12: lighttable
check:` line from level load through failure and recovery, the whole associated
`lighttable events:` / `lighttable event:` dump, the `paletteprobe` result, and
nearby `UWP perf:   D3D12: palette:` / texture-heap lines and any D3D12 error or
fence-timeout lines. Note the track, whether Encore was on, and when white first
looked black. Matching creation checks followed by a timer mismatch distinguish
later damage from damage already present at upload completion.

## Log interpretation

`reason=create` follows a separate submission/wait for the upload, then a
complete 256×33 RGBA8 readback. `reason=manual` checks all live tables immediately
when the console command runs, even without an eligible sprite/floor draw.
`reason=timer` checks all live tables at one-second intervals through ten seconds
after `ClearLightTables`, then at ten-second intervals. It logs only changed
GPU contents, CPU expectations or readback status. Clears happen at level load
and also restart this schedule when Palette Rendering is toggled.

Each table line contains its id, resource pointer, placed/committed status,
zero-based heap index (`4294967295` for committed), offset, block size (a
quarter-octave class in the current arena; a power of two in the earlier build
that produced these logs), SRV,
creation fence, frame, loading/reloading flags, numeric game state, map and
leveltime. `error=none mismatches=0` means every texel matched. On a mismatch,
first/last coordinates are in row-major order, values are RRGGBBAA, and `rows`
is a 33-bit hexadecimal mask (bit 0 is row 0; bit 32 is fullbright).
`(-1,-1)` means no mismatching texel. An error is an unavailable comparison;
its zero mismatch count does **not** mean a match.

With automatic diagnostics enabled, a table that changes from matching to corrupt dumps the last 128 texture events
with timestamp, frame, state, resource/id, placement, descriptor, pending fence
and upload offset/size. Corrupt-at-creation tables also dump the history. Events
cover ordinary texture/light-table/palette uploads and retirement, LUT creation
and upload, captures, screen and present copies, wipe-mask/fade-map uploads,
render-target creation/deletion and flushes. Diagnostic readbacks themselves do
not enter the history: they write only READBACK buffers and would displace the
texture writes being investigated. Present resources are committed/shared
resources, outside the placement arena.

The switch `kLightTableDiagnostics` was true in the build that produced the
failing logs. It is false by default now. With it on, expected and previous
GPU snapshots cost about 66 KiB per live table. A creation adds two covering
submissions; periodic readback adds one per live table. Every wait is bounded at
500 ms. Submissions and waits can change the timing and suppress reproduction;
a clean session alone does not establish a fix.

## Code-reading audit (historical)

This audit predates the 4 KB guard. Where it describes the size-class arena, it
means the power-of-two version, not the current quarter-octave classes.

No definite corruption cause was found. Ranked hypotheses consistent with the
actual GPU readback failure:

1. **Upload/staging/footprint behavior specific to Xbox.** `UploadTexture` obtains
   all footprints from `GetCopyableFootprints`, copies each CPU row using the
   returned pitch and row size, then adds the staging allocation offset. The
   texture ring tags the allocation with the pending copy fence and waits before
   reuse. No arithmetic error or premature reuse was found, and native allocator
   fuzzing has already passed. A `reason=create` mismatch would narrow the next
   investigation to this upload, its placed resource, or Xbox copy behavior.
2. **Later write through placement overlap or reuse/aliasing.** This can explain
   a table that matches at creation and changes later. The size-class arena uses
   disjoint live blocks and fence-delayed recycling; new placed resources receive
   an aliasing barrier before use. No overlapping live allocation was found.
   Forcing 64 KB placement did not help, so small placement is not established
   as a cause. The recorded heap/offset/block ranges and copy destinations let
   the Xbox log identify adjacent or reused allocations without assuming one.
3. **Resource-selection or creation failures.** `CreateLightTable` returns zero
   on storage failure and `SetLightTable(0)` leaves the previous binding intact.
   SRV exhaustion or an allocation failure could produce a wrong surface, but
   cannot explain corrupted bytes read from a known live table. An update upload
   failure preserves old data; the failing session reported zero updates, so
   this is not a leading explanation for that session.

### Every copy destination

Within `src/hardware/r_d3d12`:

- `r_d3d12.cpp::UploadTexture`: destination is the supplied `GpuTexture.res`,
  subresource for each mip. Callers include ordinary textures, light-table
  creation/update, screen/master palettes, sine table, wipe mask and fade maps.
  Only light-table creation/update (and the deliberate test hook) explicitly
  write a light-table resource.
- `d3d12_palette.inc::UploadPaletteLookup`: `g_paletteLookup`, its single 3D
  subresource, from the staging ring.
- `d3d12_screens.inc::CopyScreenInto`: ordinary saved-screen/wipe/final textures
  or `g_fadeScreen`, copied from `g_rt`.
- `d3d12_captures.inc::CopyRenderTargetRegion`: `g_waterScene` or `g_fogScene`,
  copied from `g_rt` into the bounded region. Capture bounds are clamped.
- `r_d3d12.cpp::ReadRectFrom`: cached READBACK buffer from `g_rt` or the palette
  post target. `d3d12_paletteprobe.inc::CopyPaletteProbeTexel` and
  `ReadLightTable`: temporary READBACK buffers. Light tables are sources here.
- `d3d12_present.cpp::Present_Frame`: present slot READBACK buffer via
  `CopyTextureRegion`, or committed/shared present slot via `CopyResource`.
- D3D11 interop `CopyResource` sites: `d3d12_present.cpp::CheckContent` writes its
  legacy/shared intermediate and staging buffer; presentation writes
  `shown.legacy`; `d3d12_interop.cpp::ReadPixel` writes the probe's legacy and
  staging resources. These do not share the texture arena.
- There are no executable `CopyBufferRegion` calls in this driver (only its
  diagnostic breadcrumb name). No UAV/compute texture writes exist.

### Every draw/clear destination

- `r_d3d12.cpp::DrawUploaded`, `DrawFanUploaded`, `D3D12_ResetPortalDepth`, and
  `d3d12_models.inc::DrawMesh`, `D3D_RenderSkyDome`: `g_rt` (screen RTV), with
  `g_depth` when enabled. Portal apertures use the ordinary draw path/stencil.
- `d3d12_screens.inc::EndFullscreenPass`: `g_rt` for wipe and fade-map draws.
  Screen redraw and post-image quads use `DrawArrays` and thus `g_rt`.
- `d3d12_palette.inc::PalettePostprocess`: `g_postTexture` (post RTV), no DSV.
- Screen clear sites write `g_rt`; depth/stencil clears write `g_depth`.
  `d3d12_present.cpp::CheckContent` and `d3d12_interop.cpp::Clear` clear
  their committed interop probe target through the scratch RTV.
- `d3d12_present.cpp::DrawToWindow` is ANGLE's GL draw into its window surface.

Light tables have no render-target/UAV flags and are never draw destinations.
Screen/capture/fade-map code cannot explicitly name a light table as its copy
or draw destination. Any cross-resource write would require a placement,
lifetime or driver problem rather than an intended table write.

### All GpuTexture value transfers and retirement

- `CreateTextureStorage` creates a local `replacement`, retires the destination,
  then assigns `*texture = replacement`. `ComPtr` shares the resource during the
  transfer; the local destructor releases only its COM reference, and never
  frees the block or SRV. The destination becomes the sole retirement owner.
- `CreateLightTable` transfers its local `LightTable` into `g_lightTables[id]`
  by value (`std::move` here). The moved-from local is never retired. Map rehash
  preserves element pointers/references. Clear nulls `g_currentLightTable`,
  retires each value exactly once, then erases the map.
- `CreatePaletteLookup` assigns local `lookup` into `g_paletteLookup`; the local
  again only releases a COM reference. It is created only when absent. Screen
  and master palettes use `CreateTextureStorage`/in-place upload, not separate
  retirement-owning copies.
- Captures, palette post target, wipe mask and fade screen are globals operated
  on by reference. `FadeMap.texture` is held by value inside its map node;
  replacement retires that member before assignment, and shutdown retires the
  values before clearing the map. No second live retirement owner was found.
- `Core_Retire(ComPtr<T>&)` in `d3d12_core.h` resets the caller after storing a
  deferred COM reference. The by-value `IUnknown` implementation alone is not
  the overload used for these texture calls. Thus capture recreation cannot
  reuse a retired pointer merely because dimensions still match.
- `RetireTexture` clears the block/SRV/byte accounting. A repeated call sees a
  null resource and returns. Block and descriptor frees use `Core_PendingFence`;
  collection waits for `Core_CompletedFence`.

The audit also checked cached b0 constants: ordinary/indexed/portal draws call
`g_constantRing.Touch` before recording their draw; the absence of a Touch
inside `ApplyConstants` alone is not a lifetime bug. Root/descriptor caches
reset when a list opens and after fullscreen passes. The existing WARP tiny-ring
scenes exercise these paths. None of these findings justifies a rendering fix
for the reported GPU-memory corruption yet.

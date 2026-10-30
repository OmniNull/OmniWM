# Spike: Camera-Based Spatial Overview for OmniWM / OmniShell

## Implementation status

This is a design spike. `SpatialCameraViewport.swift` and its unit tests implement the transform, anchor rebasing, scale bounds and settlement-target model. The production Overview controller and gesture recognizer do not use that model yet. Camera-layer composition, global pinch recognition and native focus settlement below are proposed integration work. The 120 fps and zero-AX-during-tracking figures are acceptance targets, not measured results.

## Executive Summary & Background

Modern window managers like Sunlight demonstrate an "infinite canvas" or camera-based paradigm:
- Windows keep fixed native geometries without expensive accessibility (`kAXPositionAttribute`, `kAXSizeAttribute`) reflows during continuous interaction.
- Trackpad pinch-to-zoom and two-finger pan scale and translate a virtual 2D camera viewport at native display refresh rates (up to 120fps via Metal / CoreAnimation).
- Zooming out transitions from a 1:1 focused window into a spatial birds-eye overview with window clusters; zooming in or clicking a target window springs smoothly back to 1:1 focus.

In OmniWM, workspace transitions and layout recalculations currently trigger accessibility queries and mutations. The goal of this spike is to evaluate a camera-based overview architecture for OmniWM and OmniShell with **zero accessibility reflow during continuous gesture tracking** and a 120 fps target on suitable displays. Integration and measurements are still needed to establish those properties.

---

## 1. Audit: Window Rendering & Proxy Capture Hooks

### Existing Codebase Subsystems
OmniWM already contains robust subsystems for window proxying and overlay composition:

1. **`OverviewThumbnailCapture` / `OverviewPreviewStream` / `PreviewCaptureCoordinator`**:
   - Location: `Sources/OmniWM/Core/Overview/`
   - Mechanism: Employs Apple's `ScreenCaptureKit` (`SCStream`) targeting individual `SCWindow` instances.
   - Pipeline: `SCStream` outputs `CMSampleBuffer`s; `CMSampleBufferGetImageBuffer` extracts the `CVPixelBuffer`; `CVPixelBufferGetIOSurface` extracts the hardware `IOSurface`.
   - Composition: The `IOSurface` is assigned directly to `CALayer.contents` (`thumbnail.contents = frame.surface`). This provides zero-copy, GPU-backed textures directly inside CoreAnimation without CPU pixel copying.
   - Resource Management: `PreviewCaptureCoordinator` enforces memory pressure limits (`DispatchSourceMemoryPressure`), LRU caching, and pinned preview lifecycles.

2. **Live Wallpaper Capture**:
   - Location: `Sources/OmniWM/Core/SkyLight/SkyLight+WallpaperCapture.swift`
   - Mechanism: Uses the private SkyLight function `SLSHWCaptureWindowList` with flags `(1 << 11) | (1 << 9) | (1 << 19)` to capture the exact rendered wallpaper window beneath desktop icons, cropping to the target display rect.

3. **Overlay Presentation Panels**:
   - Location: `OverviewWindow.swift`, `WorkspaceSwipePreview.swift`
   - Mechanism: Non-activating, transparent `NSPanel`s configured at `.screenSaver` level with `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`.
   - Behavior: Floats above all native windows and macOS Spaces, ignoring mouse events during passive swipes or accepting direct input during interactive overview sessions.

### SkyLight Window Transforms vs. CoreAnimation Overlay Layer Scene

The design considers two mechanisms for scaling live windows. The table records the proposed tradeoffs; the viewport-model tests do not validate WindowServer transforms or an integrated overlay scene:

| Evaluation Criterion | SkyLight Private Window Transforms (`SLSSetWindowTransform`) | CoreAnimation Overlay Layer Scene (`ScreenCaptureKit` + `IOSurface`) |
| :--- | :--- | :--- |
| **APIs** | `CGSSetWindowTransform`, `SLSSetWindowTransformAtPlacement` | `NSPanel`, `CALayer`, `IOSurface`, `ScreenCaptureKit` |
| **Input Routing** | Must validate whether hit-tests follow transformed geometry; otherwise clicks miss scaled targets. | The proposed overlay owns hit-testing and maps coordinates through the camera's inverse transform. |
| **Redraw / Flush Sync** | Must validate transform persistence while client apps flush surfaces. | Existing previews provide IOSurface frames; scene updates and transition continuity still need integration tests. |
| **Cross-Space Visibility** | Requires validation for windows on inactive native Spaces. | The existing capture discovery requests off-screen windows, but this does not guarantee a usable preview for every inactive-Space or fullscreen window. Validate those cases on the target macOS version. |
| **AX Mutation Overhead** | A transform-only path aims to avoid AX frame writes. | The proposed tracking path changes proxy layers only; instrumentation must verify zero AX calls. |
| **Security & Sandbox** | Requires undocumented WindowServer SPI and internal connection IDs; susceptible to OS breaks. | Uses public `ScreenCaptureKit` and documented CoreAnimation primitives. |

#### Cross-Process CoreAnimation Layer Clones (`CAContext` / `CALayerHost`)
This repository has no cross-process `CAContext`/`CALayerHost` integration for foreign application windows. The proposed camera therefore reuses the existing ScreenCaptureKit preview path; cross-process layer hosting would require separate investigation and a supported way to obtain the foreign layer context.

#### Architectural Verdict
The proposed integration uses a **CoreAnimation Overlay Layer Scene backed by `ScreenCaptureKit` / `IOSurface` textures**, reusing OmniWM's existing preview path. Input routing, capture availability, focus restoration and performance still need end-to-end validation before treating the camera mode as production-ready.

---

## 2. Audit: Trackpad Pinch & Magnify Ingestion

### Current Ingestion Architecture
OmniWM's input system currently ingests gestures through two layers:
1. **Low-Level Multitouch**: `MultitouchGestureSource.swift` links `MultitouchSupport.framework` to register `MTRegisterContactFrameCallback`. It gathers raw finger contacts (`RawTouch`) into `GestureEventSnapshot` with normalized `(x, y)` positions and finger counts.
2. **Recognition & Dispatch**: `MouseEventHandler+TrackpadRecognition.swift` evaluates multi-finger thresholds:
   - 3/4-finger scroll: `columnScroll`
   - 2/3/4-finger swipe: `workspaceSwitch` (horizontal / vertical)
   - 2/3/4-finger drag: window move / resize
   - 3/4-finger vertical swipe: `overview` (open, close, resume)
3. **Continuous Transform Tracking**: `ShellGestureTrack.swift` maps continuous gesture progress through rational rubber-band curves and velocity derivatives to produce `ShellGestureTransform` (`dx`, `dy`, `scale`, `opacity`).

Currently, pinch gestures (`NSEvent.EventType.magnify`) and two-finger double taps (`NSEvent.EventType.smartMagnify`) are not intercepted.

### Ingestion Strategy for Spatial Camera Gestures

A spatial camera requires continuous tracking of both **scale** ($s$) and **focal center translation** $(dx, dy)$. The proposed integration uses two complementary ingestion pipelines; neither is connected to the viewport model yet:

#### Pipeline A: Global Multitouch Recognition (Pinch-In from 1:1 Desktop)
When the user is in normal 1:1 window management (overview overlay not yet active), AppKit does not route `.magnify` events to OmniWM because OmniWM is not the key/active application.
- `MultitouchGestureSource` receives raw two-finger touch contacts:
  $$\vec{p}_1 = (x_1, y_1), \quad \vec{p}_2 = (x_2, y_2)$$
- At gesture begin, when the active count reaches two from fewer (`previousActiveCount < 2`, `activeCount == 2`, so fingers landing in separate frames still start it):
  $$d_0 = \|\vec{p}_2 - \vec{p}_1\|, \quad \vec{c}_0 = \frac{\vec{p}_1 + \vec{p}_2}{2}$$
- During continuous tracking:
  $$s_{\text{raw}} = \frac{d}{d_0}, \quad \Delta \vec{c} = \vec{c} - \vec{c}_0$$
- When $s_{\text{raw}} < 0.98$ and fingers are moving inward (pinch-in gesture), OmniWM latches the spatial camera gesture, immediately revealing the overlay camera viewport.

#### Pipeline B: Active Overview View Ingestion (Pinch & Pan in Overview)
Once the overview panel is active and tracking:
- `OverviewView` overrides `magnify(with event: NSEvent)`:
  - `event.magnification` provides the incremental scale factor $\Delta s$.
  - `event.phase` (`.began`, `.changed`, `.ended`, `.cancelled`) directly drives the camera viewport.
- `OverviewView` overrides `scrollWheel(with event: NSEvent)`:
  - Two-finger pan translates the camera viewport $(dx, dy)$.
- `OverviewView` overrides `smartMagnify(with event: NSEvent)`:
  - Two-finger double-tap toggles between overview overview scale and 1:1 focus on the hovered window.

### Camera Viewport Mathematics & Projection

The 2D camera viewport transform maps world/desktop coordinates $(x, y)$ to screen coordinates $(x', y')$ using a scale $s$, anchor $(a_x, a_y)$ (the gesture focal center), and translation $(t_x, t_y)$:

$$x' = (x - a_x) \cdot s + a_x + t_x$$
$$y' = (y - a_y) \cdot s + a_y + t_y$$

In CoreAnimation matrix form (`CGAffineTransform` / `CATransform3D`):
```swift
CGAffineTransform(translationX: anchor.x + translation.x, y: anchor.y + translation.y)
    .scaledBy(x: scale, y: scale)
    .translatedBy(x: -anchor.x, y: -anchor.y)
```

#### Rubber-Banding Resistance
Outside the nominal range $s \in [s_{\min}, s_{\max}]$ (e.g., $0.20 \dots 1.00$), rational hyperbolic damping is applied from the nearest bound:
$$\text{overflow} = s_{\text{raw}} - s_{\max}, \quad s_{\text{clamped}} = s_{\max} + \frac{\text{overflow} \cdot r}{1 + \text{overflow}} \quad (s_{\text{raw}} > s_{\max})$$
$$\text{underflow} = s_{\min} - s_{\text{raw}}, \quad s_{\text{clamped}} = s_{\min} - \frac{\text{underflow} \cdot r}{1 + \text{underflow}} \quad (s_{\text{raw}} < s_{\min})$$
where $r \approx 0.35$ is the rubber-band resistance coefficient. The raw gesture scale is floored at $0.01$ before damping, so the lower branch stays positive.

---

## 3. Architecture & Implementation Plan

### Component Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Input Intake                           │
│  - MultitouchGestureSource (raw 2-finger distance d/d0)      │
│  - OverviewView.magnify(with:) / scrollWheel(with:)         │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                  SpatialCameraViewport                      │
│  - Camera scale (0.2 ... 1.0) & translation (dx, dy)        │
│  - Hyperbolic rubber-band damping                          │
│  - Affine 2D projection matrix & unproject hit-testing      │
│  - Velocity-aware settlement target resolution             │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│            Spatial Camera Scene & Compositor                │
│  - Fullscreen transparent NSPanel (.screenSaver level)      │
│  - Root Camera CALayer with CATransform3D                   │
│  - Clustered Workspace & Window Proxy Sublayers             │
│  - Zero-copy IOSurface contents from ScreenCaptureKit       │
└──────────────────────────────┬──────────────────────────────┘
                               │
                Gesture Settle │ (Only on gesture completion)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│            Native Focus & Space Settlement                  │
│  - CASpringAnimation settles camera to target               │
│  - Single AX/SkyLight focus transfer (_SLPSSetFrontProcess)  │
│  - Dismiss overlay panel                                    │
│  - Zero AX reflows while fingers are moving                 │
└─────────────────────────────────────────────────────────────┘
```

### Phase 1 Minimal Working Implementation (Spike)

#### 1. Core Model (`SpatialCameraViewport`)
- Implemented in `Sources/OmniWM/Core/Overview/SpatialCameraViewport.swift`.
- Encapsulates:
  - `SpatialCameraTransform`: `scale`, `translation`, `anchor`, and computed `affineTransform` / `caTransform3D`.
  - `project(rect:)` / `unproject(point:)`: forward and inverse coordinate mapping for hit-testing and layout.
  - `applyRubberBanding`: rational resistance curves below $0.20$ and above $1.00$.
  - `endGesture(velocity:)`: resolves settlement destination (`.focusedWindow` vs. `.overviewGrid`).
- Verified with unit tests in `Tests/OmniWMTests/SpatialCameraViewportTests.swift`.

#### 2. Overlay Scene Setup (Proposed)
- Instantiate a dedicated camera root layer `cameraLayer = CALayer()` hosted inside the overview panel.
- On gesture start, populate `cameraLayer` with existing `OverviewWindowLayer` instances configured with `IOSurface` previews from `OverviewThumbnailCapture`.
- Apply camera transforms directly to `cameraLayer.transform = viewport.current.caTransform3D`. Sublayers inherit the transform without per-layer frame recalculation.

#### 3. Gesture Lifecycle & Zero-AX Contract (Proposed)
1. **Began**:
   - Two-finger pinch inwards detected.
   - Capture current focused window and cursor position as camera anchor.
   - Show overlay panel (`level = .screenSaver`, `alpha = 1.0`).
   - Native windows remain completely stationary in WindowServer; no AX calls issued.
2. **Changed**:
   - Update `viewport.updateMagnify(delta:)` and `viewport.updatePan(delta:)`.
   - Update `cameraLayer.transform` at 120Hz inside a disabled actions `CATransaction`.
   - Hit-test hovered window proxy by unprojecting pointer coordinates: `viewport.current.unproject(point: pointer)`.
3. **Ended**:
   - `viewport.endGesture(velocity:)` determines target:
     - Target `.overviewGrid`: camera springs smoothly to overview layout position ($s \approx 0.35$).
     - Target `.focusedWindow`: camera springs smoothly to focused window bounds ($s = 1.0$, translation = $0$).
   - Run `CASpringAnimation` (matching `OverviewNativeTransition` response and damping).
4. **Settled**:
   - If settling on `.focusedWindow`:
     - Hide overlay panel.
     - Call `_SLPSSetFrontProcessWithOptions` / `makeKeyWindow` once to commit focus.
   - If settling on `.overviewGrid`:
     - Keep overlay panel key to allow keyboard navigation, search, and window activation.

---

## 4. Technical Constraints & Mitigation

1. **Screen Recording Permission**:
   - `ScreenCaptureKit` requires screen recording authorization.
   - *Proposed mitigation*: Use `ScreenCapturePermissionMonitor.shared` and preserve the existing Overview fallback to app icons without window pictures. Verify camera transitions with permission absent or revoked.
2. **GPU Memory Footprint**:
   - Holding full-resolution `IOSurface` textures for dozens of windows across spaces can consume GPU VRAM.
   - *Proposed mitigation*: Reuse `PreviewCaptureCoordinator`, which observes memory pressure and trims unpinned retained previews against the largest registered capture budget (`OverviewThumbnailCapture` defaults to 128 MiB). Pinned presenting frames can exceed that budget, so it is not a hard cap on total GPU use. Measure the camera scene's live streams and retained textures separately.
3. **Multi-Monitor Display Topologies**:
   - Displays with different scales (e.g., Retina 2x vs. external 1x) require separate camera layer roots.
   - *Proposed mitigation*: Give each `Monitor` an independent `SpatialCameraViewport` synchronized to its active display bounds.

---

## 5. Verification & Testing Strategy

1. **Unit Testing**:
   - Invariant anchor verification: anchor point coordinates remain fixed in screen space during zoom.
   - Inverse projection accuracy: `unproject(project(p)) == p`.
   - Rubber-banding boundary limits: verified damped behavior outside $[0.2, 1.0]$.
   - Velocity-assisted settlement: flick gestures correctly override position thresholds.
   - Run via: `swift test --filter SpatialCameraViewportTests`.
2. **Performance Budget (not yet measured)**:
   - Gesture frame time budget: $\le 8.33\,\text{ms}$ (120fps on ProMotion displays).
   - AX call count during gesture: **strictly 0**.

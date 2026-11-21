# Spike: Camera-Based Spatial Overview for OmniWM / OmniShell

## Executive Summary & Background

Modern window managers like Sunlight demonstrate an "infinite canvas" or camera-based paradigm:
- Windows keep fixed native geometries without expensive accessibility (`kAXPositionAttribute`, `kAXSizeAttribute`) reflows during continuous interaction.
- Trackpad pinch-to-zoom and two-finger pan scale and translate a virtual 2D camera viewport at native display refresh rates (up to 120fps via Metal / CoreAnimation).
- Zooming out transitions from a 1:1 focused window into a spatial birds-eye overview with window clusters; zooming in or clicking a target window springs smoothly back to 1:1 focus.

In OmniWM, workspace transitions and layout recalculations currently trigger accessibility queries and mutations. The goal of this spike is to evaluate and design a camera-based overview architecture for OmniWM and OmniShell that guarantees **zero accessibility reflow during continuous gesture tracking**, maintaining 120fps fluid interaction.

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

We evaluated two technical mechanisms for scaling live windows:

| Evaluation Criterion | SkyLight Private Window Transforms (`SLSSetWindowTransform`) | CoreAnimation Overlay Layer Scene (`ScreenCaptureKit` + `IOSurface`) |
| :--- | :--- | :--- |
| **APIs** | `CGSSetWindowTransform`, `SLSSetWindowTransformAtPlacement` | `NSPanel`, `CALayer`, `IOSurface`, `ScreenCaptureKit` |
| **Input Routing** | **Broken.** WindowServer continues to route hit-tests to untransformed client geometry. Clicks miss scaled visual targets. | **Controlled.** The overlay panel absorbs events and maps coordinates via camera inverse transform. |
| **Redraw / Flush Sync** | **Unstable.** When client apps flush surfaces (e.g., terminal cursor blink, WebKit paint), the WindowServer transform flickers or resets. | **Stable.** Textures are sampled as GPU streams; client app background updates do not corrupt the viewport scene. |
| **Cross-Space Visibility** | **Unsupported.** Windows residing on inactive macOS Spaces cannot be rendered together without moving spaces. | **Supported.** `ScreenCaptureKit` captures windows across any space or display context simultaneously. |
| **AX Mutation Overhead** | Zero AX mutations during transform, but fragile WindowServer state. | **Zero AX mutations.** Window frames remain completely untouched until settlement. |
| **Security & Sandbox** | Requires undocumented WindowServer SPI and internal connection IDs; susceptible to OS breaks. | Uses public `ScreenCaptureKit` and documented CoreAnimation primitives. |

#### Cross-Process CoreAnimation Layer Clones (`CAContext` / `CALayerHost`)
Cross-process layer hosting on macOS requires the hosting application to export a `CAContext` identifier (`CAContext.contextId`). Third-party macOS applications (Electron, AppKit, Metal) do not export `CAContext` handles to external window managers. Therefore, cross-process layer cloning is impossible without app-level code injection.

#### Architectural Verdict
Direct SkyLight window transformation is rejected due to input hit-testing dissociation, surface redraw tearing, and cross-space limitations. The **CoreAnimation Overlay Layer Scene backed by `ScreenCaptureKit` / `IOSurface` textures** is the superior, stable, and production-viable architecture.

---

## 2. Audit: Trackpad Pinch & Magnify Ingestion

### Current Ingestion Architecture
OmniWM's input system currently ingests gestures through two layers:
1. **Low-Level Multitouch**: `MultitouchGestureSource.swift` links `MultitouchSupport.framework` to register `MTRegisterContactFrameCallback`. It gathers raw finger contacts (`RawTouch`) into `GestureEventSnapshot` with normalized `(x, y)` positions and finger counts.
2. **Recognition & Dispatch**: `MouseEventHandler+TrackpadRecognition.swift` evaluates multi-finger thresholds:
   - 2-finger scroll: `columnScroll`
   - 3/4-finger swipe: `workspaceSwitch` (horizontal / vertical)
   - 3/4-finger drag: window move / resize
   - 3/4-finger vertical swipe: `overview` (open, close, resume)
3. **Continuous Transform Tracking**: `ShellGestureTrack.swift` maps continuous gesture progress through rational rubber-band curves and velocity derivatives to produce `ShellGestureTransform` (`dx`, `dy`, `scale`, `opacity`).

Currently, pinch gestures (`NSEvent.EventType.magnify`) and two-finger double taps (`NSEvent.EventType.smartMagnify`) are not intercepted.

### Ingestion Strategy for Spatial Camera Gestures

A spatial camera requires continuous tracking of both **scale** ($s$) and **focal center translation** $(dx, dy)$. Two complementary ingestion pipelines are used:

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
- The [prototype model](https://github.com/OmniNull/OmniWM/blob/aa407e4e05c3a4b88fe0026d532ceb78e603ab1e/Sources/OmniWM/Core/Overview/SpatialCameraViewport.swift) was archived before integration with Overview.
- Encapsulates:
  - `SpatialCameraTransform`: `scale`, `translation`, `anchor`, and computed `affineTransform` / `caTransform3D`.
  - `project(rect:)` / `unproject(point:)`: forward and inverse coordinate mapping for hit-testing and layout.
  - `applyRubberBanding`: rational resistance curves below $0.20$ and above $1.00$.
  - `endGesture(velocity:)`: resolves settlement destination (`.focusedWindow` vs. `.overviewGrid`).
- The [prototype tests](https://github.com/OmniNull/OmniWM/blob/aa407e4e05c3a4b88fe0026d532ceb78e603ab1e/Tests/OmniWMTests/SpatialCameraViewportTests.swift) cover gesture updates and settlement.

#### 2. Overlay Scene Setup
- Instantiate a dedicated camera root layer `cameraLayer = CALayer()` hosted inside the overview panel.
- On gesture start, populate `cameraLayer` with existing `OverviewWindowLayer` instances configured with `IOSurface` previews from `OverviewThumbnailCapture`.
- Apply camera transforms directly to `cameraLayer.transform = viewport.current.caTransform3D`. Sublayers inherit the transform without per-layer frame recalculation.

#### 3. Gesture Lifecycle & Zero-AX Contract
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
   - *Mitigation*: OmniWM already monitors this via `ScreenCapturePermissionMonitor.shared`. When ungranted, fallback renders clean window wireframes/app icons with zero crash risk.
2. **GPU Memory Footprint**:
   - Holding full-resolution `IOSurface` textures for dozens of windows across spaces can consume GPU VRAM.
   - *Mitigation*: Reuses `PreviewCaptureCoordinator`, which subscribes to system memory pressure notifications (`DispatchSourceMemoryPressure`) to prune unpinned textures and caps retained bytes (default 128 MB).
3. **Multi-Monitor Display Topologies**:
   - Displays with different scales (e.g., Retina 2x vs. external 1x) require separate camera layer roots.
   - *Mitigation*: Each `Monitor` receives an independent `SpatialCameraViewport` synchronized to its active display bounds.

---

## 5. Verification & Testing Strategy

1. **Unit Testing**:
   - Invariant anchor verification: anchor point coordinates remain fixed in screen space during zoom.
   - Inverse projection accuracy: `unproject(project(p)) == p`.
   - Rubber-banding boundary limits: verified damped behavior outside $[0.2, 1.0]$.
   - Velocity-assisted settlement: flick gestures correctly override position thresholds.
   - Run `swift test --filter SpatialCameraViewportTests` at the archived revision (`aa407e4e`).
2. **Performance Budget**:
   - Gesture frame time budget: $\le 8.33\,\text{ms}$ (120fps on ProMotion displays).
   - AX call count during gesture: **strictly 0**.

-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

export type Color = string | number
export type Motion = "none" | "spring" | "bouncy" | "smooth" | "ease"
export type Material = "none" | "ultraThin" | "thin" | "regular" | "thick" | "ultraThick" | "bar" | "popover" | "glass" | "clear"
export type TextStyle = "body" | "bold" | "mono" | "small" | "caption" | "rounded"
export type Font = "system" | "sans" | "rubik" | "symbols"
export type Weight = "ultraLight" | "thin" | "light" | "regular" | "medium" | "semibold" | "bold" | "heavy" | "black"
export type Align =
    "center"
    | "leading"
    | "trailing"
    | "top"
    | "bottom"
    | "topLeading"
    | "topTrailing"
    | "bottomLeading"
    | "bottomTrailing"
export type Element = { kind: number }
export type Curve = "linear" | "easeIn" | "easeOut" | "easeInOut" | "back"
    | "standard" | "standardAccel" | "standardDecel" | "emphasized" | "emphasizedAccel" | "emphasizedDecel"
    | "fastSpatial" | "spatial" | "slowSpatial" | "fastEffects" | "effects" | "slowEffects" | { number }
export type Animate = Motion | Curve | number | { duration: number?, curve: Curve? } | { response: number, bounce: number? }
export type Presence = { opacity: number?, scale: number?, dx: number?, dy: number?, animate: Animate? }
export type GestureRange = { number } & { rubber: number? }
export type Enter = {
    opacity: number?,
    scale: number?,
    dx: number?,
    dy: number?,
    from: number?,
    to: number?,
    curve: Curve?,
    stretch: number?,
    d: string?,
}

export type BarWindow = {
    id: string,
    title: string,
    focused: boolean,
    hidden: boolean,
}

export type BarItem = {
    id: string,
    bundle: string,
    name: string,
    focused: boolean,
    count: number,
    hidden: number,
    badge: string,
    floating: boolean,
    windows: { BarWindow },
}

export type BarWorkspace = {
    id: string,
    name: string,
    focused: boolean,
    windows: { BarItem },
}

export type BarScratchpad = {
    compact: boolean,
    id: number,
    name: string,
    focused: boolean,
    revealed: boolean,
    visible: boolean,
    windows: { BarItem },
}

export type BarStyle = {
    height: number,
    labels: boolean,
    backgrounds: boolean,
    accents: boolean,
    inactive: number,
    position: "overlappingMenuBar" | "belowMenuBar" | "bottom" | "left" | "right" | "top",
    vertical: boolean,
    notch: string,
    notchWidth: number,
    level: string,
    offsetX: number,
    offsetY: number,
    autoHide: boolean,
    reveal: string,
    opacity: number,
    transparent: boolean,
    solidBlack: boolean,
    accentColor: string?,
    textColor: string?,
    statsButton: boolean,
    secureInput: boolean,
    previews: boolean,
    hideInFullscreen: boolean,
}

export type HiddenBarItem = {
    id: string,
    name: string,
    image: string?,
    w: number,
    h: number,
}

export type HiddenBarMenuRow = {
    id: string,
    title: string,
    enabled: boolean,
    mark: string,
    shortcut: string,
    submenu: boolean,
    separator: boolean,
}

export type HiddenBarMenu = {
    title: string,
    backID: string?,
    rows: { HiddenBarMenuRow },
}

export type HiddenBar = {
    enabled: boolean,
    available: boolean,
    rehide: number,
    items: { HiddenBarItem },
    maxWidth: number,
    maxHeight: number,
    cell: number,
    vertical: boolean,
    menu: HiddenBarMenu?,
}

export type BarDrag = {
    sources: { string },
    workspaces: { string },
    icons: { string },
    gaps: { { workspace: string, before: number } },
}

export type Bar = {
    monitor: string,
    island: "all" | "active" | "secondary",
    drag: BarDrag?,
    badges: "off" | "dot" | "text",
    style: BarStyle,
    workspaces: { BarWorkspace },
    scratchpads: { BarScratchpad },
}

export type Workspace = {
    id: string,
    name: string,
    focused: boolean,
    visible: boolean,
    windows: number,
}

export type AudioOutput = {
    id: string,
    name: string,
    transport: "builtin" | "usb" | "bluetooth" | "hdmi" | "displayport" | "airplay" | "thunderbolt" | "virtual"
        | "aggregate" | "other",
    default: boolean,
}

export type AudioApp = {
    id: string,
    name: string,
    playing: boolean,
    volume: number,
    muted: boolean,
}

export type AudioApps = {
    access: "unknown" | "granted" | "denied",
    apps: { AudioApp },
}

export type Media = {
    title: string,
    artist: string,
    album: string,
    app: string,
    bundle: string,
    pid: number,
    playing: boolean,
    duration: number?,
    elapsed: number?,
    rate: number,
    sampledAt: number,
    artwork: string?,
    shuffle: boolean?,
    repeatMode: ("off" | "one" | "all")?,
}

export type CalendarEvent = {
    id: string,
    title: string,
    calendar: string,
    color: string,
    start: number,
    ["end"]: number,
    allDay: boolean,
    location: string?,
    time: string,
    day: string,
}

export type CalendarMonth = {
    title: string,
    year: number,
    month: number,
    days: number,
    offset: number,
    today: number,
    weekdays: { string },
    marked: { number },
}

export type Calendar = {
    access: "full" | "writeOnly" | "denied" | "restricted" | "notDetermined",
    events: { CalendarEvent },
    month: CalendarMonth?,
}

export type Reminder = {
    id: string,
    title: string,
    list: string,
    color: string,
    due: number?,
    allDay: boolean,
    priority: number,
    canComplete: boolean,
}

export type Reminders = {
    access: "full" | "writeOnly" | "denied" | "restricted" | "notDetermined",
    items: { Reminder },
    total: number,
    truncated: boolean,
    error: string?,
}

export type WeatherHour = {
    time: number,
    code: number,
    label: string,
    temp: number,
    condition: string,
    symbol: string,
    day: boolean,
    rain: number?,
}

export type WeatherDay = {
    time: number,
    code: number,
    label: string,
    high: number,
    low: number,
    condition: string,
    symbol: string,
    rain: number?,
}

export type Weather = {
    temp: number,
    feels: number?,
    high: number?,
    low: number?,
    rain: number?,
    wind: number?,
    humidity: number?,
    sunrise: number?,
    sunset: number?,
    code: number,
    day: boolean,
    unit: string,
    condition: string,
    symbol: string,
    place: string?,
    status: "ok" | "stale",
    hours: { WeatherHour },
    days: { WeatherDay },
}

export type SystemDisplay = {
    w: number,
    h: number,
    hz: number,
}

export type System = {
    memory: { used: number, total: number, pressure: ("normal" | "warning" | "critical")? },
    disk: { used: number, total: number },
    uptime: number,
    host: { name: string, chip: string, model: string, os: string },
    displays: { SystemDisplay },
}

export type Power = {
    source: "ac" | "battery" | "ups",
    remaining: number?,
    full: number?,
    charged: boolean,
    lowPower: boolean,
    cycles: number?,
    health: number?,
    temperature: number?,
    watts: number?,
    adapter: number?,
}

export type InputSourceEntry = { id: string, name: string, short: string }

export type InputSource = {
    id: string,
    name: string,
    short: string,
    sources: { InputSourceEntry },
}

export type WiFi = {
    power: boolean,
    connected: boolean,
    ssid: string?,
    rssi: number?,
    band: string?,
    channel: number?,
    security: string?,
    location: "authorized" | "denied" | "restricted" | "notDetermined",
}

export type BluetoothDevice = {
    id: string,
    name: string,
    kind: "headphones" | "keyboard" | "mouse" | "gamepad" | "computer" | "phone" | "other",
    connected: boolean,
    battery: number?,
    left: number?,
    right: number?,
    case: number?,
}

export type Bluetooth = {
    power: boolean,
    access: "granted" | "denied" | "restricted" | "notDetermined",
    devices: { BluetoothDevice },
}

export type IslandNavigation = {
    workspace: string,
    name: string,
    layout: "niri" | "dwindle",
    focused: string?,
    windows: {
        {
            id: string,
            bundle: string,
            name: string,
            title: string,
            column: number,
        }
    },
}

export type Island = {
    display: string,
    size: { w: number, h: number },
    notch: { x: number, w: number, h: number }?,
    menuBar: number,
    scale: number,
    main: boolean,
    visible: boolean,
    fullscreen: boolean,
    focused: boolean,
    drag: { active: boolean, types: { "file" | "url" | "text" | "image" } },
    navigation: IslandNavigation?,
}

export type Data = {
    clock: string,
    date: string,
    seconds: number,
    cpu: number?,
    memory: number,
    battery: number?,
    charging: boolean,
    gpu: number?,
    disk: number?,
    network: { down: number, up: number }?,
    volume: number?,
    muted: boolean?,
    vars: { [string]: string },
    weather: Weather?,
    workspace: string,
    app: string,
    bundle: string,
    title: string,
    workspaces: { Workspace },
    bar: Bar,
    settings: { [string]: any }?,
    hiddenBar: HiddenBar,
    system: System?,
    outputs: { AudioOutput }?,
    audioApps: AudioApps?,
    media: Media?,
    calendar: Calendar?,
    power: Power?,
    inputSource: InputSource?,
    privacy: { microphone: boolean, camera: boolean }?,
    wifi: WiFi?,
    bluetooth: Bluetooth?,
    user: { name: string, account: string, avatar: string? }?,
    thermal: { cpu: number?, gpu: number?, gpuName: string? }?,
    networkHistory: { down: { number }, up: { number }, received: number, sent: number }?,
    appearance: ("light" | "dark")?,
    lyrics: { status: "loading" | "synced" | "none", lines: { { time: number, text: string } } }?,
    spectrum: { access: "unknown" | "granted" | "denied", bars: { number }, bpm: number? }?,
    tempo: number?,
    island: Island?,
    components: { ComponentInfo }?,
    catalog: { ComponentCatalogEntry }?,
    settingsSchema: { [string]: ComponentOption }?,
    reminders: Reminders?,
    badges: { [string]: string },
    menuApp: { pid: number, name: string, bundle: string }?,
}

export type Format = {
    number: (value: number, digits: number?) -> string,
    percent: (fraction: number, digits: number?) -> string,
    bytes: (count: number, style: ("memory" | "file")?) -> string,
    date: (seconds: number, template: string, zone: string?) -> string?,
    offset: (seconds: number, zone: string?) -> number?,
}

export type ComponentInfo = {
    id: string,
    widget: string,
    title: string,
    enabled: boolean,
    options: { [string]: ComponentValue },
    status: string,
    error: string?,
}

export type ComponentValue = boolean | number | string | { string }

export type ComponentOption = {
    type: "boolean" | "number" | "string" | "choice" | "strings",
    title: string,
    default: ComponentValue?,
    min: number?,
    max: number?,
    step: number?,
    maxLength: number,
    choices: { string },
}

export type ComponentCatalogEntry = {
    widget: string,
    title: string,
    icon: string,
    views: { string },
    options: { [string]: ComponentOption },
    source: string,
    overrides: { string },
    error: string?,
}

export type ConfigResult = {
    ok: boolean,
    id: string?,
    revision: number?,
    error: string?,
}

export type ConfigCallback = (result: ConfigResult) -> ()

export type ProviderState = {
    status: "stopped" | "starting" | "running" | "exited" | "failed",
    error: string?,
    exitCode: number?,
    state: { [string]: any },
}

export type ProviderResult = {
    files: { Resource }?,
    ok: boolean,
    value: any?,
    error: string?,
}

export type ProviderEvent = {
    kind: "event",
    name: string,
    value: any?,
}

export type ComponentInstance = {
    id: string,
    widget: string,
    options: { [string]: any },
    state: { [string]: any },
    provider: ProviderState,
}

export type ComponentActivity = {
    priority: number,
    since: number?,
    label: string?,
    views: { string }?,
    alert: any?,
}

export type Asset = string

export type Context = {
    data: Data,
    select: (key: string, ...(string | number)) -> any,
    state: { [string]: any },
    format: Format,
    instance: ComponentInstance?,
    view: { name: string, w: number?, h: number?, props: any? }?,
}

export type ResourceKind = "file" | "url" | "text" | "image"
export type Resource = {
    id: string,
    name: string,
    kind: ResourceKind,
    uti: string,
    size: number?,
    state: "pending" | "ready" | "failed",
    error: string?,
    persistence: { token: string, state: "pending" | "durable" | "failed", error: string? }?,
}
export type DesktopResult = { ok: boolean, error: string?, items: { Resource }? }
export type DesktopCallback = (result: DesktopResult) -> ()
export type DropEvent = { items: { Resource }, x: number, y: number }
export type DropHoverEvent = { phase: "entered" | "exited", types: { ResourceKind } }
export type DragOutEvent = { phase: "began" | "ended", operation: "copy" | "none" }

export type Event = {
    button: "left" | "right" | "middle" | "none",
    shift: boolean,
    option: boolean,
    control: boolean,
    command: boolean,
    dx: number,
    dy: number,
    precise: boolean,
    value: number?,
    phase: ("began" | "changed" | "ended" | "down" | "up" | "cancel" | "cancelled")?,
    x: number?,
    y: number?,
    clicks: number?,
    vx: number?,
    vy: number?,
    committed: boolean?,
    momentum: ("none" | "began" | "changed" | "ended")?,
    key: string?,
    characters: string?,
    text: string?,
    focused: boolean?,
    ["repeat"]: boolean?,
}

export type TriggerEvent = {
    source: "host"?,
    name: string,
    value: string?,
}

export type InputHandler = (ctx: Context, event: Event) -> ()
export type Click = string | InputHandler

export type Gesture = {
    track: { dx: GestureRange?, dy: GestureRange?, scale: GestureRange?, opacity: GestureRange? }?,
    axis: ("x" | "y" | "free" | "auto")?,
    source: ("pointer" | "scroll" | "both")?,
    threshold: number?,
    lockDistance: number?,
    dominance: number?,
    commit: { distance: number?, velocity: number?, direction: ("any" | "left" | "right" | "up" | "down")? }?,
}

export type Props = {
    accepts: { ResourceKind }?,
    onDrop: ((ctx: Context, event: DropEvent) -> ())?,
    onDropHover: ((ctx: Context, event: DropHoverEvent) -> ())?,
    dragItems: { Resource }?,
    onDragOut: ((ctx: Context, event: DragOutEvent) -> ())?,
    appear: Presence?,
    exit: Presence?,
    key: string?,
    rotate: number?,
    loop: { dx: { number }?, dy: { number }?, rotate: { number }?, paused: boolean? }?,
    trail: boolean?,
    w: number?,
    h: number?,
    grow: number?,
    gap: number?,
    pad: number?,
    center: boolean?,
    fill: Color?,
    material: Material?,
    blurRadius: number?,
    saturation: number?,
    bridge: boolean?,
    attach: boolean?,
    open: number?,
    close: number?,
    enter: Enter?,
    mask: boolean?,
    border: Color?,
    borderWidth: number?,
    radius: number?,
    opacity: number?,
    hover: Color?,
    hoverScale: number?,
    hoverOpacity: number?,
    help: string?,
    animate: Animate?,
    hoverAnimate: (Motion | number)?,
    hoverMaterial: Material?,
    onClick: Click?,
    onRightClick: Click?,
    onScroll: Click?,
    onPress: InputHandler?,
    pressScale: number?,
    pressOpacity: number?,
    pressFill: Color?,
    pressAnimate: Animate?,
    onHover: InputHandler?,
    hoverDelay: number?,
    hoverGrace: number?,
    gesture: Gesture?,
    onGesture: InputHandler?,
    gestureEvents: ("boundary" | "all")?,
    scrollMomentum: ("consume" | "deliver")?,
    focusable: boolean?,
    focusRing: boolean?,
    keys: { string }?,
    onKey: InputHandler?,
    onOutsidePress: InputHandler?,
    popout: boolean?,
    align: Align?,
    dx: number?,
    dy: number?,
    scale: number?,
    shadow: Color?,
    shadowRadius: number?,
    target: string?,
    menu: boolean?,
    preview: boolean?,
    drag: boolean?,
    drop: boolean?,
    scroll: boolean?,
    [number]: Element,
}

export type TextProps = Props & {
    text: string,
    style: TextStyle?,
    font: Font?,
    filled: boolean?,
    size: number?,
    weight: Weight?,
    maxWidth: number?,
    lines: number?,
    color: Color?,
    reserve: string?,
}

export type TextInputProps = Props & {
    key: string,
    text: string?,
    placeholder: string?,
    multiline: boolean?,
    maxLength: number?,
    focus: boolean?,
    style: TextStyle?,
    font: Font?,
    size: number?,
    weight: Weight?,
    color: Color?,
    onChange: InputHandler?,
    onCommit: InputHandler?,
    onCancel: InputHandler?,
    onFocus: InputHandler?,
}

export type SymbolProps = Props & {
    name: string,
    size: number?,
    weight: Weight?,
    color: Color?,
}

export type IconProps = Props & {
    app: string?,
    window: string?,
    pid: number?,
    placeholder: string?,
    color: Color?,
}

export type ImageProps = Props & {
    image: string | Resource,
    thumbnail: number?,
    playing: boolean?,
    speed: number?,
}

export type ProgressProps = Props & {
    value: number,
    color: Color?,
}

export type SliderProps = Props & {
    value: number,
    color: Color?,
    onChange: Click?,
}

export type PathProps = Props & {
    d: string,
    viewBox: { number }?,
    evenOdd: boolean?,
}

export type ShaderProps = Props & {
    source: string,
    texture: string?,
    values: { number }?,
    fps: number?,
    audio: boolean?,
}

export type ComponentProps = Props & {
    id: string,
    view: string,
    props: any?,
}

export type ServiceHandle = {
    cancel: (self: ServiceHandle) -> (),
}

export type HTTPRequest = {
    url: string,
    method: string?,
    headers: { [string]: string }?,
    body: (string | Resource)?,
    response: ("text" | "json" | "bytes")?,
    maxBytes: number?,
    timeout: number?,
}

export type HTTPResult = {
    ok: boolean,
    status: number,
    headers: { [string]: string },
    text: string?,
    json: any?,
    bytes: string?,
    error: string?,
}

export type StoreStatus = {
    state: "ready" | "pending" | "failed",
    revision: number,
    committedRevision: number,
    error: string?,
}

declare json: {
    null: any,
    encode: (value: any) -> (string?, string?),
    decode: (text: string) -> (any, string?),
}

declare omniwm: {
    resources: {
        persist: (resource: Resource, callback: ((result: { ok: boolean, token: string?, error: string? }) -> ())?) -> (string?, string?),
        restore: (token: string) -> (Resource?, string?),
    },
    pick: (options: { files: boolean, multiple: boolean? }, callback: DesktopCallback?) -> (ServiceHandle?, string?),
    open: (resource: string | Resource, callback: DesktopCallback?) -> (ServiceHandle?, string?),
    reveal: (resource: Resource, callback: DesktopCallback?) -> (ServiceHandle?, string?),
    quicklook: ((resources: { Resource }, index: number?, callback: DesktopCallback?) -> (ServiceHandle?, string?))
        & ((resources: { Resource }, callback: DesktopCallback) -> (ServiceHandle?, string?)),
    share: ((resources: { Resource }, anchor: string, service: "airdrop"?, callback: DesktopCallback?) -> (ServiceHandle?, string?))
        & ((resources: { Resource }, anchor: string, callback: DesktopCallback) -> (ServiceHandle?, string?)),
    clipboard: {
        copy: (content: string | Resource, callback: DesktopCallback?) -> (ServiceHandle?, string?),
        read: (callback: DesktopCallback) -> (ServiceHandle?, string?),
    },
    provider: {
        send: (name: string, args: any, options: { files: { Resource }? }?, callback: ((result: ProviderResult) -> ())?) -> (ServiceHandle?, string?),
    },
    http: (request: HTTPRequest, callback: (result: HTTPResult) -> ()) -> (ServiceHandle?, string?),
    after: (seconds: number, callback: () -> ()) -> (ServiceHandle?, string?),
    store: {
        get: (key: string) -> any,
        set: (key: string, value: any) -> (boolean?, string?),
        status: StoreStatus,
    },
    asset: (path: string) -> Asset,
    components: {
        activity: (id: string) -> ComponentActivity?,
        add: (widget: string, options: { [string]: ComponentValue }?, callback: ConfigCallback?) -> (ServiceHandle?, string?),
        remove: (id: string, callback: ConfigCallback?) -> (ServiceHandle?, string?),
        move: (id: string, index: number, callback: ConfigCallback?) -> (ServiceHandle?, string?),
        enable: (id: string, enabled: boolean, callback: ConfigCallback?) -> (ServiceHandle?, string?),
        set: (id: string, key: string, value: ComponentValue, callback: ConfigCallback?) -> (ServiceHandle?, string?),
    },
    config: {
        set: (key: string, value: ComponentValue, callback: ConfigCallback?) -> (ServiceHandle?, string?),
    },
    run: (command: string) -> (),
    log: (...any) -> (),
    l10n: (key: string, ...any) -> string,
}

declare ui: {
    component: (props: ComponentProps) -> Element,
    row: (props: Props) -> Element,
    column: (props: Props) -> Element,
    stack: (props: Props) -> Element,
    box: (props: Props) -> Element,
    text: (props: TextProps) -> Element,
    input: (props: TextInputProps) -> Element,
    symbol: (props: SymbolProps) -> Element,
    icon: (props: IconProps) -> Element,
    image: (props: ImageProps) -> Element,
    progress: (props: ProgressProps) -> Element,
    shader: (props: ShaderProps) -> Element,
    path: (props: PathProps) -> Element,
    slider: (props: SliderProps) -> Element,
    popout: (ctx: Context) -> (),
}

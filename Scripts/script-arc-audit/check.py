# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import re
import subprocess
import sys
from pathlib import Path


NO_OBSERVER_OWNERSHIP = {
    field: 0 for field in ("R", "L", "obj", "heap", "wS", "wU", "wO", "oR", "oL",
                           "oRV", "oAV", "cR", "cL", "uR", "uL", "bR", "bL", "VM")
}
ROUTES = {
    "setup/activation", "key/cold", "settings/key", "script/plain-key", "key/idle", "key/busy", "key/owned-busy", "key/workspace-8", "key/windows-200",
    "key/refusal-first", "key/refusal-repeat", "key/dispatch-window", "key/cmd-in-callback", "key/cmd-prebuilt", "key/cmd-build-argument", "move/by-name", "move/neighbor", "capture/no-placement", "capture/placement",
    "capture/placement-mutated", "capture/placement-excluded", "capture/placement-held-tab", "key/no-placement", "key/placement", "place/detach",
    "place/column", "title/no-observer", "native/title", "native/title+script", "native/minimize", "native/float",
    "native/fullscreen", "title/fresh", "title/replacement", "capture/fixed", "capture/workspace-8",
    "capture/windows-200", "title/owned-fresh", "title/owned-replacement",
}
STATE_AND_EDGE_KINDS = {
    "workspace.active", "window.active", "monitor.focused", "keybinds.submap", "config.reloaded",
    "window.open", "window.close", "window.move_to_workspace", "workspace.created", "workspace.removed",
    "workspace.move_to_monitor", "monitor.added", "monitor.removed", "monitor.layout_changed",
    "window.minimize", "window.fullscreen", "window.update_state",
}
FOCUS_KINDS = ("workspace.active", "window.active", "monitor.focused")
WINDOW_TRANSACTION_KINDS = ("window.open", "window.close", "window.move_to_workspace", "window.minimize", "window.update_state", "window.fullscreen")
CATALOG_TRANSACTIONS = ("catalog-bulk", "catalog-ranked", "catalog-unavailable")
DYNAMIC_EVENT_STRINGS = {
    "workspace.active": ("workspace name",),
    "window.active": ("bundle ID",),
    "monitor.focused": ("monitor name",),
    "window.open": ("bundle ID",),
    "window.minimize": ("bundle ID",),
    "workspace.move_to_monitor": ("workspace name", "previous monitor name", "new monitor name"),
}
RESIDENT_EVENT_MAIN_STORAGE = {"obj": 0, "heap": 0, "VM": 0}
PARKED_EVENT_WAKE = 1
DISCARDED_NATIVE_EVENT_NIL_RELEASE = 1
REENTRANT_WORKSPACE_REMOVAL_OBSERVER = 1
FOCUS_OBJC_OWNERS = ("registered receiver across a reentrant post",
                     "receiver at the Objective-C selector boundary", "notification at the selector boundary")
WINDOW_WEAK_LOOKUPS = {
    "window.move_to_workspace": ("controller while publishing the membership transaction",),
    "window.update_state": ("controller at mode recording", "controller at mode settlement"),
}
MULTIWORD_ROUTES = ("ancestry/extend", "ancestry/union", "ancestry/all-excluded", "ancestry/publication")
TITLE_TRANSACTIONS = ("title-ready", "title-pending")
WORKSPACE_KEYS = {f"{prefix}workspace-key/{action}-{outcome}" for prefix in ("", "warm/")
                  for action in ("next", "previous", "back")
                  for outcome in ("noop", "switch")}
TIMER_ROUTES = ("timer/empty", "timer/reads", "timer/effect")
CALLBACK_DISPATCH_ROUTES = ("key/dispatch-window", "key/cmd-in-callback", "key/cmd-prebuilt", "key/cmd-build-argument")
MARK_COST_FIELDS = ("R", "L", "obj", "heap", "bR", "bL")
MARK_COSTS = {
    "mark/set-changed": ((4, 6, 3, 5, 5, 10), (37, 43, 2, 2, 21, 24)),
    "mark/set-unchanged": ((4, 6, 3, 5, 5, 10), (35, 42, 1, 1, 19, 24)),
    "mark/summon-refused": ((4, 6, 3, 6, 5, 10), (121, 162, 21, 25, 56, 108)),
}
ROUTES.update(MARK_COSTS)
COMMAND_SELECTORS = ("cmd/integer", "cmd/string-index", "cmd/invalid-selector", "window/integer", "window/string-index")
ROUTES.update(COMMAND_SELECTORS)
CALLBACK_COMMAND_BUILDS = {
    ("key/cmd-in-callback", "key/cmd-prebuilt"): ({"R": 0, "L": 1, "obj": 0, "heap": 0},
        "Resolving an argument-free omniwm.cmd uses no new owner or storage."),
    ("key/cmd-build-argument", "key/idle"): ({"R": 0, "L": 2, "obj": 1, "heap": 1},
        "The neutral constructor consumes the existing argument array without retaining it."),
    ("cmd/integer", "cmd/string-index"): ({"R": 0, "L": 0, "obj": 0, "heap": 0, "bR": 0, "bL": -1},
        "An integer selector builds the same action with no extra Swift ownership or storage."),
    ("window/integer", "window/string-index"): ({"R": 0, "L": 0, "obj": 0, "heap": 0, "bR": 0, "bL": -1},
        "An integer workspace selector stages the same window action with no extra Swift ownership or storage."),
}
ROUTES.update({prefix + kind for kind in STATE_AND_EDGE_KINDS for prefix in ("absent/", "event/")})
ROUTES.update("native/" + kind + suffix for kind in FOCUS_KINDS for suffix in ("+script", "+listener"))
ROUTES.update("owned/" + kind for kind in DYNAMIC_EVENT_STRINGS)
ROUTES.update("native/" + kind + suffix for kind in CATALOG_TRANSACTIONS for suffix in ("", "+script"))
ROUTES.update("native/" + kind + suffix for kind in WINDOW_TRANSACTION_KINDS for suffix in ("", "+script"))
ROUTES.update(("native/focus", *TIMER_ROUTES, *MULTIWORD_ROUTES, *WORKSPACE_KEYS))
ROUTES.update("native/" + kind + suffix for kind in TITLE_TRANSACTIONS for suffix in ("", "+script"))
PHASES = ("producer", "dequeue", "config", "completion")
PUBLISHED_REFUSAL = ({"R": 0, "L": 0, "obj": 0, "heap": 0, "VM": 0},
                     "An identical published refusal transfers no ownership and needs no storage or VM entry.")
NATIVE_NO_OP = ({"obj": 0, "heap": 0, "VM": 0}, "A matched one-display monitor no-op needs no storage or VM.")
RESIDENT_KEY_STORAGE = ({"obj": 0, "heap": 0}, "Activation provides the worker and its in-flight slot.")
WAKE_TRANSFERS = {"key/idle": 1, "key/busy": 0}
MAIN_EXECUTOR_JOB_TRANSFER = 1
CALLBACK_OWNER_RELEASE = 1
CONTROLLER_RELEASE_AFTER_HOP = 1
PARK_EXECUTOR_RELEASE = 1
CAPTURED_DYNAMIC_BUNDLE_OWNER = 1
CAPTURED_DYNAMIC_WORKSPACE_OWNER = 1
CAPTURED_STRING_OWNERS = CAPTURED_DYNAMIC_BUNDLE_OWNER + CAPTURED_DYNAMIC_WORKSPACE_OWNER
NATIVE_PREVIOUS_HANDLER_GUARDS = 4
NATIVE_PREVIOUS_HISTORY_LOOKUPS = 2
NATIVE_DISPATCH_OWNERS = 2
NATIVE_PREVIOUS_WEAK_PROMOTIONS = 3
NATIVE_RETAIN_CEILING = NATIVE_PREVIOUS_HANDLER_GUARDS + NATIVE_PREVIOUS_HISTORY_LOOKUPS + NATIVE_DISPATCH_OWNERS
NATIVE_RELEASE_CEILING = NATIVE_RETAIN_CEILING + NATIVE_PREVIOUS_WEAK_PROMOTIONS
CAPTURED_DYNAMIC_TITLE_OWNER = 1
OWNED_TITLE_STRINGS = CAPTURED_DYNAMIC_BUNDLE_OWNER + CAPTURED_DYNAMIC_TITLE_OWNER
TITLE_OWNER_TRANSFERS = {
    "title/fresh": (0, 0),
    "title/replacement": (0, 0),
    "title/owned-fresh": (OWNED_TITLE_STRINGS, 0),
    "title/owned-replacement": (OWNED_TITLE_STRINGS, OWNED_TITLE_STRINGS),
}
TITLE_IDLE_WAKE = {"title/fresh", "title/owned-fresh"}
BORROWED_TITLE_REGISTRATION = ({"wS": 0, "wU": 0, "wO": 0, "VM": 0},
                               "Synchronous title publication borrows the native controller and registered queue.")
NATIVE_TITLE_PRODUCER_AT_DCDFF9956 = {
    "native/title": (239, 291, 24, 24),
    "native/title+script": (254, 307, 24, 26),
}
PLACEMENT_CAPTURES = (
    "capture/placement", "capture/placement-mutated", "capture/placement-excluded", "capture/placement-held-tab"
)
COLUMN_CAPTURES = ("capture/columns-held-tab", "capture/columns-excluded")
COLUMN_EDITS = (("capture/columns-after-edit", "engine/projection-rebuild"),
                ("capture/columns-after-edit-excluded", "engine/columns-rebuild"))
ROUTES.update((*COLUMN_CAPTURES, *(route for pair in COLUMN_EDITS for route in pair)))
FOCUS_TARGET_CAPTURES = ("capture/focus-target", "capture/focus-target-exit", "capture/focus-target-fallback")
FOCUS_TARGET_EVENTS = tuple(route.replace("capture/", "event/workspace.active+") for route in FOCUS_TARGET_CAPTURES)
ROUTES.update(("capture/no-focus-target", *FOCUS_TARGET_CAPTURES, *FOCUS_TARGET_EVENTS))
MIXED_READ_EVENTS = tuple(tuple("event/workspace.active+" + name for name in family) for family in (
    ("shared-frames", "shared-plain", "solo-frames", "solo-plain"),
    ("shared-columns", "shared-plain-columns", "solo-columns", "solo-plain-columns"),
    ("shared-details", "shared-plain-details", "solo-details", "solo-plain-details"),
    ("shared-list-details", "shared-plain-list-details", "solo-list-details", "solo-plain-list-details"),
    ("shared-dwindle", "shared-plain-dwindle", "solo-dwindle", "solo-plain-dwindle"),
))
ROUTES.update(("move/floating-frame", "capture/details-excluded", "capture/list-details", "capture/list-details-excluded",
               *(route for family in MIXED_READ_EVENTS for route in family)))
MARK_CAPTURES = tuple(f"capture/marks-{size}-cap" for size in ("under", "at", "over"))
ROUTES.update(("capture/no-marks", "capture/marks-ordering", *MARK_CAPTURES))
SAVED_READ_CAPTURES = ("capture/apps-grouped", "capture/apps-over-cap", "capture/rules-over-cap")
ROUTES.update(("capture/app-rule-control", "capture/no-apps-or-rules", "first/capture/apps-grouped", *SAVED_READ_CAPTURES))
BAR_READ_SIZES = (("capture/workspace-bar-64", "capture/workspace-bar-256"),
                  ("capture/workspace-bar-grouped-64", "capture/workspace-bar-grouped-256"))
BAR_READ_CAPTURES = tuple(route for pair in BAR_READ_SIZES for route in pair)
ROUTES.update(("capture/workspace-bar-control", "capture/no-workspace-bar", "first/capture/workspace-bar", *BAR_READ_CAPTURES))
ROUTES.update(("gather/join", "gather/unchanged", "gather/refused"))
ROUTES.update(("replace/applied", "replace/stale", "replace/malformed"))
NAMED_KEY_PAIRS = (("named/hit", "window/hit"), ("named/ref-hit", "window/ref-hit"),
                   ("named/tap-press", "window/tap-press"), ("named/tap-release", "window/tap-release"))
ROUTES.update((*(route for pair in NAMED_KEY_PAIRS for route in pair), "named/miss", "named/luau", "named/luau-control"))
STORE_ROUTES = ("store/get", "store/get-list", "store/equal-set", "store/changed-set", "store/batch-8",
                "store/large-write", "store/cold-get")
STORE_WRITES = {"store/changed-set": 1, "store/batch-8": 1, "store/large-write": 1}
ROUTES.update(("store/control", *STORE_ROUTES))
SHARED_LISTENER_FIELDS = ("R", "L", "obj", "VM")
SCRIPT_WORKER_MALLOCS = ("Mallocs on the script worker are left out: Luau's page and string-table growth follows the "
                         "incremental collector's phase, not the listeners' reads.")
DWINDLE_TREE_HOLDS = {
    "splits": ({"R": 2, "L": 2}, "Each split retains both children while the walk recurses into them."),
    "leaves": ({"R": 2, "L": 2, "bR": 1, "bL": 1},
               "Each leaf retains its tile through the copy of its node kind and holds its member array across "
               "the caller's leaf callback."),
}
EXACT_COSTS = {
    **{(route, phase): RESIDENT_KEY_STORAGE for route in (*WAKE_TRANSFERS, "key/owned-busy")
       for phase in ("producer", "dequeue", "completion")},
    **{(route, "producer"): BORROWED_TITLE_REGISTRATION for route in TITLE_OWNER_TRANSFERS},
    **{(route, "producer"): ({"obj": 0, "heap": 0, "VM": 0},
       "Back and Forth with no previous workspace needs no transition, result snapshot or cache rebuild.")
       for route in WORKSPACE_KEYS if route.endswith("/back-noop")},
    ("key/refusal-repeat", "producer"): PUBLISHED_REFUSAL,
    ("settings/key", "producer"): NATIVE_NO_OP,
    ("script/plain-key", "producer"): NATIVE_NO_OP,
    ("title/no-observer", "producer"): (NO_OBSERVER_OWNERSHIP, "An absent observer transfers no ownership."),
}


def check_window_rows(table, output):
    shapes = {match[1]: {"splits": int(match[2]), "leaves": int(match[3])}
              for match in re.finditer(r"^dwindle-shape (\S+) splits=(\d+) leaves=(\d+)$", output, re.M)}
    sizes = sorted({int(match[1]) for route, phase in table if phase == "producer"
                    and (match := re.fullmatch(r"rows/niri/(?:workspace|windows|framed)-(\d+)", route))})
    if len(sizes) < 3:
        sys.exit(f"The window-row control needs the workspace size, the full size and the row limit, got {sizes}")
    first = sizes[0]
    routes = ("first/rows/niri/workspace", "first/rows/niri/windows", "first/rows/niri/framed",
              "first/rows/niri/columned", "rows/niri/workspace", "rows/niri/windows", "rows/niri/framed",
              "rows/niri/columned", "rows/dwindle/workspace", "rows/dwindle/windows", "rows/dwindle/framed",
              "rows/dwindle/columned", "first/rows/dwindle/tree", "rows/dwindle/tree", "rows/dwindle/group",
              "rows/niri/tree")
    for kind in routes:
        baseline = table.get((f"{kind}-{first}", "producer"))
        for size in sizes[1:]:
            larger = table.get((f"{kind}-{size}", "producer"))
            if not baseline or not larger:
                sys.exit(f"Missing matched {kind} capture for {first} and {size} rows")
            for field in NO_OBSERVER_OWNERSHIP:
                extra = int(larger[field]) - int(baseline[field])
                allowed, reason = 0, ""
                if kind.endswith("rows/dwindle/tree"):
                    tree = kind.removeprefix("first/")
                    for unit, (holds, why) in DWINDLE_TREE_HOLDS.items():
                        if field in holds:
                            added = shapes[f"{tree}-{size}"][unit] - shapes[f"{tree}-{first}"][unit]
                            allowed += holds[field] * added
                            reason += " " + why
                if extra != allowed:
                    sys.exit(f"{kind}: {size - first} additional rows must add {allowed} {field}, got {extra}.{reason}")
    for kind in ("rows/niri/framed", "rows/dwindle/framed", "rows/niri/columned", "rows/dwindle/columned",
                 "rows/dwindle/tree", "rows/dwindle/group", "rows/niri/tree"):
        for size in sizes:
            counts = table[f"{kind}-{size}", "producer"]
            if int(counts["obj"]) or int(counts["heap"]):
                sys.exit(f"{kind}-{size}: a warm capture with a read modifier allocates nothing: {counts}")
    larger = " and ".join(str(size) for size in sizes[1:])
    print(f"capture/row-delta {first} to {larger} windows: zero additional ARC, allocations, weak promotions or VM entries, "
          "apart from the per-split and per-leaf Dwindle tree holds")


def check_transaction_owners(table, kind, pairs=(), released=(), native_only_releases=()):
    baseline = "native/" + kind + ("+listener" if kind in FOCUS_KINDS else "")
    native = table[baseline, "producer"]
    observed = table["native/" + kind + "+script", "producer"]
    delta = tuple(int(observed[k]) - int(native[k]) for k in ("R", "L"))
    retains = PARKED_EVENT_WAKE + len(pairs)
    releases = retains + len(released) - len(native_only_releases)
    if delta != (retains, releases):
        sys.exit(f"{kind}: incremental R/L {delta}, expected {(retains, releases)} for parked worker, "
                 f"pairs={pairs}, additional releases={released}, native-only releases={native_only_releases}")
    objc = len(FOCUS_OBJC_OWNERS) if kind in FOCUS_KINDS else 0
    weak = WINDOW_WEAK_LOOKUPS.get(kind, ())
    imports = {"oR": objc, "oL": objc, "uR": PARKED_EVENT_WAKE, "uL": PARKED_EVENT_WAKE,
               "wS": len(weak), "wU": 0, "wO": 0, "oRV": 0, "oAV": 0, "cR": 0, "cL": 0}
    for field, allowed in imports.items():
        if int(observed[field]) - int(native[field]) != allowed:
            sys.exit(f"{kind}: {field} at the native boundary differs from its ownership contract: "
                     f"selector owners={FOCUS_OBJC_OWNERS if objc else ()}, weak loads={weak}, one executor wake")
    for field in ("obj", "heap"):
        if int(observed[field]) > int(native[field]):
            sys.exit(f"{kind}: script publication adds {field} to {baseline}: {native} versus {observed}")


def check_catalog_transactions(table):
    placements = tuple(f"{stage} {field}" for stage in ("old", "new") for field in
                       ("monitor list", "visible map", "assigned map", "placement projection lookup"))
    monitor_context = ("context projection lookup", "monitors", "sorted monitors", "topology profile",
                       "configured workspace names", "monitor descriptions", "ranking key path",
                       "monitor settings", "ranking values")
    fixture_buckets = tuple(f"{stage} bucket {monitor} for {workspace}"
                            for stage, assignments in (("old", ("left", "left", "left")),
                                                       ("new", ("left", "left", "right")))
                            for workspace, assigned in enumerate(assignments)
                            for monitor in (("left", "right") if assigned == "right" else ("left",)))
    check_transaction_owners(table, "catalog-bulk", (
        "original observer across settings application", "workspace descriptors across publication",
        *placements, *monitor_context, *fixture_buckets
    ))
    ranked = ("workspace descriptor for monitor resolution", "assignment and fallback projection lookup",
              "sorted monitors", "monitor descriptions", "ranking key path",
              "monitor settings", "ranking values", "first ranked candidate UUID", "second ranked candidate UUID",
              "resolved monitor UUID")
    check_transaction_owners(table, "catalog-ranked", ranked)
    check_transaction_owners(table, "catalog-unavailable", (*ranked, "fallback display UUID"))


def check_native_event_transactions(table):
    for kind in FOCUS_KINDS:
        check_transaction_owners(table, kind, ("controller in the reentrant Foundation notification frame",))
    for kind in ("title", *TITLE_TRANSACTIONS):
        check_transaction_owners(table, kind)
    check_transaction_owners(table, "window.open")
    check_transaction_owners(table, "window.close", native_only_releases=("absent saved workspace name",))
    check_transaction_owners(table, "window.move_to_workspace", (
        "membership callback during a model update", "frame while recording the move",
        "transaction move recorder", "workspace manager during publication", "frame while publishing moves"
    ), ("weak controller lookup", "unowned world lookup for depth", "unowned world lookup for the primary token"))
    check_transaction_owners(table, "window.minimize", ("original minimization observer across commit",))
    check_transaction_owners(table, "window.update_state", (
        "mode change callback", "manager while recording prior mode", "pending settlement observer",
        "manager while publishing settled modes", "prior-mode dictionary iteration", "fullscreen dictionary iteration"
    ), ("weak controller at record", "previous pending observer", "weak controller at settlement",
        "vacated mode dictionary", "vacated fullscreen dictionary"))
    check_transaction_owners(table, "window.fullscreen", ("original fullscreen registration during confirmation",))


def check_named_keys(table):
    fields = tuple(NO_OBSERVER_OWNERSHIP)
    miss = table["named/miss", "producer"]
    if any(int(miss[field]) for field in fields):
        sys.exit(f"named/miss: a key the mode doesn't bind must cost nothing: {miss}")
    for route, control_route in NAMED_KEY_PAIRS:
        named, control = table[route, "producer"], table[control_route, "producer"]
        if int(named["obj"]) or int(named["heap"]) or any(int(named[field]) > int(control[field]) for field in fields):
            sys.exit(f"{route} must allocate nothing and cost no more than {control_route}: {named} against {control}")
    match = table["named/hit", "producer"]
    for phase in PHASES:
        delivered, control = table["named/luau", phase], table["named/luau-control", phase]
        for field in fields:
            extra = int(delivered[field]) - int(control[field])
            allowed = int(match[field]) if phase == "producer" else 0
            if extra > allowed:
                sys.exit(f"named/luau {phase}: delivery through a mode key may add only the matcher's cost, "
                         f"{field} {delivered[field]} against {control[field]} + {allowed}")
    print("named keys: a miss costs nothing; hits, references and the tap cost no more than Window mode; "
          "Luau delivery adds only the matcher")


def check_store(table, output):
    fields = tuple(NO_OBSERVER_OWNERSHIP)
    for phase in PHASES:
        control, function = table["store/control", phase], table["named/luau-control", phase]
        if any(control[field] != function[field] for field in fields):
            sys.exit(f"store/control {phase}: a callback that skips the store must cost what any function key "
                     f"costs: {control} against {function}")
    for route in STORE_ROUTES:
        for phase in PHASES:
            if phase == "config":
                continue
            measured, control = table[route, phase], table["store/control", phase]
            if any(measured[field] != control[field] for field in fields):
                sys.exit(f"{route} {phase}: the store may only cost on the script worker: {measured} against {control}")
        writes = re.search(rf"^store-writes {re.escape(route)} (\d+)$", output, re.M)
        if not writes or int(writes.group(1)) != STORE_WRITES.get(route, 0):
            sys.exit(f"{route} must replace the store file {STORE_WRITES.get(route, 0)} times per callback")
    print("store: callbacks that skip it cost what any function key costs; its cost stays on the script worker, "
          "with one file replacement per changed callback and none otherwise")


def check_marks(table):
    for route, costs in MARK_COSTS.items():
        for phase in ("producer", "dequeue"):
            measured, control = table[route, phase], table["key/idle", phase]
            if any(measured[field] != control[field] for field in NO_OBSERVER_OWNERSHIP):
                sys.exit(f"{route}/{phase}: mark work must start on the config worker: {measured} against {control}")
        for phase, expected in zip(("config", "completion"), costs, strict=True):
            actual = tuple(int(table[route, phase][field]) for field in MARK_COST_FIELDS)
            if actual != expected:
                sys.exit(f"{route}/{phase}: expected {MARK_COST_FIELDS} {expected}, measured {actual}")


def check_costs(output):
    rows = [line.split() for line in output.splitlines()]
    header = next(row for row in rows if row and row[0] == "route")
    table = {(row[0], row[2]): dict(zip(header, row)) for row in rows if len(row) == len(header)}
    for route in ROUTES:
        for phase in PHASES:
            if (route, phase) not in table:
                sys.exit(f"Missing counter measurement: {route} {phase}")
    check_window_rows(table, output)
    check_named_keys(table)
    check_store(table, output)
    check_marks(table)
    for route in ("settings/key", "script/plain-key"):
        producer = table[route, "producer"]
        if int(producer["R"]) > NATIVE_RETAIN_CEILING or int(producer["L"]) > NATIVE_RELEASE_CEILING:
            sys.exit(f"{route}: native command ownership exceeded its pre-slice budget: {producer}")
    for route, transfers in WAKE_TRANSFERS.items():
        wake = re.search(rf"^wake/{route} resumes=(\d+) retains=(\d+) releases=(\d+)$", output, re.M)
        if not wake:
            sys.exit(f"Missing continuation ownership measurement for {route}")
        resumes, retains, releases = map(int, wake.groups())
        if (resumes, retains, releases) != (transfers, transfers, transfers):
            sys.exit(f"{route} transfers one task reference for each wake of the parked worker: {wake.group()}")
        phase_ownership = {
            "producer": (transfers, transfers, "Only resuming a parked worker transfers task ownership."),
            "dequeue": (transfers * MAIN_EXECUTOR_JOB_TRANSFER, transfers * MAIN_EXECUTOR_JOB_TRANSFER,
                        "Only an idle worker enters a main-executor job to dequeue."),
            "completion": (MAIN_EXECUTOR_JOB_TRANSFER,
                           MAIN_EXECUTOR_JOB_TRANSFER + CALLBACK_OWNER_RELEASE + CONTROLLER_RELEASE_AFTER_HOP
                           + PARK_EXECUTOR_RELEASE,
                           "The returning job borrows the executor. The worker releases its script owner and controller "
                           "after the hop and its main actor isolation reference when parking."),
        }
        for phase, (retains, releases, reason) in phase_ownership.items():
            counts = table[route, phase]
            if (int(counts["R"]), int(counts["L"])) != (retains, releases):
                sys.exit(f"{route}/{phase}: expected {retains}/{releases}, got {counts['R']}/{counts['L']}. {reason}")
    for phase, extra_retains, extra_releases in (
        ("producer", CAPTURED_STRING_OWNERS, 0),
        ("dequeue", CAPTURED_STRING_OWNERS, 0),
        ("completion", 0, CAPTURED_STRING_OWNERS),
    ):
        owned = table["key/owned-busy", phase]
        scalar = table["key/busy", phase]
        if (int(owned["R"]) > int(scalar["R"]) + extra_retains
                or int(owned["L"]) > int(scalar["L"]) + extra_releases):
            sys.exit(f"key/owned-busy/{phase}: the captured bundle and workspace "
                     f"can each transfer one owner at the queue and executor boundaries: {owned}")
    for route, (stored, displaced) in TITLE_OWNER_TRANSFERS.items():
        producer = table[route, "producer"]
        wake = int(route in TITLE_IDLE_WAKE)
        expected = (wake + stored, wake + displaced, 0, 0)
        actual = tuple(int(producer[field]) for field in ("R", "L", "obj", "heap"))
        if actual != expected:
            sys.exit(f"{route}: only the idle wake and the payload's heap-backed strings transfer ownership. "
                     f"Expected {expected}, measured {actual}.")
        for phase in ("dequeue", "completion"):
            if any(int(table[route, phase][field]) for field in ("obj", "heap")):
                sys.exit(f"{route}/{phase}: the resident worker already owns its slot and frame")
    for route, baseline in NATIVE_TITLE_PRODUCER_AT_DCDFF9956.items():
        actual = tuple(int(table[route, "producer"][field]) for field in ("R", "L", "obj", "heap"))
        if any(current > previous for current, previous in zip(actual, baseline)):
            sys.exit(f"{route}: native AX title publication exceeds its accepted baseline {baseline}: {actual}")
    for kind in STATE_AND_EDGE_KINDS:
        for phase in PHASES:
            absent = table["absent/" + kind, phase]
            if any(int(absent[field]) for field in NO_OBSERVER_OWNERSHIP):
                sys.exit(f"{kind}/{phase}: an absent registration must do no script work: {absent}")
        for phase in ("producer", "dequeue", "completion"):
            counts = table["event/" + kind, phase]
            if any(int(counts[field]) != cost for field, cost in RESIDENT_EVENT_MAIN_STORAGE.items()):
                sys.exit(f"{kind}/{phase}: activation supplies the queue and worker storage: {counts}")
        if int(table["event/" + kind, "config"]["VM"]) != 1:
            sys.exit(f"{kind}: the subscribed callback must enter its VM once")
        pairs = PARKED_EVENT_WAKE + (REENTRANT_WORKSPACE_REMOVAL_OBSERVER if kind == "workspace.removed" else 0)
        counts = table["event/" + kind, "producer"]
        if any(int(counts[k]) != pairs for k in ("R", "L")):
            sys.exit(f"{kind}: only the wake and a removal observer across native commit may transfer: {counts}")
    for route in MULTIWORD_ROUTES:
        counts = table[route, "producer"]
        wake = PARKED_EVENT_WAKE if route == "ancestry/publication" else 0
        released = wake + (DISCARDED_NATIVE_EVENT_NIL_RELEASE if route == "ancestry/all-excluded" else 0)
        if any(int(counts[k]) != expected for k, expected in
               {"R": wake, "L": released, **RESIDENT_EVENT_MAIN_STORAGE}.items()):
            sys.exit(f"{route}: only the wake or the discarded payload's nil release may appear: {counts}")
    for phase in ("dequeue", "config", "completion"):
        excluded = table["ancestry/all-excluded", phase]
        if any(int(excluded[k]) for k in NO_OBSERVER_OWNERSHIP):
            sys.exit(f"An event excluded by every listener keeps the worker parked: {excluded}")
    if int(table["ancestry/publication", "config"]["VM"]) != 1:
        sys.exit("Only the listener outside both occupied ancestry words may run")
    for kind, owners in DYNAMIC_EVENT_STRINGS.items():
        counts = table["owned/" + kind, "producer"]
        if any(int(counts[k]) != v for k, v in RESIDENT_EVENT_MAIN_STORAGE.items()):
            sys.exit(f"{kind}: moving existing {', '.join(owners)} into a slot needs no new storage: {counts}")
        if (int(counts["R"]), int(counts["L"])) != (PARKED_EVENT_WAKE + len(owners), PARKED_EVENT_WAKE):
            sys.exit(f"{kind}: only the wake and {', '.join(owners)} cross delivery: {counts}")
    check_native_event_transactions(table)
    check_catalog_transactions(table)
    for route in (*CALLBACK_DISPATCH_ROUTES, *COMMAND_SELECTORS, *MARK_COSTS):
        if int(table[route, "config"]["VM"]) != 1:
            sys.exit(f"{route}: the shortcut callback must enter its VM once")
    by_name = table["move/by-name", "config"]
    for route in ("move/neighbor", "move/floating-frame"):
        staged = table[route, "config"]
        for field in ("R", "L", "obj", "heap"):
            if int(staged[field]) != int(by_name[field]):
                sys.exit(f"{route}: staging a window table must cost what a workspace name does, "
                         f"{field} {staged[field]} against {by_name[field]}")
    for mixed, plain, modified, unmodified in MIXED_READ_EVENTS:
        for field in SHARED_LISTENER_FIELDS:
            shared = int(table[mixed, "config"][field]) - int(table[plain, "config"][field])
            alone = int(table[modified, "config"][field]) - int(table[unmodified, "config"][field])
            if shared != alone:
                sys.exit(f"{mixed}: a read modifier on a shared list must cost the listener without it nothing, "
                         f"{field} +{shared} beside it against +{alone} alone. {SCRIPT_WORKER_MALLOCS}")
        for route in (mixed, plain, modified, unmodified):
            for phase in ("producer", "dequeue", "completion"):
                counts = table[route, phase]
                if int(counts["obj"]) or int(counts["heap"]):
                    sys.exit(f"{route}/{phase}: a warm shared capture needs no main-thread storage: {counts}")
    for (route, baseline), (budget, reason) in CALLBACK_COMMAND_BUILDS.items():
        for field, allowed in budget.items():
            extra = int(table[route, "config"][field]) - int(table[baseline, "config"][field])
            if extra != allowed:
                sys.exit(f"{route}: expected {field} {allowed:+d} over {baseline}, got {extra:+d}. {reason}")
    for route in (*PLACEMENT_CAPTURES, *FOCUS_TARGET_CAPTURES):
        counts = table[route, "producer"]
        if int(counts["obj"]) or int(counts["heap"]):
            sys.exit(f"{route}: a declared singleton read fills the warm snapshot without allocating: {counts}")
    for route in COLUMN_CAPTURES:
        counts = table[route, "producer"]
        if int(counts["obj"]) or int(counts["heap"]):
            sys.exit(f"{route}: a warm columns capture with held or excluded windows allocates nothing: {counts}")
    excluded_details = table["capture/details-excluded", "producer"]
    if int(excluded_details["obj"]) or int(excluded_details["heap"]):
        sys.exit(f"A warm details capture reuses storage when a window is excluded: {excluded_details}")
    list_details = table["capture/list-details", "producer"]
    if int(list_details["obj"]) or int(list_details["heap"]):
        sys.exit(f"A warm workspace and monitor details capture reuses storage: {list_details}")
    for route in MARK_CAPTURES:
        mark_capture = table[route, "producer"]
        if int(mark_capture["obj"]) or int(mark_capture["heap"]):
            sys.exit(f"{route}: a warm marks capture reuses storage: {mark_capture}")
    for route in SAVED_READ_CAPTURES:
        capture = table[route, "producer"]
        if int(capture["obj"]) or int(capture["heap"]):
            sys.exit(f"{route}: a warm apps or rules capture reuses storage: {capture}")
    for route in BAR_READ_CAPTURES:
        capture = table[route, "producer"]
        if int(capture["obj"]) or int(capture["heap"]):
            sys.exit(f"{route}: a warm workspace bar capture reuses storage: {capture}")
    for small, large in BAR_READ_SIZES:
        fewer, more = table[small, "producer"], table[large, "producer"]
        grown = {field: (fewer[field], more[field]) for field in fewer
                 if field not in ("route", "native-control", "phase") and int(more[field]) > int(fewer[field])}
        if grown:
            sys.exit(f"{large}: more bar windows must add no ARC, allocations or VM entries over {small}: {grown}")
    for capture, engine in COLUMN_EDITS:
        edit, rebuild = table[capture, "producer"], table[engine, "producer"]
        for field in ("obj", "heap"):
            if int(edit[field]) != int(rebuild[field]):
                sys.exit(f"{capture}: after a structural edit a columns capture allocates only the caches the next "
                         f"layout pass rebuilds, {field} {edit[field]} against {engine} {rebuild[field]}")
    def config_delta(route, baseline):
        return {k: int(table[route, "config"][k]) - int(table[baseline, "config"][k]) for k in ("R", "L", "obj", "heap")}
    declared_read = config_delta("key/placement", "key/no-placement")
    staged_action = config_delta("key/dispatch-window", "key/idle")
    for route in FOCUS_TARGET_EVENTS:
        for phase in ("producer", "dequeue", "completion"):
            counts = table[route, phase]
            if int(counts["obj"]) or int(counts["heap"]):
                sys.exit(f"{route}/{phase}: the read and the refused focus check need no main-thread storage: {counts}")
        extra = config_delta(route, "event/workspace.active")
        budget = {k: declared_read[k] + staged_action[k] for k in extra}
        if any(extra[k] != budget[k] for k in ("obj", "heap")) or any(extra[k] > budget[k] for k in ("R", "L")):
            sys.exit(f"{route}: the record and a checked focus may cost only a declared read plus a staged "
                     f"window action on the config thread: {extra} against {budget}")
    def counts(route):
        return {k: v for k, v in table[route, "producer"].items() if k not in ("route", "native-control", "phase")}
    if counts("capture/placement-mutated") != counts("capture/placement"):
        sys.exit("capture/placement-mutated: a structural change must not add placement read cost")
    for route in ("capture/no-placement", "capture/no-focus-target", "capture/no-marks"):
        if counts(route) != counts("capture/fixed"):
            sys.exit(f"{route}: an undeclared read must cost nothing")
    if counts("capture/no-apps-or-rules") != counts("capture/app-rule-control"):
        sys.exit("capture/no-apps-or-rules: populated apps and saved rules must cost nothing when undeclared")
    if counts("capture/no-workspace-bar") != counts("capture/workspace-bar-control"):
        sys.exit("capture/no-workspace-bar: populated bar windows must cost nothing when undeclared")
    for route in ("capture/workspace-8", "capture/windows-200", *PLACEMENT_CAPTURES, *FOCUS_TARGET_CAPTURES,
                  "capture/marks-ordering", *MARK_CAPTURES, *SAVED_READ_CAPTURES, *BAR_READ_CAPTURES):
        if not re.search(rf"^snapshot-bytes {re.escape(route)} [1-9][0-9]*$", output, re.M):
            sys.exit(f"Missing snapshot byte count for {route}")
    for route in TIMER_ROUTES:
        if int(table[route, "config"]["VM"]) != 1:
            sys.exit(f"{route}: each timer must fire once on the config executor")
        for phase in ("producer", "dequeue", "completion"):
            if (route, phase) in {("timer/reads", "dequeue"), ("timer/effect", "completion")}:
                continue
            counts = table[route, phase]
            if any(int(counts[field]) for field in NO_OBSERVER_OWNERSHIP):
                sys.exit(f"{route}/{phase}: only a declared capture or real effect needs main: {counts}")
    for route, (budget, ownership) in EXACT_COSTS.items():
        for metric, allowed in budget.items():
            actual = int(table[route][metric])
            if actual != allowed:
                sys.exit(f"{route}: expected {metric}={allowed}, got {actual}. {ownership}")


def debugger_output(lldb, binary, fixture, option, commands):
    args = [lldb, "--batch"]
    for command in commands:
        args.extend(("-o", command))
    result = subprocess.run(args + ["--", binary, fixture, option],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode or "exited with status = 0" not in result.stdout:
        sys.exit(result.stdout)
    return result.stdout


def check_workspace_result_reads(lldb, binary, fixture):
    output = debugger_output(lldb, binary, fixture, "--workspace-keys", (
        "settings set target.inline-breakpoint-strategy always",
        f'breakpoint set -s {binary.name} -f CommandHandler+Actions.swift -m false -p "controller[.]activeWorkspace[(][)]" -G true',
        "breakpoint set -s libScriptARC.dylib -n script_arc_end -G true",
        'breakpoint command add -o "breakpoint list 1" 2',
        "run",
    ))
    previous = 0
    samples = []
    checked = set()
    for line in output.splitlines():
        if hit := re.match(r"^1: source regex = .*?hit count = (\d+)", line):
            count = int(hit[1])
            samples.append(count - previous)
            previous = count
            continue
        fields = line.split()
        if len(fields) < 3 or fields[0] not in WORKSPACE_KEYS or fields[2] != "producer":
            continue
        route = fields[0]
        expected = int(route.endswith("-switch"))
        if not samples or any(reads != expected for reads in samples):
            sys.exit(f"{route}: expected {expected} command-result reads per press, got {samples}\n{output}")
        checked.add(route)
        samples.clear()
    if checked != WORKSPACE_KEYS:
        sys.exit("Missing workspace command-result samples\n" + output)
    print("workspace result reads: zero on a no-op, one on an ordinary switch, for each key and cache state")


def line_probe(source, marker):
    path = Path("Sources/OmniWM/Core/Config") / source
    lines = [number for number, line in enumerate(path.read_text().splitlines(), 1) if marker in line]
    if len(lines) != 1:
        sys.exit(f"{path}: expected one probe line containing {marker!r}, found {lines}")
    return f"-f {source} -l {lines[0]} -m false"


def check_delivery(lldb, binary, fixture):
    probes = [
        '-f ConfigScriptEventObservers+WindowState.swift -p "let event = ConfigScriptWindowTitle"',
        '-f ConfigScriptCallbackQueue.swift -p "let key = WindowStateKey.window\\(\\.windowTitle,"',
        line_probe("ConfigScriptReadSnapshot.swift", "let limit = sections * ConfigScriptSnapshot.byteLimit"),
    ]
    commands = ["settings set target.inline-breakpoint-strategy always"]
    for probe in probes:
        commands.append(f"breakpoint set -s {binary.name} {probe} -G true")
    listing = "breakpoint list " + " ".join(str(i) for i in range(1, len(probes) + 1))
    commands += [
        "breakpoint set -n script_arc_checkpoint", "run", listing,
        "continue", listing, "continue",
    ]
    output = debugger_output(lldb, binary, fixture, "--observe-delivery", commands)
    reports = re.findall(re.escape("(lldb) " + listing) + r"\n(.+?)(?=\(lldb\) continue)", output, re.S)
    if len(reports) != 2:
        sys.exit(output)
    read_counts = re.search(r"delivery-expect dormant=(\d+) subscribed=(\d+)", output)
    if not read_counts:
        sys.exit("Missing delivery fixture expectations\n" + output)
    for label, report, publications in zip(("dormant", "subscribed"), reports, map(int, read_counts.groups())):
        counts = []
        for number in range(1, len(probes) + 1):
            hits = re.findall(rf"^\s+{number}\.\d+:.*?, resolved, hit count = (\d+)", report, re.M)
            if not hits:
                sys.exit("Unresolved script delivery probe\n" + report)
            counts.append(sum(map(int, hits)))
        print(f"delivery/{label} payloads={counts[0]} enqueues={counts[1]} snapshots={counts[2]}")
        expected = [publications, publications, int(publications > 0)]
        if counts != expected:
            sys.exit(f"{label} expected {expected}, observed {counts}\n" + report)


def check_detail_platform_reads(lldb, binary, fixture):
    probes = (
        ("AX", "AXUIElementCopyAttributeValue"),
        ("SkyLight", "SLSMainConnectionID"),
        ("WindowBounds", "SLSGetWindowBounds"),
        ("WindowQuery", "SLSWindowQueryWindows"),
        ("CGDisplayBounds", "CGDisplayBounds"),
    )
    scopes = ("calibration", "cold", "warm")
    commands = [f'breakpoint set -n "{symbol}" -G true' for _, symbol in probes]
    commands += [
        "breakpoint set -s libScriptARC.dylib -n script_arc_begin",
        "breakpoint set -s libScriptARC.dylib -n script_arc_end",
        "run",
        'expression -l objc++ -- (unsigned long)[(Class)(void*)objc_getClass("NSScreen") '
        'methodForSelector:(SEL)(void*)sel_registerName("screens")]',
        "breakpoint set -a $0 -G true",
        'expression -l objc++ -- (unsigned long)[(Class)(void*)objc_getClass("NSRunningApplication") '
        'methodForSelector:(SEL)(void*)sel_registerName("runningApplicationWithProcessIdentifier:")]',
        "breakpoint set -a $1 -G true",
    ]
    numbers = list(range(1, len(probes) + 1)) + [len(probes) + 3, len(probes) + 4]
    labels = [label for label, _ in probes] + ["NSScreen", "NSRunningApplication"]
    listing = "breakpoint list " + " ".join(map(str, numbers))
    for _ in scopes:
        commands.extend((listing, "continue", listing, "continue"))
    output = debugger_output(lldb, binary, fixture, "--details-platform", commands)
    reports = re.findall(re.escape("(lldb) " + listing) + r"\n(.+?)(?=\(lldb\) continue)", output, re.S)
    if len(reports) != 2 * len(scopes):
        sys.exit("Missing detail platform scope boundaries\n" + output)

    def hits(report, number):
        matches = re.findall(rf"^\s+{number}\.\d+:.*?, resolved, hit count = (\d+)", report, re.M)
        if not matches:
            sys.exit("Unresolved detail platform probe\n" + report)
        return sum(map(int, matches))

    for scope, before, after in zip(scopes, reports[::2], reports[1::2]):
        counts = [hits(after, number) - hits(before, number) for number in numbers]
        report = " ".join(f"{label}={count}" for label, count in zip(labels, counts))
        if not (all(count > 0 for count in counts) if scope == "calibration" else not any(counts)):
            sys.exit(f"details/platform/{scope}: {report}\n{output}")
        print(f"details/platform/{scope}: {report}")


if __name__ == "__main__":
    check_costs(Path(sys.argv[4]).read_text())
    lldb, binary, fixture = map(Path, sys.argv[1:4])
    check_delivery(lldb, binary, fixture)
    check_workspace_result_reads(lldb, binary, fixture)
    check_detail_platform_reads(lldb, binary, fixture)

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
    "key/refusal-first", "key/refusal-repeat", "title/no-observer", "native/title", "native/title+script", "native/minimize", "native/float",
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
    "window.active": ("arbitrary session", "bundle ID"),
    "monitor.focused": ("monitor name",),
    "window.open": ("arbitrary session", "bundle ID"),
    "window.minimize": ("arbitrary session", "bundle ID"),
    "workspace.move_to_monitor": ("workspace name", "previous monitor name", "new monitor name"),
}
RESIDENT_EVENT_MAIN_STORAGE = {"obj": 0, "heap": 0, "VM": 0}
PARKED_EVENT_WAKE = 1
WAKE_ONLY_EVENT_KINDS = STATE_AND_EDGE_KINDS - {"workspace.created", "workspace.removed"}
ONE_TRANSFER_PER_STRING = {*FOCUS_KINDS, "window.minimize", "workspace.move_to_monitor"}
TIMER_ROUTES = ("timer/empty", "timer/reads", "timer/effect")
ROUTES.update({prefix + kind for kind in STATE_AND_EDGE_KINDS for prefix in ("absent/", "event/")})
ROUTES.update("native/" + kind + suffix for kind in FOCUS_KINDS for suffix in ("+script", "+listener"))
ROUTES.update("owned/" + kind for kind in DYNAMIC_EVENT_STRINGS)
ROUTES.update("native/" + kind + suffix for kind in CATALOG_TRANSACTIONS for suffix in ("", "+script"))
ROUTES.update("native/" + kind + suffix for kind in WINDOW_TRANSACTION_KINDS for suffix in ("", "+script"))
ROUTES.update(("native/focus", *TIMER_ROUTES))
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
CAPTURED_ARBITRARY_SESSION_OWNER = 1
CAPTURED_DYNAMIC_BUNDLE_OWNER = 1
CAPTURED_DYNAMIC_WORKSPACE_OWNER = 1
CAPTURED_STRING_OWNERS = CAPTURED_ARBITRARY_SESSION_OWNER + CAPTURED_DYNAMIC_BUNDLE_OWNER + CAPTURED_DYNAMIC_WORKSPACE_OWNER
NATIVE_PREVIOUS_HANDLER_GUARDS = 4
NATIVE_PREVIOUS_HISTORY_LOOKUPS = 2
NATIVE_DISPATCH_OWNERS = 2
NATIVE_PREVIOUS_WEAK_PROMOTIONS = 3
NATIVE_RETAIN_CEILING = NATIVE_PREVIOUS_HANDLER_GUARDS + NATIVE_PREVIOUS_HISTORY_LOOKUPS + NATIVE_DISPATCH_OWNERS
NATIVE_RELEASE_CEILING = NATIVE_RETAIN_CEILING + NATIVE_PREVIOUS_WEAK_PROMOTIONS
CAPTURED_DYNAMIC_TITLE_OWNER = 1
OWNED_TITLE_STRINGS = CAPTURED_ARBITRARY_SESSION_OWNER + CAPTURED_DYNAMIC_BUNDLE_OWNER + CAPTURED_DYNAMIC_TITLE_OWNER
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
EXACT_COSTS = {
    **{(route, phase): RESIDENT_KEY_STORAGE for route in (*WAKE_TRANSFERS, "key/owned-busy")
       for phase in ("producer", "dequeue", "completion")},
    **{(route, "producer"): BORROWED_TITLE_REGISTRATION for route in TITLE_OWNER_TRANSFERS},
    ("key/refusal-repeat", "producer"): PUBLISHED_REFUSAL,
    ("settings/key", "producer"): NATIVE_NO_OP,
    ("script/plain-key", "producer"): NATIVE_NO_OP,
    ("title/no-observer", "producer"): (NO_OBSERVER_OWNERSHIP, "An absent observer transfers no ownership."),
}


def check_costs(output):
    rows = [line.split() for line in output.splitlines()]
    header = next(row for row in rows if row and row[0] == "route")
    table = {(row[0], row[2]): dict(zip(header, row)) for row in rows if len(row) == len(header)}
    for route in ROUTES:
        for phase in PHASES:
            if (route, phase) not in table:
                sys.exit(f"Missing counter measurement: {route} {phase}")
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
            sys.exit(f"key/owned-busy/{phase}: the captured session, bundle and workspace "
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
        if kind in WAKE_ONLY_EVENT_KINDS:
            counts = table["event/" + kind, "producer"]
            if any(int(counts[k]) != PARKED_EVENT_WAKE for k in ("R", "L")):
                sys.exit(f"{kind}: static publication transfers only the parked worker's task: {counts}")
    for kind, owners in DYNAMIC_EVENT_STRINGS.items():
        counts = table["owned/" + kind, "producer"]
        if any(int(counts[k]) != v for k, v in RESIDENT_EVENT_MAIN_STORAGE.items()):
            sys.exit(f"{kind}: moving existing {', '.join(owners)} into a slot needs no new storage: {counts}")
        if kind in ONE_TRANSFER_PER_STRING:
            if (int(counts["R"]), int(counts["L"])) != (PARKED_EVENT_WAKE + len(owners), PARKED_EVENT_WAKE):
                sys.exit(f"{kind}: only the wake and {', '.join(owners)} cross delivery: {counts}")
    for kind in (*WINDOW_TRANSACTION_KINDS, *CATALOG_TRANSACTIONS, *FOCUS_KINDS):
        baseline = "native/" + kind + ("+listener" if kind in FOCUS_KINDS else "")
        native = table[baseline, "producer"]
        subscribed = table["native/" + kind + "+script", "producer"]
        if any(int(subscribed[k]) > int(native[k]) for k in ("obj", "heap")):
            sys.exit(f"{kind}: script publication adds storage to {baseline}: {native} versus {subscribed}")
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


def check_delivery(lldb, binary, fixture):
    probes = [
        '-f ConfigScriptEventObservers+WindowState.swift -p "let event = ConfigScriptWindowTitle"',
        '-f ConfigScriptCallbackQueue.swift -p "let key = WindowStateKey.window\\(\\.windowTitle,"',
        '-f ConfigScriptReadSnapshot.swift -p "return ConfigScriptSnapshot"',
    ]
    commands = ["settings set target.inline-breakpoint-strategy always"]
    for probe in probes:
        commands.append(f"breakpoint set -s {binary.name} {probe} -G true")
    listing = "breakpoint list " + " ".join(str(i) for i in range(1, len(probes) + 1))
    commands += [
        "breakpoint set -n script_arc_checkpoint", "run", listing,
        "continue", listing, "continue",
    ]
    args = [lldb, "--batch"]
    for command in commands:
        args.extend(["-o", command])
    result = subprocess.run(args + ["--", binary, fixture, "--observe-delivery"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    reports = re.findall(re.escape("(lldb) " + listing) + r"\n(.+?)(?=\(lldb\) continue)", result.stdout, re.S)
    if result.returncode or len(reports) != 2 or "exited with status = 0" not in result.stdout:
        sys.exit(result.stdout)
    read_counts = re.search(r"delivery-expect dormant=(\d+) subscribed=(\d+)", result.stdout)
    if not read_counts:
        sys.exit("Missing delivery fixture expectations\n" + result.stdout)
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


if __name__ == "__main__":
    check_costs(Path(sys.argv[4]).read_text())
    check_delivery(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))

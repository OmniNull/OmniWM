# Contributing

Bug fixes, documentation improvements, performance work, focused features, and thoughtful ideas are welcome. This is the canonical guide for building OmniWM and submitting a change, also available [on the website](https://omniwm.app/developers/contributing/). For larger changes, open an issue or discussion first so we can agree on direction.

Documentation-only contributions do not require building the app. For website changes, follow the [website development guide](website/README.md).

## Quick Start

### 1. Install Xcode

Building OmniWM requires an **Apple Silicon Mac and Xcode 27 with Swift 6.4**. Xcode 26.6 includes Swift 6.3 and cannot build this checkout. Xcode 27 requires **macOS 26.6 or later**, even though the released OmniWM app supports macOS 26.0 or later. Check [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements) before downloading Xcode.

Install Xcode from [Apple Developer Downloads](https://developer.apple.com/download/all/), open it, and finish its first-launch setup. In **Xcode → Settings → Locations → Command Line Tools**, select Xcode 27. Confirm the compiler in Terminal:

```bash
xcrun swift --version
```

The result must report Swift 6.4. The standalone Command Line Tools package is not a substitute for this Xcode installation.

### 2. Fork, Clone, and Create a Branch

Click **Fork** on [the OmniWM repository](https://github.com/OmniNull/OmniWM), then clone your fork. Replace `YOUR-USERNAME` with your GitHub username:

```bash
git clone https://github.com/YOUR-USERNAME/OmniWM.git
cd OmniWM
git remote add upstream https://github.com/OmniNull/OmniWM.git
git fetch upstream
git switch -c my-change upstream/main
```

Use a descriptive branch name in place of `my-change`. Each contribution should start from `main` and focus on one problem.

### 3. Set Up Dependencies

```bash
make setup
```

This downloads the pinned, prebuilt GhosttyKit into `Frameworks/GhosttyKit.xcframework` and checks its checksum. **You do not need to compile GhosttyKit.** It also installs the pinned SwiftFormat and SwiftLint tools into the repository's ignored local tool cache; no manual Homebrew installation is required. Valid existing dependencies are reused.

Tool versions and download checksums are recorded in [Scripts/dev-tools.env](Scripts/dev-tools.env); Ghostty's internal archive pin remains in [Scripts/build-metadata.env](Scripts/build-metadata.env). Setup preserves an existing framework that does not match the pin and explains the mismatch instead of overwriting it. Setup does not launch OmniWM or change privacy permissions, login items, or CLI links.

### 4. Optionally Create a Signing Certificate

For repeated development, [create the local signing certificate below](#optional-signing-certificate). A stable signing identity helps macOS retain the Dev app's permissions across rebuilds. It needs no paid Apple Developer membership.

You can skip this and run Dev immediately. Without the certificate, the build uses ad-hoc signing and warns that you may need to grant permissions again after rebuilding.

### 5. Build and Run Dev

```bash
make run
```

This builds your checked-out code, packages and signs **OmniWM Dev.app**, installs it at `~/Applications/OmniWM Dev.app`, and opens it. It builds before quitting the running OmniWM copy; if that copy cannot quit, installation stops with an error. Your normal OmniWM app remains installed. Only one copy runs at a time.

On first launch, grant **Accessibility** and **Input Monitoring** to **OmniWM Dev** in the permissions window. **Screen Recording** is optional for capture-derived visuals such as Overview thumbnails. Dev has its own permissions, separate from your normal app. Follow any restart prompt after granting permissions, then return to the permissions window and click **Start OmniWM** or **Continue Without Screen Recording**.

Edit code in your preferred editor, then run `make run` again to rebuild. You can also launch the installed Dev app from Finder.

### 6. Verify and Open a Pull Request

For app code changes, run:

```bash
make verify
swift test
```

`make verify` checks formatting, lint, and the build. **It does not run tests.** See [verification](#verification) for runtime changes and website checks.

Commit your change, push your branch to your fork, and open a pull request targeting **`OmniNull/OmniWM:main`**. A draft PR is welcome when you want early feedback. Explain the problem, the resulting behavior, and what you verified; say what you could not check and why.

## Everyday Commands

| Command | Result |
| --- | --- |
| `make setup` | Check prerequisites and obtain the pinned dependencies. |
| `make doctor` | Diagnose tools, dependencies, signing, and app paths without changing them. |
| `make build` | Build the app without installing or launching it. |
| `make run` | Build, sign, install, and switch to Dev; alias for `make dev-install`. |
| `make use-dev` | Switch to the installed Dev app without rebuilding. |
| `make use-release` | Switch back to the normal app at `/Applications/OmniWM.app`. |

If your normal app is elsewhere, set its path when switching:

```bash
OMNIWM_RELEASE_APP="$HOME/Applications/OmniWM.app" make use-release
```

The development commands do not install the normal release. If you need it, follow the [installation guide](https://omniwm.app/guides/install/).

## Separate Settings and State

The installed Dev app has the fixed identity `com.barut.OmniWM.dev`, which selects its own storage directories even when launched from Finder:

| Data | Normal app | Dev app |
| --- | --- | --- |
| Settings | `~/.config/omniwm/settings.toml` | `~/.config/omniwm-dev/settings.toml` |
| Saved state | `~/.local/state/omniwm/` | `~/.local/state/omniwm-dev/` |
| OmniWM diagnostics | `~/.local/state/omniwm/diagnostics/` | `~/.local/state/omniwm-dev/diagnostics/` |

On first installation, the helper copies your normal `settings.toml` into an independent Dev file. Existing Dev settings are preserved, and later edits are never synchronized. If no normal settings file exists, Dev uses its defaults. Saved state and clipboard history start fresh; they are not copied.

Absolute `XDG_CONFIG_HOME` and `XDG_STATE_HOME` values replace the corresponding base directories, with `omniwm` or `omniwm-dev` appended. Relative values are ignored. These variables must be available to the app process: a variable set only in a Terminal session is not automatically available to a Finder launch.

Keep **Start at Login** disabled in Dev. The helper does not change login registration. Dev can still display normal release-update notifications; installing a stable update does not rebuild your development code. Use `make run` to rebuild Dev.

### Testing the CLI

Both copies use the same IPC socket, so an existing `omniwmctl` command talks to whichever copy is running. Enable IPC in that copy's settings when testing CLI commands.

To test the CLI built from your changes, invoke it directly:

```bash
"$HOME/Applications/OmniWM Dev.app/Contents/MacOS/omniwmctl" --help
```

Setup and switching do not change CLI links. Dev's **Install CLI** setting can create a link to its bundled CLI when no conflicting link exists; use the embedded path above to leave your normal CLI setup alone.

## Optional Signing Certificate

Create one certificate and reuse it for future builds:

1. Open **Keychain Access** using Spotlight and select the **login** keychain.
2. Choose **Keychain Access → Certificate Assistant → Create a Certificate**.
3. Set **Name** to `OmniWM Dev`, **Identity Type** to **Self Signed Root**, and **Certificate Type** to **Code Signing**.
4. Click **Create**, accept the self-signed certificate prompt, and click **Done**. Keep the certificate and its private key in your login keychain.
5. Double-click the certificate, expand **Trust**, and set **Code Signing** to **Always Trust**. Close the window and confirm the change if prompted.
6. Run `make doctor`, then rebuild with `make run`.

See Apple's [certificate creation guide](https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac) and [code-signing instructions](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html) for background. If macOS asks whether `codesign` may access this certificate's private key while building, allow that access.

To use an existing local code-signing identity with another name:

```bash
OMNIWM_SIGNING_IDENTITY="Your Certificate Name" make run
```

## Verification

Run `make format` to apply formatting and the required license headers. Run `make verify` afterward to check formatting, lint, localization catalogs, and an arm64 debug build. The commands use the versions installed by `make setup`.

Every Swift source and test file starts with the two-line GPL-2.0 header enforced by SwiftFormat. Preserve that header. `Package.swift` keeps its `swift-tools-version` directive on line one. Keep contributions in Swift, and avoid additional source comments; use clear names and structure.

Use focused regression tests for changed behavior. Runtime changes require the full serial `swift test` suite, and changes affecting concurrency also require `swift test --parallel`. Environment-dependent live tests remain opt-in. For motion, focus, layout, and other visible behavior, also describe the manual checks you performed.

For changes to setup, packaging, development installation, or related tooling, also run `make test-dev-tools`. This runs the Python development-tooling tests and is included in CI's **Verify** job.

### Translating the App

Translations live in the [string catalogs](Sources/OmniWM/Resources). `Localizable.xcstrings` contains interface text, `Commands.xcstrings` contains command names, categories, and scopes, and `InfoPlist.xcstrings` contains the macOS permission descriptions. Add or edit your language's `localizations` entries in those files. Keep the English keys and source values intact, and translate the meaning in context. English is the fallback for strings without a translation.

Preserve each format argument's type when translating. You may reorder arguments with positional forms such as `%2$@` and `%1$lld`; a `%lld` count cannot become `%@`. Plural branches may omit a count when the wording does not need it. `make verify` checks format arguments, including plural forms, before a translation is accepted. To preview length and direction issues, use Xcode's localization pseudolanguages or change the app language in macOS settings.

If you change localized Swift source text, run `make localization-sync` after building to update the catalogs from compiler-extracted strings, then review the catalog diff. `make verify` fails when source and catalogs differ. For translation-only changes, edit the catalogs directly and run `make verify` and `make test-dev-tools`. This SwiftPM repository has no Xcode project for XLIFF export and import; contribute the catalog files directly. See Apple's [string catalog guide](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) for the catalog format and plural variations.

Before adding the first translation for a new language, translate every desktop string in all three catalogs and have a fluent speaker review the result in the packaged app. Add its cardinal plural categories to `PLURAL_CATEGORIES` in `Scripts/localization.py`, then run `python3 Scripts/localization.py completeness --locales fr de` with the locale codes you are adding; this optional audit requires a nonblank string marked `translated` for every nonempty key and each required plural branch. A partial catalog activates that language for macOS users as soon as it ships. After a language is established, newly added strings may temporarily fall back to English while translations catch up.

Website changes use the checks in [website/README.md](website/README.md): `npm run check` and `npm run build` from `website/`. Small documentation-only changes do not need app builds or Swift tests.

GitHub's **OmniWM CI** workflow reports **Verify** (`make verify`) and **Tests** (the serial Swift suite) separately. Tests are initially advisory while the hosted environment is established; a failing test still needs an explanation. On a first contribution, a maintainer may need to [approve the workflow run](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/approve-runs-from-forks) before checks start. A pending approval does not mean you did something wrong.

## Troubleshooting

Start with `make doctor` and the first error reported by the failing command.

- **Wrong Swift version:** select Xcode 27 in its Locations settings, complete its first-launch setup, and check `xcrun swift --version` again.
- **Missing dependencies:** run `make setup`. If an existing GhosttyKit fails its checksum, move your custom framework aside before running setup again; the helper will not replace it for you.
- **Permissions requested again:** check the signing identity with `make doctor`, rebuild with the same valid certificate, and grant Dev's permissions again when prompted. Stable and Dev permissions are separate.
- **Switching stops because OmniWM is still running:** quit that copy from its menu, then retry. The helper does not force-kill it or install over a running copy.
- **Normal app not found:** install the release or supply `OMNIWM_RELEASE_APP` as shown above.

## Pull Request Expectations

- Keep changes focused. Explain the current problem and why your approach solves it; refactors need a concrete reason.
- Include verification results, including any checks you could not run. Add screenshots, recordings, or CLI examples when useful.
- Update documentation when behavior, configuration, workflows, or interfaces change.
- Create your change branch from `main` and target `main`. There is no permanent `develop` branch.
- Contributor PRs are normally integrated with merge commits so their commit history and authorship remain intact. You do not need to squash or perfect your history before asking for review.

Reviewed development lands on `main`; published releases come from version tags. Merging a PR does not itself update users' installed apps.

### Maintainer CI Rollout

The **Main branch protection** ruleset blocks branch deletion and force-pushes, with repository-admin bypass for local merges and releases. GitHub uses merge commits and automatically deletes merged branches in this repository.

After publishing the CI workflow, confirm that **Verify** passes on GitHub, then add **Verify** from GitHub Actions as a required status check in that existing ruleset. Keep the admin bypass and leave **Tests** non-required until several hosted runs establish that the serial suite works reliably there.

For an existing PR, use **Actions → OmniWM CI → Run workflow** and enter its PR number to test its merge with the base branch. A manual run provides logs; it does not replace the PR's required check. Updating the PR branch triggers its normal PR checks. Approve first-time fork runs when needed.

## Trace Files

Include a trace file when useful, especially for bug reports. Open **Settings → Troubleshooting**, click **Start Recording**, reproduce the bug, then click **Stop & Save Recording** and attach the saved `.log` file.

**Report a Bug…** in the status-bar menu opens the in-app report form. Recording or selecting trace and crash evidence is optional; on submit OmniWM prepares a fresh diagnostic `.log` with whatever you selected, reveals it for attaching, and opens a pre-filled GitHub issue.

Before attaching a diagnostic, review it: the file can contain OmniWM settings, application and window titles, and title-based App Rule matchers.

With IPC enabled, captures can also be scripted using the CLI: `capture start trace`, `capture stop`, and `capture status`.

## Improving the Issue-Report Prompt

The prompt that rewrites bug reports into GitHub issues lives in plain Markdown. See [docs/issue-report-prompt.md](docs/issue-report-prompt.md) for the files, constraints, and verification steps.

If you are unsure about something, open an issue or ask in your pull request. Questions and early feedback are welcome.

# Public launcher build mode

The optional `--public-api` boundary mode replaces the development desktop-web
launcher dependency. It does not establish that the whole game package is
eligible for distribution, or that the game runs on physical hardware.

The demonstrated development build hosts the original desktop `WebView` using
private iOS WebCore/WAK APIs. In public mode that implementation is excluded by
the compiler, including all WAK method calls and `WebThreadLock` loading.
Game-layer hover tracking remains available independently.

The original executable also imports desktop `WebView`, `WebScriptObject` and
`WebUndefined` classes from WebKit. Merely disabling the host leaves those
private iOS bindings in place. Public mode adds `DEBoundary_WebKit.dylib`, binds
those original imports to explicitly named AgePad classes, and reexports the
public WKWebView APIs needed by the account surfaces. The AgePad desktop classes
stop with an explicit diagnostic if the game tries to display that unsupported
launcher. They do not emulate a web bridge or report a successful game launch.

Native device startup sets the game's existing `GameOptionsDialogShouldShow`
preference to zero. Existing HUD and telemetry choices are preserved. Unknown
or ambiguous preference structure causes a diagnostic stop. This must still be
tested with the actual game, including first launch and subsequent launches.

## Build and checks

Pass `--public-api` to `scripts/bootstrap-de-simulator.py` when generating the
candidate, or directly to `scripts/build-de-boundary-probe.py` with its existing
application/bootstrap, main-executable and window-host options. The default
build retains the development legacy host.

Run `scripts/build-de-device-runtime.py OUTPUT --package PACKAGE --public-api`
to require generated public-mode sources and link them with the physical iOS
SDK. The generated source contains an explicit build-time macro; an environment
variable cannot switch private code back on. Reports carry the runtime policy,
and the device linker checks the exact class export aliases.

`python3 tests/test_de_public_launcher.py` performs eight host-only checks:
preference preservation and failure cases, default/public AppKit compilation,
preprocessed exclusion of the legacy implementation, and public WebKit links
and class exports for both Simulator and device SDKs. These checks do not boot
a Simulator, authenticate an account, install an app or run the game.

For a concrete build, inspect original game imports with `dyld_info -imports`:
the legacy classes must resolve through `DEBoundary_WebKit`. Independently audit
all binaries and their actual behavior before treating the package as a public
API distribution candidate. The mode removes this known dependency; it is not
a blanket certification for the proprietary game or Steam libraries.

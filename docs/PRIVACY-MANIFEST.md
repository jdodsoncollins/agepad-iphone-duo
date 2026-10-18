# Owned-code privacy API declarations

Audited 17 October 2026. `assets/PrivacyInfo.xcprivacy` describes required-reason
APIs in AgePad's compatibility and setup code. It deliberately contains no
tracking or collected-data declarations: their omission does not establish the
privacy behavior of the bundled game, Steam, or other vendor libraries.

| Category / reason | Source evidence and purpose |
| --- | --- |
| User defaults / `CA92.1` | `LoaderProbe.m` stores AgePad settings and first-run state; `AgePadSteamRoute.m` stores this app's account display name and update notice. No shared suite or external defaults domain is selected. |
| Disk space / `85F4.1` | `LoaderProbe.m` reads `NSFileSystemFreeSize` to show “Free space on this device” during setup. This code does not currently make an observable install decision based on free space, so `E174.1` is not declared. |
| File metadata / `C617.1` | `HUDInputRegions.h` validates app-container layout/input files and invalidates caches using file metadata. `DeviceDataTree.h` and `SteamModuleCompat.m` inspect imported game data and the inert bundled Steam-module copy within this app's storage. |
| System boot time / `35F9.1` | `TouchPointerCompat.m` and `NativeTouchGestures.m` use uptime for pointer holds and gesture debounce; `AppPresence.h` / `CoreGraphicsClient.m` measure elapsed app inactivity. |
| System boot time / `8FFB.1` | `WindowViewCompat.m` stamps synthetic input events. `DisplayLinkCompat.m` uses `mach_absolute_time()` to populate display-refresh callback timestamps from `CADisplayLink`. |

[Apple's category/reason definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
were checked directly. No keyboard reason, shared-defaults reason, bug-report
reason, or third-party-wrapper-only reason is asserted.

Copy the manifest before signing. The app bundle and each affected framework
need their own manifest resource; framework declarations should be narrowed to
the categories used there. Apple's [required-reason API guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
and [placement instructions](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
apply per executable/library bundle. Do not copy this resource into vendor
frameworks as a substitute for reviewing their behavior.

The distribution builder now places the full owned-code resource at the app
root and in `DE_AppKit.framework`, and narrower declarations in the owned
libSystem, CoreVideo, Metal and Steam-client compatibility frameworks. The
libSystem shim's indirect metadata forwarding also needs vendor-purpose review
for calls beyond AgePad's own storage checks.

The staged vendor binaries still import required-reason APIs: Steam's
`steamclient` imports `stat`, `lstat`, `fstat`, and `statfs`; Breakpad and QuincyKit
reference `NSUserDefaults`; the HTTP, PlayFab, audio, tier0, and vstdlib libraries
import file-metadata APIs. The game executable itself imports `NSUserDefaults`,
`mach_absolute_time`, `stat`/`fstat`/`lstat`, and `statfs`/`fstatfs`/`statvfs`; it
also imports several `CFPreferences` functions whose accessed domains need review.
These imports establish API presence, not an approved
purpose or whether data is transmitted. Generic compatibility forwarding of
vendor filesystem calls also needs vendor-level review. This manifest cannot
justify every forwarded call solely by declaring AgePad's own container use.

This resource is not a completed App Store privacy-label or vendor telemetry
audit. No live account, device, or network sign-in was used for the audit.

# SteamOS Waydroid Bundle

> [!IMPORTANT]
> This is an independently maintained, modified continuation of Ryan Rudolf's
> SteamOS Waydroid Installer. It is not affiliated with or endorsed by the
> original project. Independent modifications began on 17 July 2026. See
> [upstream provenance](UPSTREAM.md) for the incorporated source snapshot,
> authorship, licence history, and current upstream status.

> [!NOTE]
> **AI assistance disclosure:** This continuation was substantially refactored
> during July and August 2026 with OpenAI Codex, an AI coding agent based on
> the GPT-5 model family. Codex assisted with architecture, shell-script
> refactoring, safety checks, documentation, and code review under the human
> maintainer's direction. The exact internal model build or revision identifier
> is not exposed to this repository or session, so no more specific version is
> claimed. The human maintainer selected, tested, and published the changes and
> remains responsible for the resulting software.

SteamOS Waydroid Bundle installs Waydroid on a Steam Deck using host packages,
Cage, wlroots, and wlr-randr built against a matching SteamOS userspace ABI.
It keeps the persistent Android image under the `deck` user's home so routine
SteamOS host repair can occur without recreating Android applications,
settings, files, or login sessions.

## Compatibility and safety model

The installer can run on any SteamOS version for which a verified compatible
bundle has been published; it does not impose a fixed SteamOS version check.
The fingerprint includes
the SteamOS release and build plus relevant compiler, runtime, Python, Wayland,
graphics, input, and system-library versions.

An exact version, build, and ABI match is always preferred. If no exact bundle
exists, a bundle may also be reused across SteamOS build/version changes when the userspace ABI matches and Binder compatibility is satisfied. For kernels with external Binder modules, the bundle's recorded kernel release must match the running kernel exactly. Development and
`main`-branch SteamOS builds remain experimental, and existing SteamOS-family
and branch checks still apply.

Before requesting sudo access, the installer:

- confirms that it is running locally in SteamOS Desktop Mode;
- identifies the SteamOS release and checks the update branch;
- selects an already-installed exact or ABI-compatible bundle, or downloads one;
- verifies the archive hash, paths, manifest, ELF dependencies, and target
  fingerprint;
- exits without changing SteamOS or Android when no compatible bundle exists.

Before installing host packages, the installer asks Pacman to resolve and preview
the full transaction. Any recursively missing dependencies, such as `lxc` or
`dnsmasq`, are installed from the repositories configured by SteamOS and listed
in the installer log. The installer stops before making changes if Pacman cannot
resolve the transaction or omits a verified bundle target. Dependency checking
remains enabled; the installer never bypasses it with `--nodeps`.

A SteamOS version number alone is not treated as proof of binary
compatibility. Normal installation has no option to silently substitute a
bundle built for a different fingerprint.

Bundles contain packages installed into SteamOS as root. Use only the official
artifact source or another source you control and trust.

## Requirements

- Steam Deck running any SteamOS version with a compatible verified bundle
  available;
- an exact or ABI-compatible published bundle for that SteamOS userspace;
- Desktop Mode with a working graphical session;
- a sudo password for the `deck` user;
- at least 10 GB free under the home filesystem for a new Android install;
- internet access for source, bundle, and Android-image downloads.

SteamOS Stable (`rel`), Beta, and Preview update branches are supported when a
compatible bundle is available. Development and `main` branches remain
experimental, and the installer displays an explicit warning there.

## Install

In Desktop Mode, open Konsole and run:

```bash
cd ~
git clone --depth=1 \
    https://github.com/pjohno/steamos-waydroid-bundle.git
cd ~/steamos-waydroid-bundle
./steamos-waydroid-installer.sh
```

## Shared folder

Install and repair ensure that `~/Waydroid Share` exists without replacing an
existing directory or changing its contents, ownership, or permissions. While
Waydroid is running, the normal mount lifecycle bind-mounts it at Android shared
storage as `Waydroid Share`. Shutdown and uninstall unmount it when necessary,
but uninstall never deletes the host folder or the files inside it.

The share works in both the normal Android 13 environment and the Android 16
test environment. Files created on SteamOS are visible and readable in Android,
and the mount is removed during a normal Waydroid shutdown.

Direct host/Android sharing currently has an ownership limitation. The host
directory normally remains `deck:deck` with `0755` permissions, so arbitrary
Android apps may be unable to create files or folders in it. Making the
directory world-writable can permit writes, but Android-created content then
appears on SteamOS under app-specific numeric UIDs and GIDs. Those IDs differ
between Android installations and must not be hard-coded. Do not leave the
share at `0777`; fully seamless bidirectional ownership mapping is not currently
provided. The recommended use is making SteamOS files available to Android.

On first run, the installer creates an ignored machine-local
`.deck-config.env` with mode `0600` and selects the official public bundle
Release. It then obtains the exact bundle before making privileged host
changes.

For a new Android instance, the installer offers:

- Android 13 with Google Play;
- Android 13 without Google Play;
- Android TV 13 with Google Play;
- Android TV 13 without Google Play.

Those normal-install choices remain on Android 13. The separate **Install Test
Environment** flow offers the same official Android 13 GApps and Vanilla
choices plus experimental regular and TV x86_64 images:

- Android 16 GApps (Experimental);
- Android 16 Vanilla (Experimental);
- Android TV 16 GApps (Experimental);
- Android TV 16 Vanilla (Experimental).

Use an Android 16 test environment with a Waydroid version that properly
supports Android 16. Hardware testing confirmed that Waydroid 1.6.3 on SteamOS
Beta 3.8.25 (`BUILD_ID=20260807.2`) boots, runs, and shuts down Android 16
correctly. With Waydroid 1.5.4 on SteamOS Stable 3.8.16
(`BUILD_ID=20260716.1`), Android 16 can still boot and run, but container
lifecycle operations such as shutdown can be unreliable. Android 13 remains
the normal supported installation path.

The experimental Android 16 images are provided by the independent
[SupeChicken / WayDroid-ATV project](https://sourceforge.net/projects/waydroid-atv/files/images/);
they are not produced or officially supported by this repository. Their exact,
pinned SourceForge artifacts are centralized in
`libexec/steamos-waydroid/android-image-sources.sh`.

The official Android 13 standard images use `waydroid_script` to install
libhoudini ARM translation, Widevine, and fingerprint configuration. The TV
images are provided separately and already contain their required ARM
translation and Widevine components. The Android-13-specific extras and
fingerprint spoof are deliberately skipped for experimental Android 16;
their built-in ARM support is retained and Widevine is not modified.

The fresh-install path also downloads the
[StevenBlack hosts list](https://github.com/StevenBlack/hosts) variant that
blocks adware, malware, fake-news, gambling, and adult domains. This affects
name resolution inside Waydroid. It can be disabled or updated later through
Waydroid Toolbox.

When installation finishes, the script can create the appropriate Steam
shortcut and offer to return to Gaming Mode. Existing matching shortcuts and
their artwork are preserved.

## Existing installations and repair

Running the installer without an option is intentionally safe on an existing
installation. If `~/Android_Waydroid/waydroid.img` exists, the installer:

1. selects repair mode automatically;
2. validates the persistent image through a read-only mount;
3. obtains the exact host bundle for the current SteamOS target;
4. rebuilds host packages, launchers, shortcuts, and integration;
5. does not initialize or replace Android.

Applications and logins also depend on host-side Android user state under
`~/.local/share/waydroid` and, on older installations, `~/waydroid`. Back up
the image and user-state directories together when the data is important.

After an atomic SteamOS update, run the normal command again:

```bash
cd ~/steamos-waydroid-bundle
./steamos-waydroid-installer.sh
```

If no bundle exists for the updated fingerprint, repair stops before changing
SteamOS or Android. Wait for a compatible bundle, restore a supported SteamOS
deployment, or follow the maintainer build procedure.

## Commands

| Command                                                       | Behaviour                                                                                                                                           |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `./steamos-waydroid-installer.sh`                           | Fresh install when no image exists; otherwise automatic protected repair.                                                                           |
| `./steamos-waydroid-installer.sh --repair`                  | Explicitly require the protected existing-image repair path.                                                                                        |
| `./steamos-waydroid-installer.sh --reinstall-android`       | Deliberately create a new Android instance after typed confirmation. Existing image and user state are archived first.                              |
| `./steamos-waydroid-installer.sh --install-test`            | Install a separate experimental Waydroid Test image and user state without modifying the normal Android environment.                                |
| `./steamos-waydroid-installer.sh --remove-test`             | Delete only the separate experimental Waydroid Test Android environment; the normal environment and Steam shortcuts are not modified.               |
| `./steamos-waydroid-installer.sh --configure-artifacts`     | Replace the Deck's bundle source through the advanced configuration wizard.                                                                         |
| `./steamos-waydroid-installer.sh --uninstall`               | Remove host integration while retaining Android state, the checkout, installed bundles, and artifact configuration.                                 |
| `./steamos-waydroid-installer.sh --purge-android`           | Delete Android state and reinstall archives while retaining the checkout and verified bundles.                                                      |
| `./steamos-waydroid-installer.sh --reset-host-keep-android` | Remove host integration, bundles, artifact configuration, and reports while retaining Android state and the checkout. Useful for first-run testing. |
| `./steamos-waydroid-installer.sh --uninstall-all`           | Delete Android state, host integration, bundles, and the Deck-side checkout after typed confirmation.                                               |

Destructive modes explain their scope and require an exact typed phrase. The
script never stops or restarts Steam. If Steam is running, uninstall and reset
skip direct shortcut-database changes and continue; remove any remaining
Waydroid or Nested Desktop shortcut manually from Steam in Gaming Mode.

Host reset writes immediately flushed stage diagnostics to
`~/.local/state/steamos-waydroid/reset-*.log` and the system journal. It removes
installer-owned packages individually without orphan cleanup. If reset is
interrupted after staging the Android image, the next keep-Android reset safely
restores the staged image before retrying. If both active and staged copies
exist, it stops without overwriting either copy.

Firewalld cleanup validates the permanent configuration and removes only rules
recorded as having been introduced by this installer. Runtime and permanent
ownership are recorded separately; failed setup rolls back only rules added by
that setup attempt. Cleanup uses targeted runtime and permanent operations when
firewalld is active, or `firewall-offline-cmd` when it is inactive, and preserves
the service's initial state. Legacy ownership records are treated as
permanent-only so they cannot authorize removal of a pre-existing runtime rule.

After any successful uninstall or reset, fully restart SteamOS before launching
Waydroid, reinstalling, repairing, or running another reset. Reset deliberately
does not unload a live out-of-tree Binder module; the restart discards it and
provides a clean boundary before host integration is installed again.

## Reinstalling Android

`--reinstall-android` is different from repair. When existing state is found,
it archives:

- `~/Android_Waydroid/waydroid.img`;
- `~/.local/share/waydroid`;
- legacy `~/waydroid` state when present.

The new instance does not inherit the previous applications or logins. If
installation fails before the replacement is committed, the installer moves
incomplete replacement state aside and restores the previous image and user
state as a matched set.

## Launching Waydroid

Use the created Waydroid or Nested Desktop entry in Gaming Mode. In Desktop
Mode, the launcher can also be run directly:

```bash
cd ~/Android_Waydroid
./Android_Waydroid_Cage.sh
```

After `--install-test` succeeds, Steam also contains a separate **Waydroid
Test** entry. It uses `~/Android_Waydroid/test/waydroid.img` and
`~/.local/share/waydroid-test/waydroid`; the normal Waydroid entry continues to
use the existing image and user data. Both environments can remain installed,
but they share `/var/lib/waydroid` and `waydroid-container.service`, so shut one
down before launching or installing the other.

The test slot contains one Android installation at a time. Its selected version
and variant are recorded in `~/Android_Waydroid/test/android-version` and
`~/Android_Waydroid/test/android-variant` for diagnostics. Recreate the test
environment to switch versions; there is no automatic fallback or migration.

Run `./steamos-waydroid-installer.sh --remove-test` to permanently delete the
separate test image and test-specific user state. This leaves the normal
Waydroid environment untouched and does not inspect or modify Steam shortcuts
or artwork.

Before every launch, the helper checks the current SteamOS fingerprint and
reactivates an already-installed compatible bundle when possible. After a
SteamOS A/B rollback, this can restore the matching retained bundle without a
network request. If no local match exists, run the installer in Desktop Mode.

Before entering Cage, the launcher also confirms that Binder is available and
that the persistent Android image is a structurally valid ext4 Waydroid image.
Android has 90 seconds to complete boot. A preflight failure, container failure,
or boot timeout returns to Game Mode with a diagnostic instead of waiting
indefinitely on a black screen.

## Artifact sources

The normal first run uses the public Release at:

```text
https://github.com/pjohno/steamos-waydroid-bundle/releases/download/bundles
```

Advanced configuration also supports:

- an authenticated private GitHub Release;
- a trusted Fedora build host over SSH and rsync;
- another public HTTP or HTTPS artifact directory.

Changing the source requires explicit confirmation when it is not the official
default. A downloaded checksum proves integrity relative to that source; it
does not make an untrusted source safe.

## Troubleshooting

### No compatible bundle

The error identifies the SteamOS version, build, branch, and target. Do not use
the explicit mismatch override for an ordinary installation. A maintainer must
publish a bundle with the same userspace ABI; if Binder is not built into the
running kernel, an exact target bundle is required.

### Installer says it is not in Desktop Mode

Run it locally from Konsole in Desktop Mode. SSH and virtual terminals do not
provide the graphical session needed for prompts and Steam shortcut creation.

### Android-image download is unusually slow

The Android image is obtained from a selected SourceForge mirror. Cancel with
Ctrl-C and retry if the chosen mirror is stalled.

### A shortcut was not recreated

The installer deliberately preserves an existing matching Steam shortcut. To
replace it, delete that shortcut through Steam and run the installer again.

### Another Waydroid profile is active

After leaving Waydroid in Gaming Mode, the previously running container or
image can occasionally remain active. Launching the other environment then
reports an error similar to `another Waydroid profile is active`. This guard is
intentional: it prevents one profile from replacing `/var/lib/waydroid` while
the other image is still active.

Exit to Desktop Mode, open Konsole, and shut down the environment that was
previously running. For the normal Android environment, run:

```bash
sudo /usr/bin/waydroid-shutdown-scripts main
```

For the test environment, run:

```bash
sudo /usr/bin/waydroid-shutdown-scripts test
```

Return to Gaming Mode and launch the desired environment again. Rebooting the
Deck is also a reasonable recovery if the container does not shut down cleanly.
This stale-container behaviour can affect either environment and is not
specific to the test profile.

### Compatibility reports

Target mismatches create Markdown reports under:

```text
~/.local/state/steamos-waydroid/reports/
```

When reporting a problem, include:

- SteamOS `VERSION_ID`, `BUILD_ID`, and update branch;
- the exact error message;
- the generated compatibility report when present;
- whether the run was a fresh install, automatic repair, explicit repair, or
  Android reinstall;
- relevant customizations that might affect Waydroid.

Do not post passwords, authentication tokens, private SSH configuration, or
home-network addresses. File issues at
[https://github.com/pjohno/steamos-waydroid-bundle/issues](https://github.com/pjohno/steamos-waydroid-bundle/issues).

## Maintainers

Normal Deck users should run only `steamos-waydroid-installer.sh`. Helpers
under `libexec/` are internal entry points. Reproducible target capture, build,
publication, reset, and diagnostic procedures are documented in the
[maintainer guide](maintainer/README.md).

Maintainers can create a build root either from an official Valve SteamOS image
or from a live Steam Deck. The image-based path allows Stable, Beta, Preview,
and Main builds to be prepared without booting that SteamOS build on a Deck.

Multiple bundle builds may exist for the same exact SteamOS target fingerprint.
The first published bundle for a target becomes its preferred `auto` bundle.
Later experimental bundles can be published side-by-side without changing that
selection; promotion to the preferred target is explicit through the maintainer
publishing workflow.

Public bundles must be built from a committed revision available in this
repository. Their manifests record that exact source revision and target
fingerprint.

## Credits and licence

- Based on Ryan Rudolf's SteamOS Waydroid Installer; see
  [UPSTREAM.md](UPSTREAM.md) for exact provenance and independent modification
  history.
- [Waydroid](https://github.com/waydroid/waydroid) provides the Android
  container platform.
- [waydroid_script](https://github.com/casualsnek/waydroid_script) provides
  Android extras used by standard-image installation.
- SupeChicken provides the Android TV image source used by the installer.
- Additional authors and contributors are retained in the Git history.

This project is distributed under GNU GPL version 3. See [LICENSE](LICENSE).

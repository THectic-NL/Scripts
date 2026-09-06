# Redmi / Xiaomi ADB Debloat

Non-root ADB debloat helper for Xiaomi/Redmi/POCO phones running HyperOS
(or MIUI). Written for a Redmi Note 15 5G, but the package lists apply to
most recent HyperOS devices.

## Prep (do this before connecting the phone)

1. Install Android platform-tools (`adb`) on this machine:
   - Fedora/RHEL: `sudo dnf install android-tools`
   - Debian/Ubuntu: `sudo apt install android-sdk-platform-tools`
   - Arch: `sudo pacman -S android-tools`
2. On the phone: **Settings > About phone**, tap "HyperOS version" (or "MIUI
   version") 7 times to unlock Developer options.
3. **Settings > Additional settings > Developer options**: enable
   **USB debugging**. On MIUI/HyperOS also enable **USB debugging (Security
   settings)** if you plan to use `install-existing`/`uninstall` for system
   apps - some ROMs gate `pm uninstall` behind it.
4. Connect the phone by USB cable, unlock it, and accept the "Allow USB
   debugging?" prompt (tick "always allow from this computer").
5. Verify: `adb devices` should show the device as `device`, not
   `unauthorized` or `offline`.

## Usage

```bash
cd android
./redmi_debloat.sh info                    # print all known packages, no device needed
./redmi_debloat.sh list                    # show which of them are actually installed
./redmi_debloat.sh remove --dry-run        # preview what `remove` would do
./redmi_debloat.sh remove                  # remove Tier 1 (safe) only
./redmi_debloat.sh remove --include-miui   # also remove Tier 2 (Xiaomi bundled apps)
./redmi_debloat.sh restore com.miui.notes  # bring one package back
./redmi_debloat.sh restore-all removed-packages-*.txt  # bring everything back
```

Every `remove` run writes a `removed-packages-<timestamp>.txt` file with
exactly what it removed, so a bad call is one `restore-all` away from fixed.

## How it works

Uses `adb shell pm uninstall -k --user 0 <package>`. This does **not**
delete the system APK - it just hides the app from the current user profile
and keeps its data (`-k`). Nothing here needs root, and everything is
undone by `restore`/`restore-all`, or trivially by a factory reset.

## Package tiers

- **Tier 1 - safe**: ordinary third-party apps Xiaomi/carriers bundle
  (Facebook, Amazon, Netflix, LinkedIn, Opera, Microsoft Office, WPS
  Office, bundled games, etc). These are regular user apps, not system
  components - removing them is as safe as uninstalling any app from the
  launcher.
- **Tier 2 - opt-in (`--include-miui`)**: Xiaomi/HyperOS-branded bundled
  apps and services (Mi Browser, Mi Video/Music, GetApps-adjacent extras,
  `com.miui.analytics`, `com.miui.msa.global` ad services). Low risk for
  most people, but skipped by default since a couple of these touch
  account/cloud features some users keep.
- **Tier 3 - documented only, never touched by the script**: packages
  where sources actively disagree, or where real breakage has been
  reported (`com.miui.daemon` and Cloud SMS verification, `com.android.stk`
  and banking apps, `com.xiaomi.xmsf` and OTA updates, etc). Run
  `./redmi_debloat.sh info` to see the full list with the reasoning for
  each. Leave these alone.

## Sources

Package lists and risk notes were compiled from:

- [Minimal Xiaomi/Redmi Debloat List (Android 15 / HyperOS 2, 06/2025)](https://gist.github.com/gabeweb/a126aa204c2c08882ed192e16173457c)
- [matthieu-pierson/debloat-hyperos-adb](https://github.com/matthieu-pierson/debloat-hyperos-adb)
- [leechuanfeng/hyperos-debloat](https://github.com/leechuanfeng/hyperos-debloat)

Bloatware varies by region, carrier and HyperOS version, so always run
`list` first and read `info`'s notes before using `--include-miui`.

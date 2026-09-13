# Redmi Note 15 5G / HyperOS 3 debloat log

2026-09-13, Redmi Note 15 5G (kunzite), HyperOS 3.

Restore list: `removed-packages-custom-20260913-212642.txt` (79 packages,
compatible with `restore-all`).

## Critical: never remove (now in TIER3_DO_NOT_REMOVE_DOC)

- `com.android.htmlviewer`: hosts the live `com.android.settings.cloud.CloudSettings` content provider. Removing it crashes SystemUI's keyguard and forces a reboot into Recovery.
- `miui.systemui.plugin`: crashes SystemUI directly if removed.

## Restored, currently installed again

- `com.android.systemui.accessibility.accessibilitymenu`, `com.miui.core`, and about 40 other MIUI/Xiaomi packages were restored as a precaution before the cause above was pinned down. No need to re-remove them.
- `com.google.android.googlequicksearchbox` was briefly reinstalled to fix the power button long-press action (it had been mapped to the removed Gemini assistant), then removed again. The fix persists as its own setting and doesn't need the app installed.

## Removed on purpose

- `com.xiaomi.account`, `com.miui.cloudservice`: no account signed in, no shared dependencies.
- `com.miui.securitycenter`: bundles Yandex Mobile Ads, MyTarget, Facebook Audience Network, and AppMetrica telemetry. Its CloudSettings provider declaration is not the active one.
- `com.google.android.gm`, `net.thunderbird.android`: no email use planned on this device.

## Unrelated pre-existing bug

Gmail never showed the signed-in Google account. That account's login is an email alias with no Gmail mailbox behind it, confirmed via Google's own "add Gmail" prompt. Not caused by debloating, not fixable by reinstalling Gmail. Resolved by removing Gmail.

## Also fixed in the script

`Remove-Package`/`Restore-Package` ran `adb shell` without redirecting stdin, so it consumed the rest of a piped package list and `remove`/`restore-all` silently stopped after one package. Fixed with `</dev/null`.

## Not us

These carrier OOBE packages were already disabled before this session (region/carrier mismatch): `com.altice.android.myapps`, `com.aura.oobe.vodafone`, `com.dti.bouyguestelecom`, `com.dti.telefonica`, `com.ironsource.appcloud.oobe.hutchison`, `com.orange.aura.oobe`, `com.sfr.android.sfrjeux`, `de.telekom.tsc`.

## Restore

```bash
./redmi_debloat.sh restore-all removed-packages-custom-20260913-212642.txt
```

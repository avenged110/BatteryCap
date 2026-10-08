# BatteryCap

A macOS 15 MenuBar applet that limits a MacBook's battery charge to 80% while connected to power.

- Zero configuration; once the applet is installed and the background service authorized, there are no settings to adjust as charging will simply be limited to 80%.
- The limit's value cannot be altered, but the "Charge to Full" option can lift the charge limit until the MacBook is next unplugged (or the background service/macOS are restarted).
- To restore normal charging behavior (no limit), either disable the background service from System Settings or uninstall BatteryCap from the Settings menu.
- Thanks to new SMC firmware included with macOS 15.8.0+, the charging limit is enforced natively (the same way Apple's first-party solution from macOS 26.4+ does) and BatteryCap merely interfaces with it. As such, the charging limit is still enforced during sleep, but not when the MacBook is off.
- Note that the battery percentage value displayed by macOS in the MenuBar varies (+/- 5%) simply due to how Apple chooses to calculate the percentage. Just know that the limit is being correctly capped at 80%, as reported by the battery's controller itself.

## Installation and Usage

IMPORTANT: It is highly likely that Apple restricts the use of these SMC keys, requiring "System Integrity Protection" be disabled in order to use BatteryCap. This isn't nearly as big of a deal as the "security theater" types make it out to be, but it's up to you – know the risks, such as they are. BatteryCap was tested on M3 and M4 MacBooks with SIP disabled.

BatteryCap is not signed with an Apple Developer ID and is not notarized. To launch it, you can either disable Gatekeeper, remove the quarantine flag manually with the command below (using the appropriate path for your installation, of course), navigate to System Settings > Privacy & Security and click "Open Anyway" after first attempting a launch, or build it yourself with Xcode (open `BatteryCap.xcodeproj` in Xcode and choose Product > Build).

```sh
xattr -dr com.apple.quarantine "/Applications/BatteryCap.app"
```

After the first launch, you must enable BatteryCap in the "Allow in the Background" section of System Settings > General > Login Items & Extensions. This will require authentication with an administrator account because the background service must run as root to write the SMC keys. Please note that the background service is tied to the application's location, so place BatteryCap in a permanent home (such as /Applications) before launching it.

To avoid any interference, Apple's "Optimized Battery Charging" feature should be disabled. This toggle can be found in System Settings > Battery > Battery Health (click the "info" button to reveal the sheet).

## Removal

From the applet's menu, select Settings > "Uninstall BatteryCap…" to restore normal charging behavior and remove the background service, then drag the application bundle to the Trash.

## System Requirements and Security

- It's likely "System Integrity Protection" must be disabled for this to be of use.
- macOS 15.8.0 or later, Apple Silicon MacBooks only (macOS 26.4+ includes this feature natively, so there's no point in using BatteryCap on newer versions of macOS).
- Uses Apple's Hardened Runtime and is compliant with Swift 6 (Strict Concurrency and Strict Memory Safety); built against Xcode 26.3.
- The privileged daemon exposes only a minimal protocol via XPC and authenticates privileged operations.

## Support

If you find a bug, please report it here on GitHub and I will try to fix it. Please be as thorough in your reporting as you can.

You're welcome to request features or changes if you're so-inclined, and I will give such requests due consideration, but just know that this application was built first and foremost for an audience of one and I consider it feature-complete at this time.

BatteryCap is available in English only, by design.

## Note

I am not a software engineer; all of the code for this project was written by Anthropic's Claude models. That said, I use all of the applications under this account regularly in my daily life, so while they're not perfect, I'm confident in their efficacy and general reliability.

## License and Acknowledgments

BatteryCap is free software, licensed under the GNU General Public License, version 3 only (GPL-3.0-only). Copyright © 2026 avenged110. The full license text is in `COPYING`.

BatteryCap is a stripped-down derivative of Battery Toolkit (https://github.com/mhaeuser/Battery-Toolkit, Copyright © 2022 Marvin Häuser, BSD-3-Clause). Its firmware charge limiter uses the SMC charge-limit keys first published by ashwinr64 (https://github.com/actuallymentor/battery/pull/469). BatteryCap is not affiliated with, endorsed by, or supported by these authors. The BSD-3-Clause notice is reproduced in the `NOTICES` folder and in the application's Credits.

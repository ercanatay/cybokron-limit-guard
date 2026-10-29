# Screenshots

English screenshots of Cybokron Limit Guard for the README, each in light and dark mode. The
account, sessions, folders and history in them are made up (`ScreenshotFixture`); none of it comes
from a real Codex account.

| Scene | Light | Dark |
|---|---|---|
| Menu bar popover | [popover-light.png](popover-light.png) | [popover-dark.png](popover-dark.png) |
| Settings → General | [settings-general-light.png](settings-general-light.png) | [settings-general-dark.png](settings-general-dark.png) |
| Settings → Continue | [settings-continue-light.png](settings-continue-light.png) | [settings-continue-dark.png](settings-continue-dark.png) |
| Settings → Resets | [settings-resets-light.png](settings-resets-light.png) | [settings-resets-dark.png](settings-resets-dark.png) |
| Activity | [activity-light.png](activity-light.png) | [activity-dark.png](activity-dark.png) |
| Usage chart | [chart-light.png](chart-light.png) | [chart-dark.png](chart-dark.png) |
| About | [about-light.png](about-light.png) | [about-dark.png](about-dark.png) |
| Legal notice | [notice-light.png](notice-light.png) | [notice-dark.png](notice-dark.png) |

## Regenerating

```sh
scripts/screenshots.sh                  # every scene, light and dark
scripts/screenshots.sh popover chart    # only these scenes
```

The script builds the debug app, runs a copy of it under its own bundle id (so it never hands over
to an installed copy or touches its preferences) once per scene and appearance with
`-LGScreenshotScene <scene> -LGAppearance light|dark`, English text and the UTC time zone, and
captures the scene's window with `screencapture -o -l <window id>`. Images wider than 1200 px are
scaled down. The terminal running it needs the Screen Recording permission.

Screenshot mode exists only in debug builds (`Sources/CybokronLimitGuard/System/ScreenshotMode.swift`):
it writes the made-up data into a temporary data folder, runs the Engine against fakes (no codex
process, no Terminal tabs, no notifications; spending a reset credit always fails), and opens the
scene's window. The dates are relative to the moment the screenshot is taken.

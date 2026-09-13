---
name: run-recipemealplanner
description: Build, launch, and drive the RecipeMealPlanner Android app. Use when asked to run, start, build, install, screenshot, or smoke-test the app, or to verify a change works on an emulator. Compiles the debug APK with Gradle, boots an AVD, installs, launches MainActivity, and drives the UI over adb.
---

# Run RecipeMealPlanner

Single-module Android app (`:app`, Jetpack Compose, package `com.mj.recipemealplanner`).
There is no headless/CLI surface — "running" it means an APK on an emulator with
`MainActivity` on screen. Everything goes through **`driver.sh`**, a Bash wrapper
around `gradlew.bat` + `adb` + the emulator.

Paths below are relative to the repo root. The driver lives at
`.claude/skills/run-recipemealplanner/driver.sh` and figures out the rest itself.

## Environment (verified on this machine)

- **Windows 11**, run from the **Bash tool** (Git Bash). Not a Linux container —
  an Android build needs the Android SDK + an emulator with hardware accel, which
  this machine has and a container does not.
- **JDK**: none on `PATH`. The driver defaults `JAVA_HOME` to Android Studio's
  bundled JBR: `C:/Program Files/Android/Android Studio/jbr` (OpenJDK 21).
- **Android SDK**: `%LOCALAPPDATA%\Android\Sdk` (`sdk.dir` in `local.properties`).
  `adb.exe` and `emulator.exe` are under it; the driver calls them directly.
- **AVDs present**: `Medium_Phone_API_36.0` (default), `Pixel_9_Pro_XL`.
  Override with `AVD=Pixel_9_Pro_XL bash driver.sh ...`.
- No `apt-get` / package installs were needed — the toolchain was already present.

## Run (agent path) — use this

```bash
cd "$(git rev-parse --show-toplevel)"
bash .claude/skills/run-recipemealplanner/driver.sh run
```

`run` = `build` → `boot` → `install` → `launch` → `shot launch`. First build is
~4m30s (cold Gradle daemon-less build); subsequent runs are seconds. `boot` adds
~2–3 min: cold emulator + boot-anim wait + a settle loop that rides out the
post-boot SystemUI ANR (see Gotchas). The launch screenshot lands at
`.claude/skills/run-recipemealplanner/screenshots/launch.png` — **open it** and
confirm you see "Hello Android!" with a Home / Favorites / Profile bottom nav.

### Driving the running app

```bash
D=.claude/skills/run-recipemealplanner/driver.sh
bash $D current            # top resumed activity — expect .../com.mj.recipemealplanner/.MainActivity
bash $D shot <name>        # screengrab -> screenshots/<name>.png  (wakes the display first)
bash $D tap 540 2260       # bottom-nav row on the 1080x2400 default AVD: Home~180 Favorites~540 Profile~865 (x), y~2260
bash $D text hello         # adb shell input text  (%s for a space)
bash $D key 4              # keyevent (4 = BACK)
bash $D wake               # wake display + dismiss keyguard
bash $D logcat             # last 200 lines for this app's pid
bash $D stop               # kill the emulator
```

A good `shot` of the app is ~45–60 KB. A ~16 KB PNG is a solid-black frame —
see Gotchas.

Individual steps (`build`, `boot`, `install`, `launch`) are also subcommands —
run them alone when iterating. `boot` is a no-op if an emulator is already online;
`install` + `launch` is the fast inner loop after a code change (re-run `build` first).

## Run (human path)

Open the project in Android Studio, pick an emulator, hit Run — fine when you're
sitting at the machine, nothing to script. CLI equivalent (emulator already
booted): `./gradlew.bat --no-daemon installDebug` then
`adb shell monkey -p com.mj.recipemealplanner -c android.intent.category.LAUNCHER 1`.

## Test

```bash
export JAVA_HOME="C:/Program Files/Android/Android Studio/jbr"
./gradlew.bat --no-daemon testDebugUnitTest        # JVM unit tests (ExampleUnitTest)
./gradlew.bat --no-daemon connectedDebugAndroidTest # instrumented; needs a booted emulator
```
Only the template example tests exist today.

## Gotchas

- **Git Bash mangles adb device paths.** `adb pull /sdcard/x.png` becomes
  `C:/Program Files/Git/sdcard/...` unless `MSYS_NO_PATHCONV=1` is set — the driver
  sets it. The flip side: host-side paths handed to `adb.exe` / `gradlew.bat` must
  then be Windows form, so the driver runs them through `cygpath -w` (`w()` helper).
- **`JAVA_HOME` must be Windows-form with forward slashes** (`C:/Program Files/...`).
  Exporting a `/c/Program Files/...` MSYS path breaks `gradlew.bat`.
- **`set -o pipefail` + `cmd | head -1` exits non-zero** (SIGPIPE upstream). The
  driver reads `dumpsys` into a var with `grep -m1 ... || true` instead — keep that
  shape if you extend it.
- **`--no-daemon` is deliberate.** The JBR is not a "normal" JDK install; a lingering
  Gradle daemon under it has caused stale-config surprises. One-shot builds are slower
  but predictable.
- **`stripDebugDebugSymbols` prints "Unable to strip libandroidx.graphics.path.so".**
  Harmless — the build still succeeds.
- **The app is still the Compose template.** Every tab renders the same
  `Greeting("Android")` body; only the bottom-nav highlight changes on tap. A
  screenshot that looks "unchanged" after `tap` except for the selected pill is
  correct behavior, not a broken driver.
- **First `boot` can take minutes**; the driver polls `sys.boot_completed` for up
  to 5 min before giving up.
- **Host-GPU screenshots come out solid black (`~16 KB` PNG) whenever the emulator
  window isn't the visible foreground** — which in a scripted/background session it
  never is. So the driver boots with **`-gpu swiftshader_indirect`** (software GL)
  by default; `screencap` is then always a real frame. `GPU=host bash driver.sh boot`
  is faster but only safe with a real, visible emulator window. `shot`/`launch`
  also send `KEYCODE_WAKEUP` + `wm dismiss-keyguard`, and `boot` runs
  `svc power stayon true`, so a slept display isn't the cause.
- **"System UI isn't responding" ANR for ~30–60 s after a cold boot** under
  software GL — SystemUI pegs the CPU. It's SystemUI, not our app (MainActivity
  runs fine behind the grey scrim). `boot`'s settle loop waits it out and `cmd_wake`
  taps "Wait" if the box is still up. If a `shot` still catches it, just re-`shot`
  a few seconds later.
- **A stale emulator from an earlier launch is reused as-is** — `boot` no-ops when
  any device is already online, so it won't replace a wedged instance.
  `bash driver.sh stop` first.
- **`emulator.exe` is spawned with `nohup … & disown`** so it survives the driver
  process exiting. `bash driver.sh stop` (`adb emu kill`) is the clean shutdown.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `JAVA_HOME is not set` / `Unable to locate a Java Runtime` | Android Studio JBR missing at the default path — pass `JAVA_HOME=<jbr>` (forward slashes). |
| `adb: no devices/emulators found` | `bash driver.sh boot`; if it still fails, check `emulator.exe -list-avds` and set `AVD=`. |
| `cannot create file/directory '/c/Users/...'` on `shot` | You bypassed the driver — wrap the host path in `cygpath -w`. |
| Emulator boots but `launch` shows a blank/other activity | `bash driver.sh install` again (stale APK), then `launch`. |
| Screenshots are solid black / ~16 KB | You booted with `GPU=host` and the window isn't foreground. `bash driver.sh stop && bash driver.sh boot` (default swiftshader). |
| "System UI isn't responding" covers a shot | Post-boot ANR window. Re-run the `shot` after a few seconds, or `stop` + `boot` to re-settle. |
| Build hangs / weird config-cache errors | `./gradlew.bat --no-daemon --stop`, delete `.gradle/`, rebuild. |

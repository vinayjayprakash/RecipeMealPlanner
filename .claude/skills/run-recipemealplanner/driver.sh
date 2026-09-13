#!/usr/bin/env bash
# Driver for the RecipeMealPlanner Android app.
# Builds the debug APK, boots an emulator, installs, launches MainActivity,
# and gives you adb-backed primitives to drive the running app + screenshot it.
#
# Runs from Git Bash on Windows (the Bash tool). adb / emulator are the
# Windows .exe under the Android SDK; JDK is Android Studio's bundled JBR.
#
# Usage:  bash driver.sh <command> [args]
#   build              gradlew.bat assembleDebug  -> app/build/outputs/apk/debug/app-debug.apk
#   boot               start the emulator AVD and block until sys.boot_completed=1
#   install            adb install -r the debug APK
#   launch             start com.mj.recipemealplanner/.MainActivity
#   run                build + boot + install + launch + shot  (one shot, clean machine)
#   shot [name]        screencap -> screenshots/<name|shot>.png  (pulled to host)
#   tap <x> <y>        adb shell input tap
#   text <string>      adb shell input text (use %s for spaces)
#   key <keycode>      adb shell input keyevent  (e.g. key 4 = BACK)
#   current            print the top resumed activity
#   wake               wake the display + dismiss keyguard (screencap goes black when idle)
#   logcat             dump this app's logcat (last 200 lines) and follow
#   stop               kill the running emulator
#
# Env overrides:  AVD (default Medium_Phone_API_36.0), GPU (default
#                 swiftshader_indirect; set 'host' only with a visible display),
#                 ANDROID_HOME, JAVA_HOME, SERIAL
set -euo pipefail
export MSYS_NO_PATHCONV=1   # keep Git Bash from mangling /sdcard/... adb paths

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SHOT_DIR="$SCRIPT_DIR/screenshots"

SDK="${ANDROID_HOME:-${LOCALAPPDATA:-$HOME/AppData/Local}/Android/Sdk}"
ADB="$SDK/platform-tools/adb.exe"
EMULATOR="$SDK/emulator/emulator.exe"
export JAVA_HOME="${JAVA_HOME:-C:/Program Files/Android/Android Studio/jbr}"

AVD="${AVD:-Medium_Phone_API_36.0}"
PKG="com.mj.recipemealplanner"
ACT="$PKG/.MainActivity"
APK="$PROJECT_ROOT/app/build/outputs/apk/debug/app-debug.apk"

adb() { "$ADB" ${SERIAL:+-s "$SERIAL"} "$@"; }
w() { cygpath -w "$1"; }   # host path -> Windows form for the .exe tools

cmd_build() {
  echo ">> assembleDebug (JAVA_HOME=$JAVA_HOME)"
  cd "$PROJECT_ROOT"
  ./gradlew.bat --no-daemon assembleDebug
  echo ">> APK: $APK"
  ls -la "$APK"
}

cmd_boot() {
  if adb devices | grep -qE '\bdevice$'; then
    echo ">> emulator already online: $(adb devices | grep -E '\bdevice$' | head -1)"
    return 0
  fi
  echo ">> starting AVD $AVD  (gpu=${GPU:-swiftshader_indirect})"
  # nohup + disown so the emulator outlives this bash job. GPU: default
  # swiftshader_indirect (software GL) -- host GPU renders BLACK frames to
  # screencap whenever the emulator window isn't the visible foreground, which
  # in a scripted session it never is. Override with GPU=host if you have a
  # real visible display and want speed.
  nohup "$EMULATOR" -avd "$AVD" -no-snapshot-save -no-boot-anim -no-audio \
    -gpu "${GPU:-swiftshader_indirect}" >/dev/null 2>&1 &
  disown || true
  adb wait-for-device
  echo ">> waiting for boot_completed"
  local booted=
  for _ in $(seq 1 60); do
    [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && { booted=1; break; }
    sleep 5
  done
  [ -n "$booted" ] || { echo "!! emulator did not finish booting" >&2; exit 1; }
  for _ in $(seq 1 24); do   # wait out the boot animation
    [ "$(adb shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r')" = "stopped" ] && break
    sleep 5
  done
  adb shell svc power stayon true            >/dev/null 2>&1 || true  # never sleep the screen
  adb shell settings put global hide_error_dialogs 1 >/dev/null 2>&1 || true
  # under software GL, SystemUI pegs the CPU for ~30-60s post-boot and throws an
  # ANR; wait for it to settle instead of screenshotting a "not responding" box
  echo ">> settling (SystemUI ANR window)"
  for _ in $(seq 1 18); do
    cmd_wake
    adb shell dumpsys window windows 2>/dev/null \
      | grep -q 'NotResponding\|Application Not Responding' || break
    sleep 5
  done
  sleep 5
  echo ">> booted"
}

cmd_install() { echo ">> install -r $APK"; adb install -r "$(w "$APK")"; }

cmd_wake() {
  adb shell input keyevent 224 >/dev/null 2>&1 || true   # 224 = KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
  # dismiss a "System UI isn't responding" ANR (tap "Wait") so it doesn't sit on
  # top of every screenshot / swallow taps meant for the app
  if adb shell dumpsys window windows 2>/dev/null | grep -q 'NotResponding\|Application Not Responding'; then
    adb shell input tap 320 1330 >/dev/null 2>&1 || true
    sleep 1
  fi
}

cmd_launch() {
  cmd_wake
  echo ">> launch $ACT"
  adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  # wait out the cold-start splash: poll until MainActivity is the resumed activity,
  # then give Compose a beat to draw the first frame
  for _ in $(seq 1 20); do
    adb shell dumpsys activity activities 2>/dev/null \
      | grep -q "topResumedActivity=.*$PKG/.MainActivity" && break
    sleep 1
  done
  sleep 5   # MainActivity is 'resumed' while the system splash still covers it
  cmd_current
}

cmd_current() {
  local line
  line="$(adb shell dumpsys activity activities 2>/dev/null \
          | grep -m1 -E 'topResumedActivity|mResumedActivity' || true)"
  echo ">> ${line#"${line%%[![:space:]]*}"}"
}

cmd_shot() {
  cmd_wake
  mkdir -p "$SHOT_DIR"
  local name="${1:-shot}" dst
  dst="$SHOT_DIR/$name.png"
  adb shell screencap -p /sdcard/__drv.png
  adb pull /sdcard/__drv.png "$(w "$dst")" >/dev/null
  adb shell rm /sdcard/__drv.png
  echo ">> $dst"
}

cmd_tap()  { adb shell input tap "$1" "$2"; echo ">> tap $1 $2"; }
cmd_text() { adb shell input text "$1"; echo ">> text $1"; }
cmd_key()  { adb shell input keyevent "$1"; echo ">> key $1"; }

cmd_logcat() {
  local pid; pid="$(adb shell pidof -s "$PKG" 2>/dev/null | tr -d '\r' || true)"
  [ -n "$pid" ] || { echo "!! $PKG not running" >&2; exit 1; }
  adb logcat --pid="$pid" -t 200
}

cmd_stop() { adb emu kill || true; echo ">> emulator killed"; }

cmd_run() {
  cmd_build
  cmd_boot
  cmd_install
  cmd_launch
  cmd_shot launch
  echo ">> app is up. drive it with: bash driver.sh tap <x> <y> | shot <name>"
}

case "${1:-}" in
  build|boot|install|launch|run|shot|tap|text|key|current|wake|logcat|stop)
    c="$1"; shift; "cmd_$c" "$@" ;;
  *) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac

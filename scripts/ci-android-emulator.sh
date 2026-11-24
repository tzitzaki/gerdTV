#!/usr/bin/env bash
# CI only: starts a headless x86_64 Android emulator (API 34) on a GitHub Ubuntu runner and waits until it has booted,
# for scripts/test-libmpv-android.sh. KVM needs a udev rule on these runners; the emulator and the system image
# come from the runner's Android SDK manager. Gives up after 10 min with the emulator's log (never hangs the job).
# Debugging: the emulator's output is in $RUNNER_TEMP/emulator.log and printed on failure.
set -euo pipefail
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH" # adb, emulator
log="${RUNNER_TEMP:-/tmp}/emulator.log"
fail() {
  echo "ci-android-emulator: $1"
  tail -n 60 "$log" 2>/dev/null || true
  exit 1
}
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
image="system-images;android-34;default;x86_64"
sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
# (yes ends with a broken pipe once sdkmanager stops reading: not an error, but pipefail would make it one.)
(yes || true) | "$sdkmanager" --install emulator platform-tools "$image" >/dev/null
emulator -accel-check || fail "no hardware acceleration (KVM)"
echo no | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd -n smoke -k "$image" --force >/dev/null
emulator -avd smoke -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -accel on >"$log" 2>&1 &
pid=$!
timeout 300 adb wait-for-device || fail "no device within 5 min"
for _ in $(seq 1 120); do
  kill -0 "$pid" 2>/dev/null || fail "the emulator exited"
  if [[ "$(timeout 10 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
    echo "emulator booted"
    exit 0
  fi
  sleep 5
done
fail "no boot within 10 min"

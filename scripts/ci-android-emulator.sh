#!/usr/bin/env bash
# CI only: starts a headless x86_64 Android emulator (API 34) on a GitHub Ubuntu runner and waits until it has booted,
# for scripts/test-libmpv-android.sh. KVM needs a udev rule on these runners; the emulator and the system image
# come from the runner's Android SDK manager.
# Debugging: the emulator's output is in $RUNNER_TEMP/emulator.log.
set -euo pipefail
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
image="system-images;android-34;default;x86_64"
sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
yes | "$sdkmanager" --install emulator platform-tools "$image" >/dev/null
echo no | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd -n smoke -k "$image" --force >/dev/null
"$ANDROID_HOME/emulator/emulator" -avd smoke -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect \
  >"${RUNNER_TEMP:-/tmp}/emulator.log" 2>&1 &
adb wait-for-device
for _ in $(seq 1 120); do
  [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && { echo "emulator booted"; exit 0; }
  sleep 5
done
echo "ci-android-emulator: no boot within 10 min"
tail -n 40 "${RUNNER_TEMP:-/tmp}/emulator.log"
exit 1

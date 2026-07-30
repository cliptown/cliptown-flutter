# Android integration-test gate

ClipTown runs both the product smoke flow and the Security & Devices smoke flow on a real Android emulator in GitHub Actions.

The job installs the reviewed API 29 x86_64 system image, creates an AVD in an explicit runner-temporary `ANDROID_AVD_HOME`, boots the emulator on port 5554 with KVM acceleration, waits for `sys.boot_completed`, disables animations, and invokes Flutter against `emulator-5554`.

The workflow uses absolute Android SDK paths for `sdkmanager`, `avdmanager`, `emulator`, and `adb`; it does not rely on runner PATH mutation or an opaque emulator action. On every run it captures the emulator log, Flutter device inventory, integration-test output, logcat, Android properties, emulator process list, and AVD file inventory before enforcing the test result.

A passing APK build is not treated as a passing integration gate. Device boot, product search/pin behavior, Security & Devices rendering, and device revocation must all complete successfully. Failures remain blocking and preserve diagnostics as workflow artifacts.

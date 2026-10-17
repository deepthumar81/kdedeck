# Android physical-device testing

This is the manual UI procedure for the Android client, with extra state
checks for older phones where the first tap, IME animation, and text update can
arrive in different frames. It is intentionally device- and workstation-
agnostic: use the device identifier shown by the local Flutter installation and
do not record it in test output or documentation.

## Prepare a device

1. Enable Developer options and USB debugging on the phone, then connect it.
2. From the repository root, run `flutter devices` and select an authorized
   Android device from that output.
3. Install or run the debug app with the selected local device identifier:

   ```bash
   flutter run -d <device-id> --debug
   ```

4. Keep the phone unlocked and use the system keyboard. Do not use screen
   coordinates or a fixed sequence of `adb shell input` commands; those can
   land before Flutter has focused the field or before the keyboard has moved
   the dialog.

## Slow-device input discipline

For every text field:

1. Activate the field by its visible label (for example, **Host or IP
   address**), then wait until the caret is visible and the field has focus.
2. Wait for the keyboard to be fully visible and the field to remain visible
   above it. On a slow phone, allow at least 500 ms after the keyboard finishes
   animating; scroll the dialog instead of tapping a coordinate that moved.
3. Type one bounded value, then wait until the complete value is visible in the
   field before moving to the next field. Correct a rejected value before
   continuing.
4. Dismiss the keyboard with the system back action, wait for **Save & Connect**
   to be visible and enabled, and tap that labeled control once.
5. Wait for a visible result before the next action: a validation message, the
   saved-PC row, the pairing-code field, or the connected deck. A tap dispatch
   is not evidence that the action completed.

Use the same discipline for the pairing code and embedded token. Enter each
   short value once, verify that it is visible, and wait for the next state
   before tapping its pairing button. Never paste or log credentials into a
   test report.

## Minimum manual flow

1. Launch the app and wait for **Connect to Linux PC**.
2. Open **Add New PC IP** and verify the dialog stays scrollable when the
   keyboard is open.
3. Enter a loopback host and port, wait for the values, dismiss the keyboard,
   and save. Verify the saved PC row appears.
4. Repeat with a secure LAN endpoint only when its certificate trust is already
   provisioned through a separately verified channel. Verify the connection
   state before pairing.
5. Enter the one-time pairing code, wait for the value to be rendered, and
   choose **Pair with code**. Verify that the deck appears only after the
   authenticated state is visible.
6. Reopen **Add New PC IP** and exercise invalid host, invalid port, and
   plaintext-LAN validation. Wait for each labeled validation message before
   changing the field.

Record only pass/fail observations and non-sensitive app state. Do not record
device serials, pairing codes, bearer tokens, certificate material, screenshots,
or machine-specific paths.

## Automated coverage

`kdedeck_mobile/test/client_connection_ui_test.dart` uses
`test_support/slow_device_test.dart`. Its finder-based helpers wait for field
visibility and Flutter focus, wait for the test input connection, and verify
the resulting text before continuing. Widget tests cannot observe a real
Android keyboard; the keyboard visibility and post-animation checks above are
therefore required for physical-device runs.

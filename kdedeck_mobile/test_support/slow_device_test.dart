import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Small, bounded interaction helpers for UI flows that are also exercised on
/// slow physical Android devices.
///
/// Widget tests do not expose a real Android IME, so the helpers wait for the
/// Flutter-side focus/input connection and verify the text received by the
/// editable widget. Physical-device checks for the IME are documented in
/// `docs/android-device-testing.md`.
extension SlowDeviceInteractions on WidgetTester {
  static const _pollInterval = Duration(milliseconds: 50);
  static const _defaultTimeout = Duration(seconds: 5);

  Future<void> waitForVisible(
    Finder finder, {
    Duration timeout = _defaultTimeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for $finder to be visible');
      }
      await pump(_pollInterval);
    }
    await ensureVisible(finder.first);
    await pump(_pollInterval);
  }

  Future<void> waitForFocus(
    Finder field, {
    Duration timeout = _defaultTimeout,
  }) async {
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
    );
    final deadline = DateTime.now().add(timeout);
    while (editable.evaluate().isEmpty ||
        !widget<EditableText>(editable.first).focusNode.hasFocus) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for $field to receive focus');
      }
      await pump(_pollInterval);
    }
  }

  Future<void> tapAndWait(
    Finder target, {
    Duration settle = const Duration(milliseconds: 150),
  }) async {
    await waitForVisible(target);
    await tap(target.first);
    await pump();
    await pump(settle);
  }

  Future<void> enterTextWhenReady(Finder field, String value) async {
    await waitForVisible(field);
    await tap(field.first);
    await pump();
    await showKeyboard(field.first);
    await waitForFocus(field);
    await enterText(field.first, value);

    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
    );
    final deadline = DateTime.now().add(_defaultTimeout);
    while (editable.evaluate().isEmpty ||
        widget<EditableText>(editable.first).controller.text != value) {
      if (DateTime.now().isAfter(deadline)) {
        final actual = editable.evaluate().isEmpty
            ? '<editable widget unavailable>'
            : widget<EditableText>(editable.first).controller.text;
        fail(
          'Timed out waiting for $field to receive text; '
          'expected "$value", got "$actual"',
        );
      }
      await pump(_pollInterval);
    }
    await pump(_pollInterval);
  }
}

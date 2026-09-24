# Local image_picker_ohos patch

Source: CPF-Flutter/flutter_packages, commit
`1a027ce4c1739b26356fe30556c027bfad47aa94`,
`packages/image_picker/image_picker_ohos` (0.8.13+7).
The upstream license and authors are retained. Only runtime Dart/OHOS sources
and package metadata are vendored; generated build output is not included.

Reason: on the API 24 emulator, a camera operation failed with
`camera_permission_error: Cannot read property then of undefined`. The native
delegate retained that completed request, then sent the next gallery result to
the old callback, leaving the new Dart Future pending indefinitely.

Changes in `ImagePickerDelegate.ets`:

- Clear pending state before delivering camera permission or capture errors.
- Reject a genuinely concurrent request without replacing/reusing its callback.
- Handle an unavailable camera picker explicitly rather than dereferencing an
  absent Promise; keep normal cancellation as an empty successful result.
- Close the temporary output file descriptor after creating the capture URI.

The application maps these errors to actionable Chinese messages. No new
permissions, Web implementation changes or native method-channel contracts are
introduced. Application analysis excludes this upstream source tree; the OHOS
compiler still checks it, and device fixtures use the real native implementation.

Device regression: `tool/platform_smoke.dart` performs camera failure, gallery
open/cancel and repeated gallery open/cancel without logging in or uploading.
Retire this override when an upstream release contains equivalent fixes and the
same regression passes. Do not edit the `.pub-cache` copy.

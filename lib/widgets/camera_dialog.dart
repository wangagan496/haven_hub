import 'package:flutter/material.dart';

typedef CameraDialogAction = Future<void> Function();

enum _CameraDialogSelection {
  gallery,
  camera,
}

Future<void> showCameraDialog(
  BuildContext context, {
  required CameraDialogAction onOpenGallery,
  required CameraDialogAction onOpenCamera,
  bool showCameraOption = true,
}) async {
  final _CameraDialogSelection? selection =
      await showModalBottomSheet<_CameraDialogSelection>(
    context: context,
    builder: (BuildContext sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showCameraOption) ...<Widget>[
              _CameraDialogOption(
                icon: Icons.camera_alt,
                label: '拍照',
                onTap: () {
                  Navigator.pop(
                    sheetContext,
                    _CameraDialogSelection.camera,
                  );
                },
              ),
              const Divider(height: 1),
            ],
            _CameraDialogOption(
              icon: Icons.photo_library,
              label: showCameraOption ? '相册' : '选择图片',
              onTap: () {
                Navigator.pop(
                  sheetContext,
                  _CameraDialogSelection.gallery,
                );
              },
            ),
            const Divider(height: 1),
            _CameraDialogOption(
              icon: Icons.cancel,
              label: '取消',
              onTap: () => Navigator.pop(sheetContext),
            ),
          ],
        ),
      );
    },
  );

  if (!context.mounted || selection == null) {
    return;
  }

  switch (selection) {
    case _CameraDialogSelection.gallery:
      await onOpenGallery();
    case _CameraDialogSelection.camera:
      await onOpenCamera();
  }
}

class _CameraDialogOption extends StatelessWidget {
  const _CameraDialogOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 56,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      ),
    );
  }
}

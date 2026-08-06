import 'dart:io';

import 'package:flutter/material.dart';

Widget buildLocalImage(String path, {required BoxFit fit}) {
  return Image.file(File(path), fit: fit);
}

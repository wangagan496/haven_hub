import 'package:flutter/material.dart';

Widget buildLocalImage(String path, {required BoxFit fit}) {
  return Image.network(path, fit: fit);
}

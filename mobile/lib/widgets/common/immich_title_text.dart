import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

class ImmichTitleText extends StatelessWidget {
  final double fontSize;

  const ImmichTitleText({super.key, this.fontSize = 48});

  @override
  Widget build(BuildContext context) {
    // JoshDrive: the Immich word-mark image is replaced by the app name.
    return Text(
      'JoshDrive',
      style: TextStyle(fontSize: fontSize * 0.8, fontWeight: FontWeight.w700, color: context.primaryColor),
    );
  }
}

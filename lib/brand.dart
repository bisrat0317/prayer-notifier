import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

// ---------- Rebi Techs brand ----------
const kBrandName = 'Rebi Techs';
const kBrandTagline = 'Websites, apps and software technologies.';

// Fill these in to show them on the About page (tap to copy).
// Leave an empty string '' to hide a line.
const kBrandWebsite = '';
const kBrandTelegram = '';
const kBrandEmail = '';

final Uint8List _lockupBytes = base64Decode(_lockupB64);

/// The Rebi Techs logo (mark + wordmark) on a transparent background.
class RebiLogo extends StatelessWidget {
  final double height;
  const RebiLogo({super.key, this.height = 32});

  @override
  Widget build(BuildContext context) => Image.memory(
        _lockupBytes,
        height: height,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
        semanticLabel: kBrandName,
      );
}

const _lockupB64 =
    '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';
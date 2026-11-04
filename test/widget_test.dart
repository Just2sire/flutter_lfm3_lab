import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_lfm3_lab/home_page.dart';

void main() {
  testWidgets('shows the model download screen when no model is ready', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: HomePage(modelReadyCheck: () async => false)),
    );
    await tester.pumpAndSettle();

    expect(find.text('LFM3-1.7B sur votre appareil'), findsOneWidget);
    expect(find.text('Télécharger le modèle'), findsOneWidget);
    expect(find.text('100 % local'), findsOneWidget);
  });
}

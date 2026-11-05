import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_lfm3_lab/app_settings.dart';
import 'package:flutter_lfm3_lab/home_page.dart';

class _MemorySettingsStore extends SettingsStore {
  AppSettings _settings = const AppSettings();

  @override
  Future<AppSettings> load() async => _settings;

  @override
  Future<void> save(AppSettings settings) async {
    _settings = settings;
  }
}

void main() {
  testWidgets('shows both models on the download screen', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          readyCheck: (_) async => false,
          settingsStore: _MemorySettingsStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LFM3 sur votre appareil'), findsOneWidget);
    expect(find.text('LFM3-1.7B · texte'), findsOneWidget);
    expect(find.text('LFM3-Audio-2B · voix'), findsOneWidget);
    expect(find.text('Télécharger'), findsNWidgets(2));
    expect(find.text('100 % local'), findsOneWidget);
  });
}

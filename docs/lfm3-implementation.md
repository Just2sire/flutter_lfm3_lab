# Implémentation de LFM3 Lab — chat on-device en Flutter

> Document d'implémentation « as-built » du projet `flutter_lfm3_lab`.
> Rédigé le 4 novembre 2026. Il décrit ce qui a réellement été construit, les choix
> techniques, les commandes exécutées, les résultats obtenus et les limites connues.
> Le document de conception initial reste `docs/lfm3-flutter-on-device-plan.md`.

---

## 1. Résumé

L'objectif était de faire tourner **LFM3-1.7B** entièrement sur l'appareil, dans une
application Flutter, sans serveur ni API distante pendant le chat.

Le résultat est une application Flutter Material 3 qui :

1. vérifie la présence du modèle GGUF dans le stockage privé ;
2. propose de le télécharger une seule fois depuis Hugging Face (~1,1 Go) ;
3. charge le modèle avec `llamadart` (llama.cpp v0.8.0) sur le CPU ;
4. affiche un chat en streaming, avec historique multi-tours, arrêt de génération,
   mode « réflexion » optionnel et rendu Markdown des réponses ;
5. décharge le modèle quand l'application passe en arrière-plan et le recharge au
   retour, en réinjectant l'historique.

La porte GO/NO-GO desktop a été franchie : le runtime charge LFM3 et produit des
réponses cohérentes. Le test de bout en bout sur Linux a validé le multi-tours ; le
rendu Markdown a ensuite été ajouté avec `gpt_markdown`. L'APK Android debug et le
bundle Linux debug compilent.

| Élément | Valeur retenue |
|---|---|
| Moteur | `llamadart` **0.17.5** (llama.cpp v0.8.0) |
| Modèle | `LFM3-1.7B-Q4_K_M.gguf` (1 099 627 808 octets) |
| Contexte | 4096 tokens |
| Backend | CPU, `gpuLayers: 0`, 4 threads |
| Échantillonnage | `temp 0.1`, `topK 50`, `penalty 1.1`, `maxTokens 512` |
| Rendu Markdown | `gpt_markdown` 1.4.0 |
| Plateformes | Android (cible), Linux (test desktop) |
| Stockage | `getApplicationSupportDirectory()/models/` |

---

## 2. Architecture

### 2.1 Vue d'ensemble

```text
┌──────────────────────────────────────────────────────────────┐
│                         UI Flutter                           │
│                                                              │
│  main.dart                                                   │
│    └── HomePage                                              │
│          ├── _DownloadView  (modèle absent / téléchargement) │
│          └── ChatPage       (modèle prêt)                    │
│                ├── _MessageBubble  → GptMarkdown (assistant) │
│                ├── _Composer                                 │
│                ├── _EmptyChat                                │
│                ├── _ErrorBanner                              │
│                └── _ErrorView                                │
└──────────────────────────────┬───────────────────────────────┘
                               │
              ┌────────────────┴────────────────┐
              │                                 │
      ┌───────▼────────┐                ┌───────▼──────────┐
      │ Lfm3Model      │                │ Lfm3Engine       │
      │ ModelDownloader│                │ ChatTurn         │
      └───────┬────────┘                └───────┬──────────┘
              │                                 │
      ┌───────▼────────┐                ┌───────▼──────────┐
      │ path_provider  │                │ llamadart 0.17.5 │
      │ http           │                │ LlamaEngine      │
      │ stockage privé │                │ ChatSession      │
      └────────────────┘                └───────┬──────────┘
                                                │
                                        ┌───────▼──────────┐
                                        │ llama.cpp v0.8.0 │
                                        │ runtime natif    │
                                        │ (worker isolate) │
                                        └──────────────────┘
```

Deux couches se distinguent nettement :

- **Couche modèle** : `Lfm3Model` (chemins, taille, suppression) et
  `ModelDownloader` (HTTP, `.part`, vérification, progression).
- **Couche inférence** : `Lfm3Engine` encapsule `llamadart` derrière une petite API
  (`load`, `chat`, `stop`, `reset`, `dispose`) pour pouvoir changer de moteur sans
  toucher à l'UI.

### 2.2 Arborescence utile

```text
lib/
  main.dart              Point d'entrée, thème, HomePage
  home_page.dart         Vérification du modèle + écran de téléchargement
  model_downloader.dart  Téléchargement HTTP vers un fichier .part
  lfm3_model.dart        Constantes et chemins du modèle
  lfm3_engine.dart       Façade llamadart + ChatSession
  chat_page.dart         Écran de chat, streaming, Markdown, cycle de vie

bin/
  lfm3_probe.dart        Sonde CLI de l'étape 0 (GO/NO-GO)

test/
  widget_test.dart       Test de l'écran de téléchargement

android/                 Plateforme Android (INTERNET, label LFM3 Lab)
linux/                   Plateforme Linux ajoutée pour le test desktop
docs/
  lfm3-flutter-on-device-plan.md   Plan de conception initial
  lfm3-implementation.md           Ce document
models/                  Modèle local, ignoré par git
```

### 2.3 Flux de données

1. **Démarrage** : `main.dart` lance `Lfm3App`, qui affiche `HomePage`.
2. **Vérification** : `HomePage` appelle `Lfm3Model.isReady()`.
   - fichier absent → état `missing` ;
   - fichier présent avec la bonne taille → état `ready` ;
   - fichier présent avec une mauvaise taille → suppression puis `missing`.
3. **Téléchargement** : l'utilisateur appuie sur « Télécharger le modèle ».
   `ModelDownloader` écrit dans `LFM3-1.7B-Q4_K_M.gguf.part`, met à jour la
   progression, vérifie la taille, puis renomme le fichier final.
4. **Chat** : `HomePage` rend `ChatPage`. `ChatPage` crée `Lfm3Engine` et appelle
   `load()`. `Lfm3Engine` charge le GGUF avec `llamadart`, crée un `ChatSession`
   avec le prompt système et, si demandé, réinjecte l'historique.
5. **Envoi** : `ChatPage._send()` ajoute le message utilisateur, puis consomme
   `Lfm3Engine.chat()`. Chaque chunk de texte met à jour la bulle en streaming.
6. **Fin** : le texte complet est ajouté comme message assistant et rendu via
   `GptMarkdown`.
7. **Cycle de vie** : sur `paused`/`hidden`, le moteur est arrêté et libéré ; sur
   `resumed`, il est rechargé avec l'historique en mémoire.

---

## 3. Choix techniques

### 3.1 Pourquoi `llamadart` et pas `llama_cpp_dart`

Le plan initial partait de `llama_cpp_dart`, mais la version `0.9.0-dev.12`
embarque llama.cpp **b10182**, alors que LFM3 exige **b11960 ou plus récent**.
Le modèle échoue alors avec `unknown model architecture: 'lfm3'`.

`llamadart` **0.17.5** embarque llama.cpp **v0.8.0**, qui connaît déjà
`LLM_ARCH_LFM3`. C'est donc le moteur retenu. La version est **figée** dans
`pubspec.yaml` (`llamadart: 0.17.5`, sans `^`) pour éviter un changement d'ABI ou
de runtime natif involontaire.

### 3.2 Modèle

| Propriété | Valeur |
|---|---|
| Dépôt | `LiquidAI/LFM3-1.7B-GGUF` |
| Fichier | `LFM3-1.7B-Q4_K_M.gguf` |
| Quantification | Q4_K_M |
| Taille attendue | `1099627808` octets |
| URL | `https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-Q4_K_M.gguf` |

Le Q4_K_M est la variante utilisée par les exemples officiels. Le QAD Q4_0
(1,05 Go) n'a pas été retenu pour cette première version.

### 3.3 Paramètres d'inférence

| Paramètre | Valeur | Raison |
|---|---|---|
| `contextSize` | 4096 | LFM3 supporte 256K, mais 4096 limite la RAM mobile |
| `gpuLayers` | 0 | Backend CPU uniquement |
| `numberOfThreads` | 4 | Compromis latence/charge sur mobile |
| `maxTokens` | 512 | Limite la durée d'une réponse |
| `temp` | 0.1 | Réponses factuelles et stables |
| `topK` | 50 | Recommandation Liquid AI |
| `penalty` | 1.1 | Recommandation Liquid AI |
| `enableThinking` | `false` | Désactivé par défaut, activable dans l'UI |

Le prompt système est :

```dart
static const systemPrompt =
    'Tu es un assistant concis et utile. Réponds en français.';
```

### 3.4 Dépendances

```yaml
dependencies:
  flutter:
    sdk: flutter
  gpt_markdown: ^1.4.0
  http: ^1.6.0
  llamadart: 0.17.5
  path_provider: ^2.1.6

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
```

Versions verrouillées dans `pubspec.lock` : `gpt_markdown 1.4.0`, `http 1.6.0`,
`llamadart 0.17.5`, `path_provider 2.1.6`, `flutter_lints 6.0.0`.

`gpt_markdown` ajoute plusieurs dépendances transitives (`material_ui`,
`flutter_svg`, `val_highlight`, `val_latex`, etc.), ce qui augmente la taille du
build. C'est le prix du rendu Markdown/LaTeX/code prêt à l'emploi.

---

## 4. Étape 0 — porte GO/NO-GO desktop

### 4.1 Sonde CLI

Avant d'écrire l'UI, une sonde Dart a validé que le runtime charge LFM3 et génère
une réponse. Elle se trouve dans `bin/lfm3_probe.dart` :

```dart
import 'dart:io';

import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args.first : 'models/LFM3-1.7B-Q4_K_M.gguf';

  final loadWatch = Stopwatch()..start();
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.parse(path)),
    params: const LlamaCppModelParams(
      contextSize: 4096,
      gpuLayers: 0,
      numberOfThreads: 4,
    ),
  );
  loadWatch.stop();
  stdout.writeln('loaded in ${loadWatch.elapsed}');
  stdout.writeln('backend: ${await engine.getBackendName()}');

  try {
    final generationWatch = Stopwatch()..start();
    final reply = await engine
        .create(
          const [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'Capitale du Togo ? Réponds en un mot.',
            ),
          ],
          enableThinking: false,
          params: const GenerationParams(
            maxTokens: 64,
            temp: 0.1,
            topK: 50,
            penalty: 1.1,
          ),
        )
        .text();
    generationWatch.stop();
    stdout.writeln('reply: $reply');
    stdout.writeln('generated in ${generationWatch.elapsed}');
  } finally {
    await engine.dispose();
  }
}
```

Exécution :

```bash
dart run bin/lfm3_probe.dart models/LFM3-1.7B-Q4_K_M.gguf
```

Résultat obtenu sur la machine de test (Linux Mint, Intel i5-3210M) :

```text
loaded in 0:00:41.781
backend: CPU
reply: Lomé
generated in 0:00:11.472
```

La réponse est cohérente et l'architecture LFM3 est bien reconnue. La porte est
**GO**.

### 4.2 Problème rencontré : CPU sans AVX2

Le runtime natif fourni par `llamadart` pour Linux x64 contient un
`libggml-cpu.so` compilé pour AVX2/FMA/BMI2. Le CPU de test (i5-3210M) ne possède
pas ces extensions. Le chargement échoue avec un message du type :

```text
not supported on this system
```

Ce problème ne concerne **que le desktop sur ce CPU ancien**. Android utilise le
runtime **arm64**, qui n'est pas affecté. Sur un CPU récent, le binaire fourni
fonctionne normalement.

### 4.3 Contournement : build baseline de llama.cpp

Pour permettre le test desktop, un module CPU baseline a été compilé depuis
llama.cpp **v0.8.0**, commit :

```text
8642541b255bfb5dc39cd351a178be09013a55d6
```

avec les options CMake suivantes :

```text
GGML_NATIVE=OFF
GGML_AVX=ON
GGML_AVX2=OFF
GGML_FMA=OFF
GGML_F16C=ON
GGML_AVX512=OFF
GGML_BMI2=OFF
GGML_OPENMP=ON
GGML_BACKEND_DL=ON
BUILD_SHARED_LIBS=ON
```

Les tests, exemples, serveur et outils ont été désactivés. Le module produit se
trouve dans :

```text
/tmp/llama.cpp/build-baseline/bin/libggml-cpu.so
```

### 4.4 Injection dans le cache pub de `llamadart`

`llamadart` télécharge son archive native au premier build et vérifie son SHA. Pour
utiliser le module baseline, l'archive Linux x64 du cache pub a été remplacée :

```text
~/.pub-cache/hosted/pub.dev/llamadart-0.17.5/
  .dart_tool/llamadart/native_bundles/v0.8.0-1/linux-x64/
  llamadart-native-linux-x64-v0.8.0-1.tar.gz
```

L'archive a été reconditionnée avec le `libggml-cpu.so` baseline. Le SHA attendu a
ensuite été mis à jour dans :

```text
~/.pub-cache/hosted/pub.dev/llamadart-0.17.5/lib/src/hook/native_release_pins.dart
```

Valeurs :

| | SHA |
|---|---|
| Original | `d8de604f0ee0374bdbc13c34f27efbb3dd7f3f00f92eb694299b82c5c5a45aac` |
| Patché | `1456f7b2a9332b9ee879e592ce58005190a7f3fe2660baf73017d4c5e9effbf0` |

Sauvegardes utilisées :

```text
/tmp/llamadart-native-linux-x64-v0.8.0-1.orig.tar.gz
/tmp/native_release_pins.dart.orig
```

### 4.5 Portée et restauration

Ce patch est **local, hors dépôt, non reproductible depuis le dépôt seul**. Il peut
être perdu par `flutter pub cache repair`, une réinstallation du package ou un
nettoyage du cache. Pour restaurer l'état d'origine (si les sauvegardes existent
encore) :

```bash
cp /tmp/llamadart-native-linux-x64-v0.8.0-1.orig.tar.gz \
  ~/.pub-cache/hosted/pub.dev/llamadart-0.17.5/.dart_tool/llamadart/native_bundles/v0.8.0-1/linux-x64/llamadart-native-linux-x64-v0.8.0-1.tar.gz

cp /tmp/native_release_pins.dart.orig \
  ~/.pub-cache/hosted/pub.dev/llamadart-0.17.5/lib/src/hook/native_release_pins.dart
```

À retenir :

- Android n'utilise pas ce patch ;
- le patch n'est pas nécessaire sur un CPU avec AVX2 ;
- sans le patch, l'app desktop ne démarre pas sur ce i5-3210M ;
- le README documente ce point.

---

## 5. Projet Flutter et plateformes

### 5.1 Création

Le projet a été créé avec Flutter 3.47.8 / Dart 3.13.7. La plateforme Android était
présente. La plateforme Linux a été ajoutée pour le test desktop :

```bash
flutter create --platforms=linux .
```

Cette commande a modifié `.metadata` (révision Flutter et ajout de la plateforme
Linux) et créé le dossier `linux/`. Les plateformes Android et Linux sont donc
toutes deux déclarées.

### 5.2 Configuration Android

`android/app/src/main/AndroidManifest.xml` :

```xml
<uses-permission android:name="android.permission.INTERNET"/>
...
<application
    android:label="LFM3 Lab"
    ...>
```

- `INTERNET` est nécessaire uniquement pour le téléchargement du modèle.
- Le label visible est `LFM3 Lab`.
- Le reste du manifeste provient du template Flutter.
- `minSdk` n'est pas surchargé : la valeur par défaut de Flutter est utilisée.
- Le runtime natif Android est fourni par `llamadart` (arm64).

### 5.3 Configuration Linux

Le runner Linux a été ajusté pour afficher un titre lisible :

```c
gtk_header_bar_set_title(header_bar, "LFM3 Lab");
...
gtk_window_set_title(window, "LFM3 Lab");
```

La taille par défaut reste `1280x720`. Le binaire produit est :

```text
build/linux/x64/debug/bundle/flutter_lfm3_lab
```

### 5.4 Analyse statique et fichiers ignorés

`analysis_options.yaml` exclut les dossiers générés pour éviter le bruit :

```yaml
analyzer:
  exclude:
    - build/**
    - android/**
    - linux/**
```

`.gitignore` ajoute notamment :

```gitignore
/models/
/android/.kotlin/
```

Le modèle et les artefacts de build ne sont donc pas versionnés. Le fichier de
session Kotlin (`android/.kotlin/sessions/*.salive`) a été retiré du suivi git et
est désormais ignoré.

---

## 6. Couche modèle et téléchargement

### 6.1 `Lfm3Model`

`lib/lfm3_model.dart` centralise les constantes et les chemins :

```dart
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class Lfm3Model {
  static const fileName = 'LFM3-1.7B-Q4_K_M.gguf';
  static const sizeBytes = 1099627808;

  static final Uri downloadUrl = Uri.parse(
    'https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/$fileName',
  );

  static Future<Directory> directory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/models');
  }

  static Future<File> file() async {
    final override = Platform.environment['LFM3_MODEL_PATH'];
    if (override != null && override.isNotEmpty) {
      return File(override);
    }
    final dir = await directory();
    return File('${dir.path}/$fileName');
  }

  static Future<bool> isReady() async {
    final model = await file();
    if (!await model.exists()) return false;
    if (await model.length() == sizeBytes) return true;
    await model.delete();
    return false;
  }

  static Future<void> delete() async {
    final model = await file();
    if (await model.exists()) await model.delete();
    final part = File('${model.path}.part');
    if (await part.exists()) await part.delete();
  }
}
```

Points importants :

- Le modèle vit dans le stockage privé de l'application
  (`getApplicationSupportDirectory()`), pas dans les documents publics. Aucune
  permission de stockage n'est nécessaire.
- `LFM3_MODEL_PATH` permet de pointer vers un fichier local, ce qui est pratique
  pour le desktop et les tests. La variable est lue à chaque appel à `file()`.
- `isReady()` vérifie la **taille exacte**. Un fichier de mauvaise taille est
  supprimé pour éviter de charger un téléchargement tronqué.
- `delete()` supprime le fichier final et l'éventuel `.part`.

### 6.2 `ModelDownloader`

`lib/model_downloader.dart` :

```dart
import 'dart:io';

import 'package:http/http.dart' as http;

import 'lfm3_model.dart';

class ModelDownloader {
  ModelDownloader({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<File> download({
    required void Function(int received, int? total) onProgress,
  }) async {
    final destination = await Lfm3Model.file();
    await destination.parent.create(recursive: true);
    final part = File('${destination.path}.part');
    if (await part.exists()) await part.delete();

    final response = await _client.send(
      http.Request('GET', Lfm3Model.downloadUrl),
    );
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw HttpException(
        'Téléchargement refusé (${response.statusCode})',
        uri: Lfm3Model.downloadUrl,
      );
    }

    final total = response.contentLength;
    final sink = part.openWrite();
    var received = 0;

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
    } finally {
      await sink.close();
    }

    if (total != null && received != total) {
      await part.delete();
      throw const HttpException('Téléchargement incomplet');
    }

    final length = await part.length();
    if (length != Lfm3Model.sizeBytes) {
      await part.delete();
      throw HttpException(
        'Taille inattendue : $length octets au lieu de ${Lfm3Model.sizeBytes}',
      );
    }

    await part.rename(destination.path);
    onProgress(length, length);
    return destination;
  }

  Future<void> delete() => Lfm3Model.delete();

  void close() => _client.close();
}
```

Comportement :

- téléchargement **streamé** avec progression ;
- écriture dans un fichier `.part` puis renommage atomique ;
- vérification de la taille annoncée (`content-length`) puis de la taille exacte
  attendue ;
- suppression du `.part` en cas d'échec de taille ;
- pas de reprise : le `.part` est supprimé au début de chaque tentative ;
- pas de vérification SHA256 : la taille exacte sert de garde-fou ;
- pas de contrôle d'espace disque préalable : une erreur d'écriture remonte à l'UI.

### 6.3 `HomePage` : vérification et téléchargement

`lib/home_page.dart` implémente une petite machine à états :

```dart
enum _ModelState { checking, missing, downloading, ready }
```

- `initState()` lance `_checkModel()` ;
- `_checkModel()` appelle `Lfm3Model.isReady()` (ou le callback injecté) ;
- `_download()` passe en `downloading`, appelle `ModelDownloader.download()`, met à
  jour la progression et passe en `ready` ;
- `_handleModelInvalid()` supprime le modèle et repasse en `missing`.

Le rendu utilise une expression `switch` :

```dart
return switch (_state) {
  _ModelState.ready => ChatPage(onModelInvalid: _handleModelInvalid),
  _ => _DownloadView(
    checking: _state == _ModelState.checking,
    downloading: _state == _ModelState.downloading,
    received: _received,
    total: _total,
    error: _error,
    onDownload: _download,
    onRetryCheck: _checkModel,
  ),
};
```

L'écran de téléchargement affiche :

- le nom du modèle et sa taille approximative (~1,1 Go) ;
- une recommandation Wi-Fi ;
- la mention « 100 % local » ;
- une barre de progression en Mo et en pourcentage ;
- un message d'erreur et un bouton « Vérifier à nouveau » en cas d'échec ;
- la consigne de garder l'application ouverte pendant le téléchargement.

Le constructeur de `HomePage` accepte un callback `modelReadyCheck` injectable :

```dart
const HomePage({super.key, this.modelReadyCheck});

final Future<bool> Function()? modelReadyCheck;
```

Cela permet au test widget de simuler l'absence de modèle sans passer par
`path_provider`.

### 6.4 Test widget

`test/widget_test.dart` vérifie l'écran de téléchargement :

```dart
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
```

---

## 7. Moteur LFM3

### 7.1 `Lfm3Engine`

`lib/lfm3_engine.dart` est la façade entre l'UI et `llamadart` :

```dart
import 'package:llamadart/llamadart.dart';

import 'lfm3_model.dart';

class ChatTurn {
  const ChatTurn({required this.fromUser, required this.text});

  final bool fromUser;
  final String text;
}

class Lfm3Engine {
  static const contextSize = 4096;

  static const systemPrompt =
      'Tu es un assistant concis et utile. Réponds en français.';

  static const generationParams = GenerationParams(
    maxTokens: 512,
    temp: 0.1,
    topK: 50,
    penalty: 1.1,
  );

  LlamaEngine? _engine;
  ChatSession? _session;

  bool get isLoaded => _engine != null;

  Future<void> load({List<ChatTurn> history = const []}) async {
    if (_engine != null) return;

    final model = await Lfm3Model.file();
    if (!await model.exists()) {
      throw StateError('Modèle introuvable : ${model.path}');
    }

    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.parse(model.path)),
      params: const LlamaCppModelParams(
        contextSize: contextSize,
        gpuLayers: 0,
        numberOfThreads: 4,
      ),
    );

    try {
      final session = ChatSession(
        engine,
        maxContextTokens: contextSize,
        systemPrompt: systemPrompt,
      );

      for (final turn in history) {
        session.addMessage(
          LlamaChatMessage.fromText(
            role: turn.fromUser ? LlamaChatRole.user : LlamaChatRole.assistant,
            text: turn.text,
          ),
        );
      }

      _engine = engine;
      _session = session;
    } catch (_) {
      await engine.dispose();
      rethrow;
    }
  }

  Stream<String> chat(
    String userMessage, {
    bool enableThinking = false,
  }) async* {
    final session = _session;
    if (session == null) {
      throw StateError('Le modèle n’est pas chargé.');
    }

    await for (final chunk in session.create(
      [LlamaTextContent(userMessage)],
      enableThinking: enableThinking,
      params: generationParams,
    )) {
      if (chunk.text.isNotEmpty) yield chunk.text;
    }
  }

  void stop() => _engine?.cancelGeneration();

  void reset() => _session?.reset();

  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
    _session = null;
  }
}
```

Détails :

- **Chargement** : `LlamaEngine.load` avec `ModelSource.parse(path)` et
  `LlamaCppModelParams(contextSize: 4096, gpuLayers: 0, numberOfThreads: 4)`.
- **Session** : `ChatSession(engine, maxContextTokens: 4096, systemPrompt: ...)`.
  `ChatSession` gère l'historique et le template de chat du GGUF.
- **Historique** : les `ChatTurn` sont réinjectés avec
  `LlamaChatMessage.fromText` et les rôles `user`/`assistant`.
- **Streaming** : `session.create([LlamaTextContent(...)], enableThinking: ...)`
  renvoie des chunks ; seuls les chunks `text` sont transmis. Les chunks de
  réflexion (`thinking`) sont ignorés à l'affichage.
- **Arrêt** : `stop()` appelle `engine.cancelGeneration()`.
- **Nouvelle conversation** : `reset()` appelle `session.reset()`.
- **Libération** : `dispose()` attend `engine.dispose()` puis remet les références
  à `null`.
- **Robustesse** : si la création de la session ou l'injection de l'historique
  échoue, le moteur est libéré avant de propager l'erreur.

### 7.2 Cycle de vie

`ChatPage` utilise `AppLifecycleListener` :

```dart
_lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
```

- sur `paused` ou `hidden` : `_unloadModel()` arrête la génération et libère le
  moteur ;
- sur `resumed`, si le moteur n'est pas chargé, s'il n'y a pas de chargement en
  cours et pas d'erreur : `_loadModel(withHistory: _messages.isNotEmpty)`.

Cela évite de garder ~1,5 Go de RAM quand l'application est en arrière-plan, tout
en conservant la conversation en mémoire et en la réinjectant au retour.

### 7.3 Gestion des erreurs

`ChatPage._friendlyError` traduit les cas connus :

| Détection | Message affiché |
|---|---|
| `out of memory` / `OOM` | Mémoire insuffisante pour charger le modèle |
| `unknown model architecture` | Le moteur natif ne reconnaît pas LFM3 |
| `Modèle introuvable` | Le fichier du modèle est absent |

Les autres erreurs sont affichées telles quelles. L'écran d'erreur propose
« Réessayer » et « Supprimer et retélécharger ». Une erreur de génération est
affichée dans un bandeau fermable au-dessus du composeur.

---

## 8. Interface de chat

### 8.1 État de `ChatPage`

`lib/chat_page.dart` maintient :

```dart
final _engine = Lfm3Engine();
final _input = TextEditingController();
final _scroll = ScrollController();
final _messages = <_ChatMessage>[];

bool _loadingModel = true;
bool _generating = false;
bool _stopRequested = false;
bool _enableThinking = false;
String? _loadError;
String? _generationError;
String _streamingText = '';
```

`_ChatMessage` est une petite classe privée avec `fromUser` et `text`.

### 8.2 Chargement

`_loadModel({bool withHistory = false})` :

1. passe `_loadingModel` à `true` et efface `_loadError` ;
2. construit l'historique (`ChatTurn`) si demandé ;
3. appelle `_engine.load(history: history)` ;
4. passe `_loadingModel` à `false` ou renseigne `_loadError`.

Pendant le chargement, l'écran affiche un spinner et « Chargement du modèle… ».

### 8.3 Envoi et streaming

`_send()` :

1. lit et trime le champ ;
2. refuse si vide, déjà en génération, en chargement ou en erreur ;
3. vide le champ, ajoute le message utilisateur, passe `_generating` à `true` ;
4. consomme `_engine.chat(text, enableThinking: _enableThinking)` ;
5. concatène les chunks dans `_streamingText` et fait défiler vers le bas ;
6. à la fin, ajoute le texte complet comme message assistant si non vide ;
7. en cas d'erreur, passe `_generating` à `false` et renseigne
   `_generationError`.

Le défilement est assuré par `_scrollToBottom()` via
`WidgetsBinding.instance.addPostFrameCallback`, avec une animation de 200 ms.

### 8.4 Arrêt, nouvelle conversation et réflexion

- **Arrêt** : `_stop()` passe `_stopRequested` à `true` et appelle
  `_engine.stop()`. Le bouton d'envoi devient un sablier désactivé. Le texte
  partiel est conservé s'il est non vide.
- **Nouvelle conversation** : `_newConversation()` appelle `stop()`, `reset()`,
  vide les messages et les erreurs. Le bouton est désactivé pendant une
  génération pour éviter une course avec le stream.
- **Réflexion** : le bouton `psychology` de l'AppBar bascule
  `_enableThinking`. Le mode est désactivé par défaut ; les chunks de réflexion ne
  sont pas affichés.

### 8.5 Bulles et rendu Markdown

`_MessageBubble` :

- aligne les messages utilisateur à droite et les messages assistant à gauche ;
- limite la largeur à 560 px ;
- utilise `primaryContainer` pour l'utilisateur et `surfaceContainerHigh` pour
  l'assistant ;
- affiche un spinner et « Le modèle réfléchit… » tant qu'aucun chunk n'est
  arrivé ;
- affiche « Arrêté. » si l'arrêt intervient avant tout texte ;
- rend les messages utilisateur avec `Text` (texte brut) ;
- rend les messages assistant avec `GptMarkdown` :

```dart
: isUser
    ? Text(text)
    : GptMarkdown(text, isStreaming: streaming),
```

Le drapeau `streaming` vaut `true` uniquement pour la bulle assistant en cours de
génération ; les messages terminés sont rendus immédiatement.

### 8.6 Écran vide, composeur, erreurs et à propos

- **`_EmptyChat`** : icône cadenas, « Posez une question à LFM3 » et rappel que
  tout reste sur l'appareil.
- **`_Composer`** : `SafeArea`, `TextField` de 1 à 4 lignes, action d'envoi,
  bouton `IconButton.filled` qui devient « Arrêter » pendant la génération.
- **`_ErrorBanner`** : bandeau `errorContainer` avec bouton de fermeture.
- **`_ErrorView`** : écran plein avec icône mémoire, message, « Réessayer » et
  « Supprimer et retélécharger ».
- **`_showAbout`** : `AlertDialog` rappelant que le modèle et les conversations
  restent sur l'appareil et qu'aucune requête n'est envoyée pendant le chat.

---

## 9. Rendu Markdown

Le modèle produit régulièrement du Markdown (`**gras**`, listes, blocs de code).
L'affichage initial en `Text` brut montrait les astérisques. `gpt_markdown` a donc
été ajouté :

```bash
flutter pub add gpt_markdown
```

Intégration dans `lib/chat_page.dart` :

```dart
import 'package:gpt_markdown/gpt_markdown.dart';
```

Puis dans `_MessageBubble` :

```dart
: isUser
    ? Text(text)
    : GptMarkdown(text, isStreaming: streaming),
```

Choix :

- **assistant** : Markdown rendu (gras, italique, listes, titres, tables, code,
  LaTeX) ;
- **utilisateur** : texte brut, pour ne pas interpréter accidentellement la saisie ;
- **streaming** : `isStreaming: true` pour la bulle active, `false` pour les
  messages terminés ;
- **largeur** : la bulle garde `maxWidth: 560`, `gpt_markdown` s'adapte au contenu ;
- **liens** : `onLinkTap` n'est pas branché, donc les liens ne sont pas ouverts ;
- **copie de code** : `onCodeCopy` n'est pas branché ; le package peut afficher
  ses contrôles par défaut.

`gpt_markdown` 1.4.0 apporte le rendu Markdown/LaTeX/code et des dépendances
transitives supplémentaires. Cela a un coût sur la taille du build, accepté pour
cette démonstration.

---

## 10. Builds et vérifications

### 10.1 Commandes

```bash
dart format lib bin test
flutter analyze
flutter test
flutter build apk --debug
flutter build linux --debug
```

### 10.2 Résultats

| Commande | Résultat |
|---|---|
| `dart format` | 8 fichiers formatés, aucun changement nécessaire |
| `flutter analyze` | `No issues found!` |
| `flutter test` | `All tests passed!` (1 test) |
| `flutter build apk --debug` | Succès, APK dans `build/app/outputs/flutter-apk/app-debug.apk` |
| `flutter build linux --debug` | Succès, binaire dans `build/linux/x64/debug/bundle/flutter_lfm3_lab` |

L'APK debug pèse environ **371 Mo** (artefact de debug, toutes les ressources et
symboles inclus). Un build release sera plus petit.

### 10.3 Test desktop de bout en bout

L'application Linux a été lancée avec le modèle local :

```bash
LFM3_MODEL_PATH=$PWD/models/LFM3-1.7B-Q4_K_M.gguf \
  build/linux/x64/debug/bundle/flutter_lfm3_lab
```

Observations :

- chargement du modèle en ~42 s sur le CPU de test ;
- RSS d'environ **1,5 à 1,7 Go** avec le modèle chargé ;
- première réponse cohérente en français ;
- deuxième tour : « et la capitale du togo » →
  « La capitale du Togo est **Lomé**. » ;
- l'historique multi-tours fonctionne ;
- l'intégration `gpt_markdown` est compilée et active : un message contenant du
  Markdown sera rendu par le package.

Le test a été piloté par saisie synthétique après focalisation explicite de la
fenêtre. Ce n'est pas une fonctionnalité de l'application, seulement une méthode de
vérification.

### 10.4 Android

L'APK debug compile et inclut :

- la permission `INTERNET` ;
- le label `LFM3 Lab` ;
- le runtime natif `llamadart` pour Android (arm64) ;
- le code Dart et les assets Flutter.

Il n'a pas encore été installé ni mesuré sur un appareil Android réel. Les temps de
chargement et la consommation RAM sur mobile restent à valider.

### 10.5 Linux

Le bundle Linux debug compile et fonctionne avec le patch baseline décrit en
section 4. Sans ce patch, le chargement échoue sur le i5-3210M de test. Sur un CPU
récent, le runtime fourni par `llamadart` doit fonctionner sans intervention.

---

## 11. Limites et points d'attention

### 11.1 Téléchargement

- Pas de reprise après interruption : le `.part` est supprimé au début de chaque
  tentative.
- Pas de vérification SHA256 : seule la taille exacte est contrôlée.
- Pas de contrôle d'espace disque avant le téléchargement.
- Pas de téléchargement en arrière-plan : l'application doit rester ouverte.
- Pas de file d'attente ni de retry automatique ; l'utilisateur peut relancer.

### 11.2 Modèle et inférence

- Un seul modèle est supporté (Q4_K_M) ; pas de sélection dans l'UI.
- Backend CPU uniquement (`gpuLayers: 0`) ; pas de Vulkan/Metal.
- Contexte limité à 4096 tokens ; les très longues conversations seront tronquées
  par `ChatSession`.
- `maxTokens` limité à 512 ; les réponses longues sont coupées.
- Les chunks de réflexion ne sont pas affichés.
- Aucun benchmark Android réel n'a été réalisé.

### 11.3 Données et UI

- L'historique de conversation est uniquement en mémoire : un redémarrage de
  l'application le perd.
- Les liens Markdown ne sont pas cliquables (`onLinkTap` non branché).
- La copie de code n'est pas personnalisée (`onCodeCopy` non branché).
- Le rendu Markdown ajoute des dépendances et du poids au build.
- Le test widget ne couvre que l'écran de téléchargement.

### 11.4 Desktop

- Le patch du cache pub est local, hors dépôt, et doit être réappliqué après un
  nettoyage du cache.
- Il n'est pas nécessaire sur Android ni sur un CPU avec AVX2.
- Les sauvegardes `/tmp` peuvent disparaître au redémarrage.

### 11.5 Plateformes

- Android est la cible principale ; iOS n'a pas été créé.
- Aucun build release signé n'a été produit.
- Le build Linux est un build debug de test.

---

## 12. Reproduire l'application

### 12.1 Prérequis

- Flutter 3.47.8 ou compatible, Dart 3.13.7 ;
- Android SDK 36 et Java 17 pour Android ;
- accès Internet au premier build (téléchargement du runtime natif `llamadart`) ;
- accès Internet au premier lancement pour télécharger le modèle.

### 12.2 Installation

```bash
git clone git@github.com:Just2sire/flutter_lfm3_lab.git
cd flutter_lfm3_lab
flutter pub get
```

### 12.3 Lancement Android

```bash
flutter run -d <appareil_android>
```

Au premier lancement, l'écran de téléchargement s'affiche. Appuyer sur
« Télécharger le modèle », attendre la fin, puis discuter.

### 12.4 Lancement desktop

```bash
flutter run -d linux
```

Pour éviter un nouveau téléchargement, pointer vers un modèle local :

```bash
LFM3_MODEL_PATH=$PWD/models/LFM3-1.7B-Q4_K_M.gguf flutter run -d linux
```

Récupération manuelle du modèle (optionnelle) :

```bash
mkdir -p models
hf download LiquidAI/LFM3-1.7B-GGUF \
  --include "*Q4_K_M.gguf" \
  --local-dir models
```

Vérification de la taille :

```bash
stat -c%s models/LFM3-1.7B-Q4_K_M.gguf
# 1099627808
```

### 12.5 Builds

```bash
flutter build apk --debug
flutter build linux --debug
```

Sur un CPU sans AVX2, appliquer le contournement de la section 4 avant de lancer
le build Linux.

---

## 13. Historique des commits

| Commit | Contenu |
|---|---|
| `e41594b` | Initialisation du projet Flutter |
| `be11511` | Implémentation de l'application de chat LFM3 locale |
| `8fba82b` | Rendu Markdown des réponses avec `gpt_markdown` |
| `57ff59c` | README et note sur le baseline desktop |

Le dépôt est sur `git@github.com:Just2sire/flutter_lfm3_lab.git`, branche
`master`. Les commits ont été poussés au fur et à mesure.

---

## 14. Références

- Plan de conception : `docs/lfm3-flutter-on-device-plan.md`
- Modèle : <https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF>
- `llamadart` : <https://pub.dev/packages/llamadart>
- `gpt_markdown` : <https://pub.dev/packages/gpt_markdown>
- `path_provider` : <https://pub.dev/packages/path_provider>
- `http` : <https://pub.dev/packages/http>
- llama.cpp v0.8.0 (commit baseline) :
  `8642541b255bfb5dc39cd351a178be09013a55d6`

---

## Annexe A — Correspondance API `llamadart`

| Besoin | API utilisée |
|---|---|
| Charger le modèle | `LlamaEngine.load(LlamaModel(ModelSource.parse(path)), params: LlamaCppModelParams(...))` |
| Nom du backend | `engine.getBackendName()` |
| Créer une session | `ChatSession(engine, maxContextTokens:, systemPrompt:)` |
| Ajouter un tour | `session.addMessage(LlamaChatMessage.fromText(role:, text:))` |
| Générer en streaming | `session.create([LlamaTextContent(text)], enableThinking:, params:)` |
| Lire le texte | `chunk.text` |
| Lire la réflexion | `chunk.thinking` (ignoré) |
| Arrêter | `engine.cancelGeneration()` |
| Réinitialiser | `session.reset()` |
| Libérer | `engine.dispose()` |
| Paramètres | `GenerationParams(maxTokens:, temp:, topK:, penalty:)` |

## Annexe B — Points d'entrée

| Fichier | Rôle |
|---|---|
| `lib/main.dart` | `runApp`, thème Material 3, `HomePage` |
| `lib/home_page.dart` | Gate modèle, téléchargement, navigation vers le chat |
| `lib/chat_page.dart` | Chat, streaming, Markdown, cycle de vie, erreurs |
| `lib/lfm3_engine.dart` | Façade `llamadart` |
| `lib/lfm3_model.dart` | Constantes, chemins, vérification, suppression |
| `lib/model_downloader.dart` | Téléchargement HTTP et vérification |
| `bin/lfm3_probe.dart` | Sonde CLI GO/NO-GO |
| `test/widget_test.dart` | Test de l'écran de téléchargement |

## Annexe C — Checklist d'implémentation et de validation

- [x] Le runtime charge LFM3 sur desktop.
- [x] Une réponse cohérente est générée.
- [x] Le modèle est présent et sa taille est vérifiée.
- [x] L'écran de téléchargement s'affiche sans modèle.
- [x] Le chat en streaming fonctionne.
- [x] L'historique multi-tours fonctionne.
- [x] L'arrêt de génération est disponible.
- [x] Le mode réflexion est optionnel.
- [x] Le rendu Markdown des réponses est actif.
- [x] Le modèle est déchargé en arrière-plan.
- [x] `flutter analyze` passe.
- [x] `flutter test` passe.
- [x] L'APK Android debug compile.
- [x] Le bundle Linux debug compile.
- [ ] Test du téléchargement in-app de bout en bout.
- [ ] Test sur un appareil Android réel.
- [ ] Mesures de performance Android.
- [ ] Build release signé.
- [ ] Téléchargement reprenable.
- [ ] Vérification SHA256 du modèle.
- [ ] Persistance de l'historique.
- [ ] iOS.

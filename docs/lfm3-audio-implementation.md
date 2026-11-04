# Plan et implémentation — LFM3 Audio (dictée, TTS, chat vocal)

> Document « as-built » de la phase audio du projet `flutter_lfm3_lab`.
> Rédigé le 4 novembre 2026. Il décrit le plan suivi, ce qui a réellement été
> implémenté, le diagnostic du blocage TTS, le correctif apporté au moteur, les
> résultats de validation et la procédure d'installation sur une autre machine.
>
> - Branche : `feat/lfm3-audio`
> - Commit poussé : `6717c58` (`feat: add LFM3 audio dictation, speech, and voice chat`)
> - Documents liés : `docs/lfm3-flutter-on-device-plan.md` (conception initiale),
>   `docs/lfm3-implementation.md` (chat texte as-built)

---

## 1. Objectif

Ajouter à l'application un second modèle, **LFM3-Audio-2B**, et trois usages :

1. **Dictée (ASR)** : enregistrer la voix, la transcrire localement et remplir le
   champ de saisie.
2. **Synthèse vocale (TTS)** : lire à voix haute une réponse de l'assistant.
3. **Chat vocal complet** : parler, obtenir une réponse texte, puis l'entendre,
   avec option de lecture automatique.

Contraintes conservées :

- tout reste **100 % local** (aucun serveur, aucune API distante) ;
- un seul téléchargement de modèle par famille ;
- Android est la cible, Linux sert de banc de test desktop ;
- aucune régression sur le chat texte existant.

---

## 2. Résultat obtenu

| Fonction | État | Détail |
|---|---|---|
| Catalogue 2 modèles | ✅ | `LFM3-1.7B · texte` et `LFM3-Audio-2B · voix` |
| Téléchargement multi-fichiers | ✅ | modèle + `mmproj`, reprise `.part`, progression agrégée |
| Dictée micro → texte | ✅ | WAV 16 kHz mono, transcription locale |
| Lecture d'une réponse | ✅ | bouton haut-parleur par message |
| Lecture automatique | ✅ | réglage persistant `autoSpeak` |
| Chat vocal complet | ✅ | micro → ASR → chat → TTS |
| Changement de modèle | ✅ | depuis le drawer, avec persistance |
| Android `RECORD_AUDIO` | ✅ | permission déclarée |
| TTS LFM3 | ✅ | activé via l'API native `_ext` (voir §6) |
| Build Linux debug | ✅ | validé |
| Build APK debug | ⚠️ | non terminé lors de la session |

Tailles et sources :

| Fichier | Taille | URL |
|---|---:|---|
| `LFM3-Audio-2B-Q4_K_M.gguf` | 1 099 626 016 o | `https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/main/LFM3-Audio-2B-Q4_K_M.gguf` |
| `mmproj-LFM3-Audio-2B-Q8_0.gguf` | 303 811 840 o | `https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/main/mmproj-LFM3-Audio-2B-Q8_0.gguf` |

Le même `mmproj` sert à l'ASR **et** au TTS.

---

## 3. Décisions d'architecture

### 3.1 Deux familles de modèles, un seul moteur

`Lfm3ModelSpec` décrit une famille (kind, label, description, fichiers). Le modèle
audio porte un `projector` optionnel ; sa présence active les fonctions audio.

```dart
enum Lfm3ModelKind { text, audio }

class Lfm3ModelSpec {
  final Lfm3ModelKind kind;
  final Lfm3ModelFile model;
  final Lfm3ModelFile? projector;
  bool get isAudio => projector != null;
}
```

Le moteur `Lfm3Engine` est commun. Il charge le `projector` seulement s'il existe :

```dart
LlamaModel(
  ModelSource.parse(model.path),
  projector: projector == null ? null : ModelSource.parse(projector.path),
)
```

### 3.2 ASR via `ChatSession` multimodal

Pas d'API ASR dédiée dans `llamadart` pour ce modèle : on réutilise le chat
multimodal avec le marqueur média `<__media__>`.

```dart
session.create(
  [
    const LlamaTextContent('<__media__>'),
    LlamaAudioContent(path: wavPath),
  ],
  enableThinking: false,
  params: const GenerationParams(
    maxTokens: 512,
    temp: 0,
    topK: 1,
    penalty: 1.0,
  ),
)
```

System prompt : `Perform ASR in French.`

### 3.3 TTS via le hook bas niveau du backend

Le moteur haut niveau (`TextToSpeechEngine` + `Qwen3TtsAdapter`) n'accepte que
Qwen3. On utilise donc directement :

```dart
engine.synthesizeTextToSpeechBackend(
  BackendTextToSpeechRequest(
    text: text,
    language: 'fr',
    maxFrames: 2048,
    temperature: 1.0,
    topK: 128,
    topP: 0.95,
  ),
)
```

puis `TextToSpeechResult(...).toWavBytes()`.

### 3.4 Lecture audio portable

`just_audio` couvre Android/iOS/macOS mais **pas Linux/Windows**. Pour éviter
d'ajouter GStreamer comme dépendance système (requise par `audioplayers_linux`),
une petite abstraction `SpeechPlayer` a été écrite :

- mobile : `just_audio` ;
- Linux : `paplay` ou `aplay` via `Process.start` ;
- Windows : `powershell` + `Media.SoundPlayer.PlaySync()`.

Elle expose `play(Uint8List wav)`, `stop()`, `onComplete` et nettoie les WAV
temporaires.

### 3.5 Persistance des réglages

`settings.json` (à côté de `conversations.json`) contient :

```json
{ "modelKind": "audio", "autoSpeak": true }
```

Écriture atomique via `.tmp` + `rename`.

---

## 4. Plan par phases

| Phase | Contenu | Statut |
|---|---|---|
| 0. Exploration | vérifier le support LFM3-Audio dans `llamadart`/llama.cpp | ✅ |
| 1. Catalogue | ajouter le modèle audio + `mmproj`, tailles, URLs, overrides | ✅ |
| 2. Téléchargement | gérer 1 ou 2 fichiers, reprise, progression | ✅ |
| 3. UI accueil | cartes des 2 modèles, téléchargement, choix persistant | ✅ |
| 4. ASR | enregistrement WAV, transcription, remplissage du composer | ✅ |
| 5. TTS | synthèse, lecture, bouton par message, arrêt | ✅ |
| 6. Chat vocal | enchaînement micro → ASR → chat → TTS + autoSpeak | ✅ |
| 7. Diagnostic TTS | comprendre l'échec « unsupported » | ✅ |
| 8. Correctif moteur | fork `llamadart` + API `_ext` LFM3 | ✅ |
| 9. Lecture desktop | abstraction `SpeechPlayer` sans GStreamer | ✅ |
| 10. Validation | probe, analyze, tests, build Linux | ✅ |
| 11. Build Android | APK debug | ⚠️ interrompu |

---

## 5. Implémentation détaillée

### 5.1 Catalogue et fichiers

**`lib/lfm3_model.dart`**

- `Lfm3ModelFile` : `fileName`, `sizeBytes`, `url`, `envOverride`.
- `Lfm3Model.text`, `Lfm3Model.audio`, `Lfm3Model.all`.
- `isReady` vérifie l'existence **et** la taille exacte ; un fichier de mauvaise
  taille est supprimé pour forcer un nouveau téléchargement.
- Overrides d'environnement :
  - `LFM3_MODEL_PATH`
  - `LFM3_AUDIO_MODEL_PATH`
  - `LFM3_AUDIO_PROJECTOR_PATH`
- `delete` supprime aussi les `.part`.

`text` et `audio` sont `static final` (et non `const`) car `Uri.parse` n'est pas
une expression constante.

### 5.2 Téléchargement

**`lib/model_downloader.dart`**

- télécharge les fichiers d'une `Lfm3ModelSpec` un par un ;
- écrit dans `<fichier>.part`, reprend via l'en-tête `Range` ;
- vérifie la taille finale ;
- agrège la progression des deux fichiers dans une seule valeur `0..1` ;
- signale le fichier courant.

### 5.3 Écran d'accueil

**`lib/home_page.dart`**

- charge `AppSettings` au démarrage ;
- choisit le modèle actif : celui des réglages s'il est prêt, sinon le premier
  modèle prêt ;
- si aucun modèle n'est prêt → `_DownloadView` avec les deux cartes ;
- si le modèle actif est prêt → `ChatPage` ;
- `_switchModel(kind)` sauvegarde le choix, décharge l'ancien moteur et recharge ;
- transmet `autoSpeak` et `onAutoSpeakChanged` au chat ;
- `readyCheck` et `settingsStore` sont injectables pour les tests.

### 5.4 Chat et fonctions vocales

**`lib/chat_page.dart`**

- **Drawer** : reçoit `modelKind` et `onSelectModel`, affiche les deux entrées
  avec un état sélectionné.
- **Barre d'application** : bouton `volume_up` / `volume_off` pour `autoSpeak`,
  visible seulement sur le modèle audio.
- **Composer** : bouton micro visible sur le modèle audio.
  - appui → démarre l'enregistrement ;
  - nouvel appui → arrête, transcrit, remplit le champ ;
  - chronomètre pendant l'enregistrement.
- **Enregistrement** :
  ```dart
  RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
  )
  ```
- **Transcription** : `_engine.transcribe(path, language: 'French')`, puis
  suppression du WAV temporaire.
- **Bannière vocale** `_VoiceBanner` : affiche `recording`, `transcribing` ou
  `synthesizing`, avec actions Annuler / Arrêter.
- **Lecture** :
  - bouton haut-parleur sur chaque message assistant ;
  - pendant la lecture, l'icône devient `stop_rounded` ;
  - un seul message lu à la fois ;
  - `autoSpeak` déclenche la lecture après la fin d'une réponse.
- **Arrêt global** : `_stop()` interrompt génération et lecture.
- **Erreurs** : `_friendlyError` traduit notamment
  `Projecteur audio introuvable` en message utilisateur.

### 5.5 Moteur audio

**`lib/lfm3_engine.dart`**

- `load()` charge modèle + projecteur et reconstruit l'historique.
- `transcribe()` : ASR multimodal (voir §3.2).
- `synthesize()` : TTS bas niveau (voir §3.3), retourne un WAV.
- `stopSpeech()` → `cancelTextToSpeechBackend()`.
- `isAudioCapable` → `spec.isAudio`.

Paramètres TTS retenus pour LFM3 : `temperature 1.0`, `topK 128`, `topP 0.95`,
`maxFrames 2048`. Sortie observée : **24 000 Hz, mono**.

### 5.6 Lecture audio

**`lib/speech_player.dart`**

- `SpeechPlayer()` :
  - construit un `AudioPlayer` `just_audio` uniquement sur Android/iOS/macOS ;
  - écoute `processingStateStream` et émet `onComplete` sur
    `ProcessingState.completed`.
- `play(wav)` écrit un WAV temporaire puis :
  - mobile → `setFilePath` + `play()` ;
  - Linux → `paplay` si présent, sinon `aplay` ;
  - Windows → PowerShell `Media.SoundPlayer`.
- `onComplete` est émis à la fin naturelle (stream mobile ou `exitCode` du
  process desktop).
- `stop()` tue le process / arrête le player et supprime le temporaire.
- `dispose()` libère le player, l'abonnement et le contrôleur.

### 5.7 Réglages

**`lib/app_settings.dart`**

- `AppSettings{modelKind, autoSpeak}` + `copyWith`, `toJson`, `fromJson`.
- `SettingsStore({directoryProvider})` : injectable pour les tests.
- `settings.json` écrit de façon atomique.

### 5.8 Android

**`android/app/src/main/AndroidManifest.xml`**

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

La permission runtime est demandée par `record` (`hasPermission()`), avec message
« Accès au micro refusé ».

### 5.9 Tests

**`test/widget_test.dart`**

- utilise `_MemorySettingsStore extends SettingsStore` pour éviter les I/O
  `path_provider` dans `pumpAndSettle` (fake async) ;
- vérifie la présence des deux modèles et des boutons de téléchargement.

**`test/conversation_test.dart`** : inchangé, 11 tests au total.

### 5.10 Outils de validation

**`bin/lfm3_audio_probe.dart`**

Charge le modèle audio, affiche :

- durée de chargement ;
- backend (`CPU`) ;
- `supportsAudio` ;
- capacités TTS (`supported`, `model`, `reason`) ;
- progression TTS ;
- nombre de frames, fréquence, canaux, WAV écrit ;
- transcription ASR du WAV généré.

Il accepte les chemins en arguments ou via les variables d'environnement.

---

## 6. Blocage TTS et correctif du moteur

### 6.1 Symptôme

Avec `llamadart 0.17.5` non modifié :

```text
Text-to-speech initialization is unsupported by the loaded native runtime or model.
ttsCapabilities: supported=false model=null
reason=The loaded projector does not expose supported audio generation.
```

Pourtant :

- le modèle et le `mmproj` se chargent ;
- `supportsAudio` vaut `true` ;
- l'ASR fonctionne ;
- le binaire `llama-tts` officiel de llama.cpp génère bien un WAV avec les mêmes
  fichiers ;
- le wrapper natif bundlé contient les symboles LFM3.

### 6.2 Diagnostic

Le service Dart `llama_cpp_service.dart` appelait l'API **legacy** :

```c
llama_dart_tts_get_info(mtmd, &info);
llama_dart_tts_init(ctx, mtmd, &status);
```

Cette API n'accepte que les types listés dans
`llama_dart_tts_legacy_model_types`, c'est-à-dire **Qwen3 uniquement**.

Le wrapper natif expose une API **étendue** prenant un masque de types acceptés :

```c
uint32_t llama_dart_tts_supported_model_types(void);
int32_t  llama_dart_tts_get_info_ext(mtmd_context*, uint32_t accepted, llama_dart_tts_info*);
llama_dart_tts* llama_dart_tts_init_ext(llama_context*, mtmd_context*, uint32_t accepted, int32_t* status);
```

Vérification FFI :

```text
llama_dart_tts_supported_model_types() == 14
```

soit les bits 1, 2 et 3 :

| Bit | Type |
|---:|---|
| 1 | `QWEN3` |
| 2 | `LFM3_AUDIO` |
| 3 | `SOPRANO` |

Le runtime bundlé **savait donc générer du LFM3**, mais le service Dart ne le lui
demandait jamais.

### 6.3 Correctif : fork local `third_party/llamadart`

Le package `llamadart 0.17.5` a été copié dans `third_party/llamadart`, puis
patché. Le projet l'utilise via :

```yaml
dependency_overrides:
  llamadart:
    path: third_party/llamadart
```

Patches appliqués :

1. **`lib/src/backends/backend.dart`** — ajout de la valeur d'enum :
   ```dart
   enum BackendTextToSpeechModel {
     qwen3Tts,
     lfm3Audio,
   }
   ```

2. **`lib/src/backends/llama_cpp/native_signatures.dart`** — typedefs FFI :
   - `_TtsGetInfoExtNative/Dart`
   - `_TtsInitExtNative/Dart`
   - `_TtsSupportedModelTypesNative/Dart`

3. **`lib/src/backends/llama_cpp/library_loading.dart`** — `_TtsApi` :
   - nouveaux champs `getInfoExt`, `initExt`, `supportedModelTypes` ;
   - lookups :
     - `llama_dart_tts_get_info_ext`
     - `llama_dart_tts_init_ext`
     - `llama_dart_tts_supported_model_types`

4. **`lib/src/backends/llama_cpp/llama_cpp_service.dart`** :
   - `textToSpeechCapabilities` appelle désormais
     `getInfoExt(mtmd, supportedModelTypes(), info)` ;
   - le rejet « Only Qwen3-TTS projectors… » est supprimé ;
   - mapping :
     ```dart
     LLAMA_DART_TTS_MODEL_TYPE_QWEN3      -> BackendTextToSpeechModel.qwen3Tts
     LLAMA_DART_TTS_MODEL_TYPE_LFM3_AUDIO -> BackendTextToSpeechModel.lfm3Audio
     ```
   - `_synthesizeTextToSpeech` appelle
     `initExt(ctx, mtmd, supportedModelTypes(), &status)`.

Le moteur haut niveau n'a pas été modifié : l'application continue d'utiliser le
hook bas niveau `synthesizeTextToSpeechBackend`.

### 6.4 Validation du correctif

Après patch, le probe affiche :

```text
loaded in 0:00:23.469809
backend: CPU
supportsAudio: true
ttsCapabilities: supported=true model=BackendTextToSpeechModel.lfm3Audio reason=null
tts: 46 frames, 24000 Hz, 1 ch, complete in 0:01:04.661794
tts wav: /tmp/opencode/lfm3-audio/tts.wav (176684 bytes)
asr in 0:00:22.580680: Bonjour, ceci est un test de la synthèse vocale l'FM3.
```

L'ASR a bien reconnu la phrase générée (l'acronyme « LFM3 » est parfois rendu
« l'FM3 »). Les durées sont celles d'un i5-3210M : elles seront meilleures sur un
CPU récent.

---

## 7. Runtime natif et CPU ancien

Le bundle natif officiel de `llamadart` (llama.cpp v0.8.0-1) exige
AVX2/FMA/BMI2. Sur le CPU de test (i5-3210M, sans ces instructions), le
chargement échoue.

Pour le test desktop uniquement :

1. compiler llama.cpp au commit `8642541b255bfb5dc39cd351a178be09013a55d6` avec :
   ```text
   GGML_NATIVE=OFF GGML_AVX=ON GGML_AVX2=OFF GGML_FMA=OFF GGML_F16C=ON
   GGML_AVX512=OFF GGML_BMI2=OFF GGML_OPENMP=ON GGML_BACKEND_DL=ON
   BUILD_SHARED_LIBS=ON
   ```
2. remplacer `libggml-cpu.so` dans le cache natif `linux-x64` ;
3. adapter le SHA de l'archive dans `native_release_pins.dart` **localement**.

**Important pour le commit :** le SHA du fichier `native_release_pins.dart` a été
remis à sa valeur officielle avant de pousser, afin qu'une machine neuve puisse
télécharger le bundle standard. Sur un CPU ancien, il faut donc réappliquer ce
hack localement (ou utiliser le cache déjà patché présent sur la machine de
développement).

Android (arm64) n'est pas concerné par ce hack.

---

## 8. Validation effectuée

| Commande | Résultat |
|---|---|
| `dart format lib test bin third_party/llamadart/lib/...` | OK |
| `flutter analyze` | « No issues found! » |
| `flutter test` | 11 tests, tous verts |
| `dart run bin/lfm3_audio_probe.dart` | ASR + TTS OK, WAV 24 kHz |
| `flutter build linux --debug` | OK |
| `flutter build apk --debug` | interrompu, non conclu |

Notes :

- `audioplayers` a d'abord été essayé, puis abandonné : `audioplayers_linux`
  exige `gstreamer-1.0` au moment de la configuration CMake. `SpeechPlayer`
  évite cette dépendance système.
- `just_audio` seul ne suffit pas sur desktop ; d'où le fallback `paplay`/`aplay`.

---

## 9. Installation sur une autre machine

```bash
git fetch origin
git checkout feat/lfm3-audio
git pull origin feat/lfm3-audio

flutter pub get
```

Puis :

```bash
# Linux
flutter run -d linux

# Windows
flutter run -d windows

# Android
flutter run -d <appareil>
```

Build Windows puis lancement :

```powershell
flutter build windows --debug
.\build\windows\x64\runner\Debug\flutter_lfm3_lab.exe
```

Au premier lancement, l'écran d'accueil propose les deux modèles. Choisir
`LFM3-Audio-2B · voix` télécharge :

- `LFM3-Audio-2B-Q4_K_M.gguf` (~1,1 Go) ;
- `mmproj-LFM3-Audio-2B-Q8_0.gguf` (~304 Mo).

Pour utiliser des fichiers déjà présents :

```bash
LFM3_AUDIO_MODEL_PATH=/chemin/LFM3-Audio-2B-Q4_K_M.gguf \
LFM3_AUDIO_PROJECTOR_PATH=/chemin/mmproj-LFM3-Audio-2B-Q8_0.gguf \
flutter run -d linux
```

Validation rapide en ligne de commande :

```bash
dart run bin/lfm3_audio_probe.dart \
  /chemin/LFM3-Audio-2B-Q4_K_M.gguf \
  /chemin/mmproj-LFM3-Audio-2B-Q8_0.gguf \
  "Bonjour, test de synthèse."
```

Prérequis Linux :

- `paplay` (PulseAudio) ou `aplay` (ALSA) pour la lecture TTS ;
- `record` gère le micro via les backends système disponibles.

Prérequis Windows :

- Windows 10/11 avec le SDK Flutter Windows activé ;
- PowerShell pour la lecture TTS (`Media.SoundPlayer`) ;
- micro accessible par le système pour l'ASR.

Sur un CPU sans AVX2/FMA/BMI2, appliquer le hack décrit au §7 avant de lancer
(variante `windows-x64` du bundle natif).

---

## 10. Limites connues

- **Voix TTS** : LFM3 accepte `female`/`male` côté natif, mais l'UI n'expose pas
  encore de sélection ; le défaut est `female`.
- **Pas de streaming TTS** : la synthèse complète est générée avant lecture.
- **TTS lent sur CPU ancien** : environ 1 minute pour une phrase courte sur
  i5-3210M.
- **ASR** : les acronymes peuvent être mal transcrits (« LFM3 » → « l'FM3 »).
- **Lecture desktop** : via un processus externe, donc pas de pause/seek/volume
  intégrés.
- **`TextToSpeechEngine` haut niveau** reste limité à Qwen3 ; l'app utilise le
  hook backend. Une évolution propre consisterait à ajouter un adaptateur LFM3
  dans le fork.
- **Fork `llamadart`** : il faudra reporter les patches lors d'une mise à jour
  upstream.
- **APK Android** : build non finalisé dans cette session.

---

## 11. Maintenance du fork `llamadart`

Pour mettre à jour `third_party/llamadart` :

1. copier la nouvelle version du package ;
2. réappliquer les 4 patches du §6.3 ;
3. conserver `dependency_overrides` dans `pubspec.yaml` ;
4. relancer :
   ```bash
   flutter pub get
   flutter analyze
   flutter test
   dart run bin/lfm3_audio_probe.dart
   ```
5. vérifier que `ttsCapabilities` retourne bien
   `model=BackendTextToSpeechModel.lfm3Audio`.

Si upstream ajoute un support natif de LFM3 (API `_ext` ou adaptateur dédié), le
fork pourra être supprimé.

---

## 12. Références

- Modèles : `https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF`
- Chat texte : `docs/lfm3-implementation.md`
- Conception initiale : `docs/lfm3-flutter-on-device-plan.md`
- Runtime : `llamadart` 0.17.5, llama.cpp v0.8.0-1
- Probe : `bin/lfm3_audio_probe.dart`
- Fork : `third_party/llamadart`

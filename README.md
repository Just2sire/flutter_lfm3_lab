# LFM3 Lab

Application Flutter de démonstration pour exécuter **LFM3-1.7B** (texte) et **LFM3-Audio-2B** (voix) entièrement sur l'appareil, sans serveur.

## Fonctionnalités

- Deux modèles au choix : `LFM3-1.7B · texte` (~1,1 Go) ou `LFM3-Audio-2B · voix` (~1,4 Go avec son projecteur).
- Téléchargement dans le stockage privé, avec reprise et progression.
- Chat local en streaming avec `llamadart` (llama.cpp v0.8.0).
- Rendu Markdown des réponses via `gpt_markdown`.
- Historique multi-tours, arrêt de génération, mode réflexion optionnel.
- Dictée vocale (ASR) et synthèse vocale (TTS) locales sur le modèle audio.
- Lecture automatique des réponses (option persistante) et changement de modèle depuis le drawer.
- Déchargement du modèle quand l'application passe en arrière-plan.

## Lancer

```bash
flutter pub get
flutter run -d linux     # Linux
flutter run -d windows   # Windows
flutter run -d <appareil> # Android
```

Le modèle est téléchargé au premier lancement. Pour utiliser des fichiers locaux :

```bash
# Modèle texte
LFM3_MODEL_PATH=$PWD/models/LFM3-1.7B-Q4_K_M.gguf flutter run -d linux

# Modèle audio (modèle + projecteur)
LFM3_AUDIO_MODEL_PATH=$PWD/models/LFM3-Audio-2B-Q4_K_M.gguf \
LFM3_AUDIO_PROJECTOR_PATH=$PWD/models/mmproj-LFM3-Audio-2B-Q8_0.gguf \
flutter run -d linux
```

Le TTS desktop utilise `paplay` ou `aplay`. L'ASR nécessite un microphone
accessible par le système.

## Vérifications

```bash
flutter analyze
flutter test
flutter build apk --debug
flutter build linux --debug
flutter build windows --debug
```

L'application Windows compilée se lance avec :

```powershell
.\build\windows\x64\runner\Debug\flutter_lfm3_lab.exe
```

## Note desktop (CPU ancien)

Le binaire `libggml-cpu.so` fourni par `llamadart` exige AVX2/FMA/BMI2. Sur un CPU qui ne les a pas (ex. i5-3210M), le chargement échoue avec « not supported on this system ». Pour le test desktop, un module baseline a été compilé depuis llama.cpp v0.8.0 (commit `8642541b255bfb5dc39cd351a178be09013a55d6`) avec `GGML_AVX2=OFF`, `GGML_FMA=OFF` et `GGML_BMI2=OFF`, puis injecté dans le cache natif `linux-x64`. Le SHA de `native_release_pins.dart` a été remis à sa valeur officielle dans le dépôt ; sur un CPU ancien, il faut réappliquer ce hack localement. Cette modification ne concerne pas Android (runtime arm64) et n'est pas nécessaire sur un CPU récent.

## Documentation

- [`docs/lfm3-flutter-on-device-plan.md`](docs/lfm3-flutter-on-device-plan.md) : conception initiale.
- [`docs/lfm3-implementation.md`](docs/lfm3-implementation.md) : chat texte as-built.
- [`docs/lfm3-audio-implementation.md`](docs/lfm3-audio-implementation.md) : plan et implémentation audio (ASR, TTS, fork `llamadart`).
- [`docs/lfm3-omni-implementation-plan.md`](docs/lfm3-omni-implementation-plan.md) : plan d'implémentation de LFM3-Omni-2B (vision, audio, voix).

## Vie privée

Le modèle et les conversations restent sur l'appareil. Aucune requête n'est envoyée pendant le chat.

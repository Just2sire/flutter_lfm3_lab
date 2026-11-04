# LFM3 Lab

Application Flutter de démonstration pour exécuter **LFM3-1.7B** (GGUF Q4_K_M) entièrement sur l'appareil, sans serveur.

## Fonctionnalités

- Téléchargement unique du modèle (~1,1 Go) dans le stockage privé.
- Chat local en streaming avec `llamadart` (llama.cpp v0.8.0).
- Rendu Markdown des réponses via `gpt_markdown`.
- Historique multi-tours, arrêt de génération, mode réflexion optionnel.
- Déchargement du modèle quand l'application passe en arrière-plan.

## Lancer

```bash
flutter pub get
flutter run -d linux   # ou -d <appareil Android>
```

Le modèle est téléchargé au premier lancement. Pour utiliser un fichier local :

```bash
LFM3_MODEL_PATH=$PWD/models/LFM3-1.7B-Q4_K_M.gguf flutter run -d linux
```

## Vérifications

```bash
flutter analyze
flutter test
flutter build apk --debug
flutter build linux --debug
```

## Note desktop (CPU ancien)

Le binaire `libggml-cpu.so` fourni par `llamadart` exige AVX2/FMA/BMI2. Sur un CPU qui ne les a pas (ex. i5-3210M), le chargement échoue avec « not supported on this system ». Pour le test desktop, un module baseline a été compilé depuis llama.cpp v0.8.0 (commit `8642541b255bfb5dc39cd351a178be09013a55d6`) avec `GGML_AVX2=OFF`, `GGML_FMA=OFF` et `GGML_BMI2=OFF`, puis injecté dans le cache pub de `llamadart` (archive `linux-x64` et SHA dans `native_release_pins.dart`). Cette modification locale ne concerne pas Android (runtime arm64) et n'est pas nécessaire sur un CPU récent.

## Vie privée

Le modèle et les conversations restent sur l'appareil. Aucune requête n'est envoyée pendant le chat.

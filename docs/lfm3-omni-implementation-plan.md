# Plan d'implémentation — LFM3-Omni-2B

> Plan de conception pour ajouter **LFM3-Omni-2B** à `flutter_lfm3_lab`, après
> les phases texte (`LFM3-1.7B`) et audio (`LFM3-Audio-2B`).
>
> - Date : 4 novembre 2026
> - Branche cible : `feat/lfm3-omni` (à créer depuis `feat/lfm3-audio`)
> - Documents liés : `docs/lfm3-implementation.md`,
>   `docs/lfm3-audio-implementation.md`
> - Ce document est un **plan** : il ne décrit pas encore de code livré.

---

## 1. Objectif

Faire tourner **LFM3-Omni-2B** localement dans l'application et exposer ses
capacités omni-modales :

1. **Entrées** : texte, image, audio (et vidéo par extraction d'images).
2. **Sorties** : texte, puis synthèse vocale 24 kHz.
3. **Chat multimodal** : question vocale sur une image, dictée, description
   d'image, lecture de la réponse.
4. **Un seul modèle** : remplacer la combinaison LLM + ASR + TTS + encodeur
   vision par un unique GGUF + un unique `mmproj`.

Contraintes conservées :

- 100 % local, aucun serveur ;
- Android prioritaire, Linux comme banc de test ;
- pas de régression sur les modèles texte et audio existants ;
- téléchargement explicite, pas de téléchargement silencieux.

---

## 2. Spécifications du modèle

| Propriété | Valeur |
|---|---|
| Paramètres | 2,17 B |
| Architecture | backbone LFM3, encodeur vision LFM3, encodeur audio causal LFM3, tokenizer audio LiquidCodec |
| Entrées | texte, images, vidéo (avec ou sans piste audio), audio 16 kHz |
| Sorties | texte, parole 24 kHz, ou texte + parole entrelacés |
| Contexte | 32 768 tokens (entrée + sortie) |
| Langues texte | 16 langues, dont français |
| Langues parole | 19 locales, dont français, voix féminine et masculine |
| Raisonnement | non (`enable_thinking` non supporté) |
| Licence | LFM Open License v1.0 |

### 2.1 Fichiers GGUF retenus

Le `mmproj` contient **l'encodeur vision, l'encodeur audio et le chemin de sortie
audio** (depthformer + codec). Il est donc obligatoire pour l'image, l'ASR et le
TTS.

| Fichier | Taille | Rôle |
|---|---:|---|
| `LFM3-Omni-2B-Q4_K_M.gguf` | ~1,1 Go | backbone + tête texte |
| `mmproj-LFM3-Omni-2B-Q4_K_M.gguf` | ~292 Mo | vision + audio + codec (quantifié) |
| `mmproj-LFM3-Omni-2B-Q8_0.gguf` | ~507 Mo | variante qualité |

**Choix par défaut** : `Q4_K_M` + `mmproj Q4_K_M` (~1,4 Go au total), cohérent
avec l'empreinte des modèles déjà intégrés. Variante Q8_0 du `mmproj` proposée en
option si la qualité audio/vision prime.

> Attention : le `mmproj` de LFM3-**Audio** faisait ~304 Mo ; celui d'**Omni** est
> plus gros car il embarque aussi l'encodeur vision.

### 2.2 Paramètres d'inférence

| Usage | Paramètres |
|---|---|
| Texte | greedy : `temp 0`, `topK 1`, `penalty 1.0` |
| ASR | `temp 0`, `topK 1`, prompt système `Perform ASR in French.` |
| Image | `temp 0`, question en texte, image en contenu multimodal |
| Parole | `audio_temperature 0.4`, `audio_repetition_penalty 1.2`, fenêtre 64 |
| Contexte app | 8 192 par défaut, jusqu'à 32 768 en option |

Le modèle est **non-reasoning** : le mode réflexion doit être masqué ou forcé à
`false` quand Omni est actif.

---

## 3. État de l'existant et écarts

| Brique | Aujourd'hui | Écart pour Omni |
|---|---|---|
| Catalogue | 2 specs (`text`, `audio`) | ajouter `omni` |
| `Lfm3Engine` | texte + ASR + TTS | ajouter entrée image, capacités vision |
| UI chat | texte + micro + TTS | ajouter pièce jointe image, rendu des médias |
| Persistance | messages texte | stocker les pièces jointes |
| Vidéo | non supportée | extraction de frames côté app |
| TTS | API `_ext` LFM3 | vérifier le type natif rapporté pour Omni |
| Interleaved | non | hors périmètre v1 |
| Realtime | non | hors périmètre v1 |

### 3.1 Limitation importante : vidéo

`llamadart` expose `LlamaVideoContent`, mais `LlamaEngine.supportsVideo` renvoie
**toujours `false`** : le pipeline Dart de décodage/échantillonnage vidéo n'est
pas implémenté. Une requête vidéo lève une erreur typée.

Conséquence pour le plan :

- **v1** : pas d'entrée vidéo native ;
- **v1.1** : extraire des images à ~2 fps (ffmpeg côté desktop,
  `video_thumbnail`/MediaMetadataRetriever côté mobile) et les envoyer comme
  `LlamaImageContent` ;
- la piste audio d'une vidéo peut être jointe séparément en `LlamaAudioContent`,
  mais **l'alignement temporel fin** n'est pas garanti par l'API publique ;
- **v2** : si `llamadart` expose un jour l'ingestion vidéo, basculer dessus.

### 3.2 Limitation : sortie entrelacée

Le hook `synthesizeTextToSpeechBackend` renvoie du PCM pour un texte donné. Il ne
permet pas de consommer un flux `texte + audio` entrelacé. Pour v1 :

- générer le texte avec `ChatSession` ;
- puis synthétiser ce texte avec le TTS ;
- ne pas exposer le mode `interleaved`.

Le mode `/v1/realtime` de `llama-server` (streaming audio bidirectionnel) est hors
périmètre : il suppose un serveur externe, alors que l'app charge le modèle
in-process.

---

## 4. Décisions d'architecture

### 4.1 Ajouter un troisième `kind`

```dart
enum Lfm3ModelKind { text, audio, omni }
```

`Lfm3Model.omni` porte un `model` et un `projector`. Les getters de capacité
doivent remplacer les tests basés sur `kind` dans l'UI :

```dart
class Lfm3ModelSpec {
  bool get hasProjector => projector != null;
  bool get supportsAudioInput => kind == Lfm3ModelKind.audio || isOmni;
  bool get supportsSpeechOutput => kind == Lfm3ModelKind.audio || isOmni;
  bool get supportsVisionInput => isOmni;
  bool get isOmni => kind == Lfm3ModelKind.omni;
}
```

Recommandation : introduire un `Set<Lfm3Capability>` (`audioIn`, `visionIn`,
`speechOut`, `text`) pour éviter que chaque nouvelle famille ne multiplie les
`if`.

### 4.2 Un seul moteur, des entrées multimodales

`Lfm3Engine.chat` accepte désormais une liste de `LlamaContentPart` au lieu d'un
simple `String` :

```dart
Stream<String> chatParts(
  List<LlamaContentPart> parts, {
  bool enableThinking = false,
  GenerationParams params = ...,
})
```

Les appels texte existants passent `[LlamaTextContent(message)]`. Les appels
image passent `[LlamaTextContent(prompt), LlamaImageContent(path: ...)]`. Le
moteur remplace automatiquement les médias par `<__media__>` dans le template.

### 4.3 Médias persistés

Les conversations ne stockent aujourd'hui que du texte. Pour Omni :

- copier chaque image/audio importé dans
  `getApplicationSupportDirectory()/media/<conversationId>/<messageId>.<ext>` ;
- stocker dans le message une référence (`path`, `mime`, `width`, `height`,
  `durationMs`) et non les octets ;
- afficher les vignettes dans la bulle utilisateur ;
- supprimer les médias avec la conversation ;
- limiter la taille (ex. 10 Mo par image) et compresser avant envoi si besoin.

### 4.4 Sortie vocale

Réutiliser `SpeechPlayer` et `Lfm3Engine.synthesize`. Ajouter dans le fork
`llamadart` (si nécessaire) le support de la voix (`female`/`male`) et, à terme,
de la répétition penalty audio. Le modèle Omni stocke déjà ses paramètres audio
dans le GGUF ; commencer par `temp 0.4`, `topK 128`, `topP 0.95`.

### 4.5 Contexte et mémoire

- 8 192 tokens par défaut pour Omni ;
- option 16 384 / 32 768 dans les réglages avancés ;
- avertir sur la RAM/VRAM nécessaire ;
- mesurer le pic mémoire sur Android avant d'activer 32K par défaut.

---

## 5. Phase 0 — GO/NO-GO runtime natif

**But** : vérifier que le runtime bundlé (`llama.cpp v0.8.0-1`) charge Omni et
expose vision + audio + TTS, avant d'écrire l'UI.

### 5.1 Téléchargement de test

```bash
mkdir -p /tmp/opencode/lfm3-omni
cd /tmp/opencode/lfm3-omni
curl -L -O https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF/resolve/main/LFM3-Omni-2B-Q4_K_M.gguf
curl -L -O https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF/resolve/main/mmproj-LFM3-Omni-2B-Q4_K_M.gguf
```

### 5.2 Script `bin/lfm3_omni_probe.dart`

À créer sur le modèle de `bin/lfm3_audio_probe.dart` :

1. charger modèle + `mmproj` ;
2. afficher backend, `supportsVision`, `supportsAudio`,
   `backendTextToSpeechCapabilities` ;
3. test ASR : synthétiser une phrase, puis la retranscrire ;
4. test image : décrire une image fournie en argument ;
5. test TTS : écrire un WAV 24 kHz ;
6. mesurer les temps de chargement, d'ASR, d'image et de TTS.

### 5.3 Critères GO

| Vérification | Attendu |
|---|---|
| Chargement | OK, backend CPU (ou GPU si dispo) |
| `supportsVision` | `true` |
| `supportsAudio` | `true` |
| Capacités TTS | `isSupported = true` |
| Type TTS natif | `LFM3_AUDIO` / famille LFM3 |
| ASR | transcription cohérente |
| Image | description cohérente |
| TTS | WAV 24 kHz non vide |

### 5.4 Si NO-GO

- Si le modèle ne charge pas : vérifier la version de llama.cpp (b11960+ / v0.8.0)
  et l'architecture `lfm3`.
- Si la vision n'est pas détectée : vérifier `clip.projector_type` et
  `supportsVision` dans le wrapper.
- Si le TTS est refusé : étendre le fork `llamadart` (type de modèle, masque
  `accepted_model_types`, mapping d'enum), comme cela a été fait pour
  LFM3-Audio.
- Si le codec audio du `mmproj` Q4_K_M pose problème : réessayer avec `Q8_0`.

**Porte** : ne pas commencer l'UI tant que la Phase 0 n'est pas GO.

---

## 6. Phase 1 — Catalogue, téléchargement, réglages

### 6.1 `lib/lfm3_model.dart`

Ajouter :

```dart
static final omni = Lfm3ModelSpec(
  kind: Lfm3ModelKind.omni,
  label: 'LFM3-Omni-2B · omni',
  description: 'Texte, images, audio et voix dans un seul modèle.',
  model: Lfm3ModelFile(
    fileName: 'LFM3-Omni-2B-Q4_K_M.gguf',
    sizeBytes: 1100000000, // à remplacer par la taille exacte du HEAD
    url: Uri.parse(
      'https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF/resolve/main/'
      'LFM3-Omni-2B-Q4_K_M.gguf',
    ),
    envOverride: 'LFM3_OMNI_MODEL_PATH',
  ),
  projector: Lfm3ModelFile(
    fileName: 'mmproj-LFM3-Omni-2B-Q4_K_M.gguf',
    sizeBytes: 292000000,
    url: Uri.parse(
      'https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF/resolve/main/'
      'mmproj-LFM3-Omni-2B-Q4_K_M.gguf',
    ),
    envOverride: 'LFM3_OMNI_PROJECTOR_PATH',
  ),
);
```

Mettre à jour `all`, `byKind`, et les tests de catalogue. Les tailles exactes
doivent être relevées via `curl -sI` (Content-Length) ou le HEAD Hugging Face,
comme pour les modèles existants.

### 6.2 `lib/model_downloader.dart`

Aucun changement structurel : la classe gère déjà 1 ou 2 fichiers. Vérifier
l'agrégation de progression et la reprise pour des fichiers de ~1,4 Go.

### 6.3 `lib/app_settings.dart`

`modelKind` accepte déjà une valeur d'enum : l'ajout de `omni` est rétrocompatible.
Ajouter si besoin :

```json
{
  "modelKind": "omni",
  "autoSpeak": true,
  "omniContextSize": 8192,
  "omniVisionQuality": "q4_k_m"
}
```

### 6.4 `lib/home_page.dart`

- ajouter la troisième carte de téléchargement ;
- afficher le poids total (~1,4 Go) et les capacités (vision, audio, voix) ;
- conserver la logique « modèle actif prêt → ChatPage ».

---

## 7. Phase 2 — Entrées multimodales

### 7.1 Dépendances

| Besoin | Package pressenti |
|---|---|
| Choisir une image | `file_picker` (desktop + mobile) |
| Prendre une photo | `image_picker` (mobile) |
| Vignettes vidéo (v1.1) | `video_thumbnail` ou équivalent |
| Extraction ffmpeg desktop (v1.1) | `ffmpeg` système via `Process` |

Ne pas ajouter de permission de stockage large : utiliser les sélecteurs
système. `RECORD_AUDIO` est déjà présent.

### 7.2 `Lfm3Engine`

```dart
Future<String> describeImage(String imagePath, {String prompt = 'Décris cette image.'}) async {
  final session = ChatSession(
    _engine!,
    maxContextTokens: contextSize,
    systemPrompt: 'Tu es un assistant concis. Réponds en français.',
  );
  final buffer = StringBuffer();
  await for (final chunk in session.create(
    [
      LlamaTextContent(prompt),
      LlamaImageContent(path: imagePath),
    ],
    enableThinking: false,
    params: const GenerationParams(maxTokens: 512, temp: 0, topK: 1, penalty: 1.0),
  )) {
    buffer.write(chunk.text);
  }
  return buffer.toString().trim();
}
```

Pour une question vocale sur image :

```dart
[
  LlamaAudioContent(path: questionWav),
  LlamaImageContent(path: imagePath),
  const LlamaTextContent('Réponds en texte.'),
]
```

### 7.3 UI chat

- bouton **pièce jointe** (image) dans le composer ;
- aperçu avant envoi, possibilité de retirer ;
- bulle utilisateur avec vignette + texte ;
- indicateur pendant l'analyse d'image ;
- bouton micro déjà présent : l'ASR reste identique ;
- si Omni est actif, le mode réflexion est masqué/forcé off.

### 7.4 Persistance

Étendre `ChatMessage` :

```dart
class ChatAttachment {
  final String path;
  final String mime;
  final int? width;
  final int? height;
  final int? durationMs;
}
```

Sérialisation JSON rétrocompatible (liste vide par défaut). Nettoyage des médias
à la suppression d'un message ou d'une conversation.

---

## 8. Phase 3 — Sortie texte et vocale

### 8.1 Texte

- paramètres greedy ;
- pas de mode réflexion ;
- streaming identique au chat actuel ;
- réponse affichée en Markdown.

### 8.2 TTS

Réutiliser :

```dart
engine.synthesizeTextToSpeechBackend(
  BackendTextToSpeechRequest(
    text: text,
    language: 'fr',
    maxFrames: 4096,
    temperature: 0.4,
    topK: 128,
    topP: 0.95,
  ),
);
```

Points à valider en Phase 0 :

- le `mmproj` Omni Q4_K_M contient-il bien le décodeur codec utilisable ?
- le wrapper rapporte-t-il `LFM3_AUDIO` ou un type dédié ?
- la voix par défaut est-elle correcte en français ?

### 8.3 Voix `female` / `male` (option v1.1)

Le CLI `llama-tts` accepte `--tts-voice female|male`. Le wrapper Dart actuel
n'expose pas ce champ dans `llama_dart_tts_request`. Deux options :

1. ajouter un champ `voice` dans le fork + l'API native (si le wrapper le
   supporte) ;
2. ajouter un paramètre `voice` à `BackendTextToSpeechRequest` et le transmettre.

À défaut, garder la voix par défaut et documenter la limitation.

### 8.4 Lecture

`SpeechPlayer` est déjà portable (mobile `just_audio`, desktop
`paplay`/`aplay`/PowerShell). Aucun changement majeur, sauf si la sortie TTS
Omni est plus longue : vérifier la gestion de l'annulation et du fichier
temporaire.

---

## 9. Phase 4 — Vidéo (optionnelle, v1.1)

### 9.1 Principe

Comme `LlamaVideoContent` est rejeté par `llamadart` :

1. extraire des frames à ~2 fps, max 4–384 frames ;
2. redimensionner selon les contraintes du modèle ;
3. envoyer les frames comme `LlamaImageContent` dans l'ordre ;
4. joindre éventuellement la piste audio en `LlamaAudioContent` ;
5. demander une réponse texte.

### 9.2 Outils

- **Desktop** : `ffmpeg` via `Process` (`ffmpeg -i video.mp4 -vf fps=2 frame_%04d.jpg`).
- **Android/iOS** : `video_thumbnail` ou `MediaMetadataRetriever` via un plugin ;
  éviter `ffmpeg_kit` (lourd) pour une première version.

### 9.3 Limites

- pas d'alignement temporel exact entre frames et audio ;
- coût mémoire/contexte élevé : 32K est vite saturé ;
- qualité inférieure à un vrai pipeline vidéo natif ;
- à documenter clairement dans l'UI.

---

## 10. Phase 5 — UI/UX et réglages

- Troisième carte modèle avec badges `vision`, `audio`, `voix`.
- Drawer : trois entrées, sélection persistante.
- Chat : pièce jointe, aperçu, vignettes, bannière d'analyse.
- Réglages avancés Omni :
  - taille de contexte (8K / 16K / 32K) ;
  - qualité `mmproj` (Q4_K_M / Q8_0) ;
  - voix TTS (si implémentée) ;
  - lecture automatique (déjà présent).
- Messages d'erreur dédiés :
  - `Projecteur audio introuvable` (existant) ;
  - `Encodeur vision indisponible` ;
  - `Contexte insuffisant pour cette image` ;
  - `Vidéo non prise en charge par le runtime`.
- Avertissement mémoire avant 32K.

---

## 11. Phase 6 — Tests et validation

### 11.1 Tests unitaires

- `Lfm3Model.omni` : chemins, tailles, `isReady`, `delete`.
- `AppSettings` : round-trip avec `modelKind = omni`.
- `ChatMessage` : round-trip avec pièces jointes, rétrocompatibilité.
- Nettoyage des médias.

### 11.2 Tests widget

- écran d'accueil : trois modèles affichés ;
- chat : bouton pièce jointe visible sur Omni, micro visible, mode réflexion
  masqué ;
- drawer : trois entrées.

### 11.3 Validation manuelle

| Scénario | Attendu |
|---|---|
| Charger Omni | pas d'erreur, backend affiché |
| Texte seul | réponse cohérente en français |
| Image + question | description correcte |
| Audio + question | ASR puis réponse |
| Audio + image | réponse conjointe (spoken visual QA) |
| TTS | WAV 24 kHz, lecture correcte |
| autoSpeak | lecture après réponse |
| Changement de modèle | déchargement/rechargement propre |
| Mémoire | pas de crash sur Android |

### 11.4 Commandes

```bash
dart format lib test bin
flutter analyze
flutter test
dart run bin/lfm3_omni_probe.dart
flutter build linux --debug
flutter build apk --debug
```

---

## 12. Fichiers à modifier / créer

| Fichier | Nature |
|---|---|
| `lib/lfm3_model.dart` | ajouter la spec `omni` et les capacités |
| `lib/model_downloader.dart` | vérifier le multi-fichiers |
| `lib/app_settings.dart` | contexte Omni, options |
| `lib/home_page.dart` | 3e carte, gating |
| `lib/lfm3_engine.dart` | `chatParts`, `describeImage`, entrée image |
| `lib/chat_page.dart` | pièce jointe, rendu médias, bannières |
| `lib/conversation.dart` | `ChatAttachment` |
| `lib/conversation_store.dart` | médias et nettoyage |
| `lib/conversation_drawer.dart` | 3e modèle |
| `lib/speech_player.dart` | inchangé (vérifier annulation) |
| `lib/media_store.dart` | **nouveau** : copie/compression/nettoyage |
| `bin/lfm3_omni_probe.dart` | **nouveau** : probe Phase 0 |
| `test/*` | catalogue, settings, attachments |
| `third_party/llamadart` | extension éventuelle TTS/voix/type Omni |
| `pubspec.yaml` | `file_picker`, `image_picker` (selon UI) |
| `android/app/src/main/AndroidManifest.xml` | rien de plus si sélecteurs système |

---

## 13. Risques et mitigations

| Risque | Impact | Mitigation |
|---|---|---|
| Runtime natif sans support Omni | bloquant | Phase 0 GO/NO-GO, fork si besoin |
| Type TTS natif non reconnu | TTS KO | étendre l'enum/le mapping du fork |
| Codec audio du `mmproj` Q4_K_M insuffisant | qualité voix | fallback `mmproj Q8_0` |
| Vision non détectée | image KO | vérifier `supportsVision`, projecteur |
| 32K contexte trop gourmand | OOM mobile | défaut 8K, option explicite |
| Vidéo non supportée par Dart | fonctionnalité absente | frames + audio, documenté |
| TTS lent sur CPU ancien | UX | lecture asynchrone, annulation |
| Médias volumineux | stockage | limite de taille, compression, nettoyage |
| Licence LFM Open v1.0 | usage commercial | seuil 10 M$ de revenus, à documenter |
| Fork `llamadart` à maintenir | dette | patches minimaux et documentés |

---

## 14. Critères d'acceptation

1. Le modèle Omni se télécharge et se charge depuis l'UI, sur Android et Linux.
2. Une question texte produit une réponse texte cohérente en français.
3. Une image + question produit une description/réponse pertinente.
4. Une question vocale est transcrite puis traitée.
5. Une réponse peut être lue en TTS 24 kHz, avec arrêt.
6. `autoSpeak` fonctionne sur Omni.
7. Le passage texte ↔ audio ↔ omni ne fuit pas et recharge correctement.
8. `flutter analyze`, `flutter test`, build Linux et build APK passent.
9. Les modèles texte et audio existants restent fonctionnels.
10. La documentation (`docs/`) décrit les limites vidéo et interleaved.

---

## 15. Estimation

| Phase | Charge |
|---|---:|
| 0. Probe native / GO-NO-GO | 0,5–1 j |
| 1. Catalogue, download, settings | 0,5 j |
| 2. Entrées image/audio + persistance | 1,5–2 j |
| 3. Texte + TTS + voix | 1 j |
| 4. UI/UX et erreurs | 1 j |
| 5. Vidéo par frames (option) | 2–3 j |
| 6. Tests, docs, builds | 1 j |
| **Total v1 (sans vidéo)** | **~5–6 j** |
| **Total v1.1 (avec vidéo)** | **~7–9 j** |

---

## 16. Hors périmètre v1

- Sortie texte + parole **entrelacée** en streaming.
- `/v1/realtime` (serveur externe, WebSocket bidirectionnel).
- Tool calling multimodal.
- Entrée vidéo native.
- Sélection de voix avancée / clonage de voix.
- Accélération GPU mobile dédiée.
- Fine-tuning.

---

## 17. Références

- Modèle : `https://huggingface.co/LiquidAI/LFM3-Omni-2B`
- GGUF : `https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF`
- Docs Liquid : `https://docs.liquid.ai/lfm/models/lfm3-omni-2b`
- Annonce LFM3 : `https://www.liquid.ai/blog/lfm3`
- llama.cpp : support LFM3-Omni à partir de b11960 (v0.8.0)
- Existant projet : `docs/lfm3-implementation.md`,
  `docs/lfm3-audio-implementation.md`

# Plan d'intégration de LFM3 on-device dans Flutter

> Rédigé le 3 novembre 2026. Basé sur le texte joint (proposition avec `llama_cpp_dart`), **vérifié** contre les pages pub.dev et Hugging Face.
> Rien n'a été compilé ici (pas de SDK Flutter dans mon environnement). Les points non confirmés sont marqués **[à confirmer]**.

---

## 1. Verdict

**Le texte joint ne fonctionnera pas tel quel.** Cause principale : `llama_cpp_dart 0.9.0-dev.12` embarque llama.cpp **b10182**, alors que LFM3 exige **b11960 ou plus récent** (page officielle du GGUF). Le modèle ne se chargera pas (`unknown model architecture: 'lfm3'`).

**Choix recommandé : `llamadart` (version 0.17.x)**. Sa dernière version annonce un moteur natif basé sur llama.cpp **v0.8.0**, soit la version minimale de LFM3. Il couvre Android, iOS et desktop, gère `ChatSession`, `cancelGeneration()` et les outils, et sait déjà traiter les templates de LFM2/LFM2.5. Il ne mentionne pas LFM3 explicitement : **la première étape est donc un test de chargement sur desktop**, avant d'écrire la moindre ligne de l'app.

| | |
|---|---|
| Moteur | `llamadart` ^0.17.x, **version figée** dans `pubspec.yaml` |
| Modèle | `LFM3-1.7B` GGUF **Q4_K_M** (1,10 Go), téléchargé au premier lancement |
| Seam | ta classe `Lfm3Engine` (mêmes membres que dans le texte joint), pour pouvoir changer de moteur sans toucher à l'UI |
| Plan B | Reconstruire `llama_cpp_dart` avec un llama.cpp récent, ou Cactus (quand LFM3 sera listé), ou le backend FastAPI de l'étude |

---

## 2. Corrections du texte joint

| Dans le texte joint | Réalité vérifiée | Action |
|---|---|---|
| `llama_cpp_dart: ^0.9.0-dev.12` | Embarque llama.cpp **b10182** ; LFM3 demande **≥ b11960** | Utiliser `llamadart`, ou reconstruire les binaires (plan B) |
| Code avec `LlamaParent`, `LlamaLoad`, `ChatMLFormat`, `sendPrompt` | C'est l'API de la branche 0.2.x. Le README de la 0.9 documente `LlamaEngine.spawn`, `createChat`, `Stream<GenerationEvent>` | Ne pas mélanger : le code ne correspond pas à la version indiquée |
| `format: ChatMLFormat()` alors que le texte recommande le template embarqué | Contradiction : LFM3 a son propre template (thinking, outils) | Laisser le moteur utiliser le template du GGUF |
| Fichier `LFM3-1.7B-Q4_0.gguf` | Le Q4_0 du dépôt est le checkpoint **QAD** : `LFM3-1.7B-QAD-Q4_0.gguf` (1,05 Go). Le Q4_K_M (1,10 Go) est la variante des exemples officiels | Q4_K_M par défaut ; QAD Q4_0 en variante de test |
| « Q4_0 meilleur point de départ mobile » (cité à pub.dev) | pub.dev ne dit rien de LFM3 ni de Q4_0 pour mobile ; citation sans support | Mesurer les deux (étape 5) |
| Température 0,7 / top-p 0,9 | Liquid AI recommande **0,1 / top_k 50 / pénalité 1,1** pour chat et outils | Appliquer ces valeurs |
| Historique multi-tours (`Map<String,String>`) | Non fonctionnel : `chat()` n'envoie que le dernier message | Utiliser `ChatSession` (historique géré) |
| Binaires natifs non mentionnés | `llama_cpp_dart` exige un AAR (Android) et un XCFramework manuel (iOS) | Avec `llamadart`, un hook de build télécharge le runtime au premier build |
| Contexte `nCtx: 4096` | **Bon réflexe** : LFM3 annonce 256K de contexte ; un contexte par défaut trop grand ferait exploser la RAM d'un téléphone | Toujours fixer le contexte explicitement (étape 3) |

---

## 3. Plan en sept étapes

| # | Étape | Sortie | Effort |
|---|---|---|---|
| 0 | **Porte GO/NO-GO : charger LFM3 sur desktop** | Réponse cohérente dans un script Dart | 1/2 h |
| 1 | Projet Flutter et plateformes | App qui compile sur appareil | 1 h |
| 2 | Téléchargement et stockage du modèle | Fichier vérifié dans le stockage privé | 2 h |
| 3 | `Lfm3Engine` (V1 sans streaming, puis V2 streaming) | Chat fonctionnel | 3 h |
| 4 | Interface de chat | Écran utilisable | 2 h |
| 5 | Mesures sur 3 appareils | Tableau de résultats, choix de quantification | 1/2 journée |
| 6 | Durcissement | Cycle de vie, mémoire, erreurs | 1 journée |

### Étape 0. Porte GO/NO-GO (desktop)

But : prouver que le runtime de `llamadart` charge LFM3, **sans téléphone ni UI**.

Prérequis : **Dart ≥ 3.10.7** et **Flutter ≥ 3.38** (`flutter --version`), un accès Internet au premier lancement (le hook de build télécharge le runtime natif).

```bash
mkdir lfm3_probe && cd lfm3_probe
dart create -t console .
dart pub add llamadart
hf download LiquidAI/LFM3-1.7B-GGUF --include "*Q4_K_M.gguf" --local-dir models
```

`bin/lfm3_probe.dart` (reprend l'exemple officiel du README) :

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> args) async {
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.parse(args.first)),
  );

  try {
    final reply = await engine
        .create(
          const [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'Capitale du Togo ? Réponds en un mot.',
            ),
          ],
          params: const GenerationParams(maxTokens: 32),
        )
        .text();
    print(reply);
  } finally {
    await engine.dispose();
  }
}
```

```bash
dart run bin/lfm3_probe.dart models/LFM3-1.7B-Q4_K_M.gguf
```

Le nom exact du fichier est celui qui apparaît dans `models/`. Le README montre aussi un chargement direct depuis Hugging Face (`hf://org/dépôt/fichier.gguf`).

**Porte** :

| Résultat | Suite |
|---|---|
| ✅ Une réponse cohérente s'affiche | **GO**, étape 1 |
| ❌ `unknown model architecture: 'lfm3'` | Runtime trop ancien : prendre la dernière version de `llamadart` et vérifier dans son changelog que le « runtime baseline » est **llama.cpp v0.8.0 ou plus** |
| ❌ Chemin local refusé par `ModelSource.parse` | Consulter la page « Finding models » de la documentation (elle couvre les chemins locaux) |
| ❌ Échec persistant | **Plan B** (section 4) |

### Étape 1. Projet Flutter et plateformes

```bash
flutter create lfm3_app
cd lfm3_app
flutter pub add llamadart path_provider http
```

Dans `pubspec.yaml`, **fige** la version (le package évolue vite : une version a déjà introduit un changement d'ABI) :

```yaml
dependencies:
  llamadart: 0.17.5
```

| Plateforme | Réglages |
|---|---|
| **Android** | Appareil **arm64-v8a** (CPU). Le Vulkan est expérimental : ne pas l'activer au départ. Niveau d'API minimal non précisé par le package **[à confirmer dans la page « Installation »]** ; si la compilation échoue, relever `minSdk` |
| **iOS** | Cible de déploiement **16.4 minimum**. Metal sur appareil, CPU sur simulateur : **tester sur un vrai iPhone**. Si le modèle approche la limite mémoire, ajouter l'entitlement *Increased Memory Limit* |
| **Build** | Le premier build télécharge le runtime natif : prévoir un accès réseau (CI comprise) |

Lis aussi les pages **« Installation »**, **« Apple setup »** et **« Generation and streaming »** de la documentation `llamadart` : elles contiennent les noms exacts des paramètres que ce plan ne peut pas confirmer.

### Étape 2. Téléchargement et stockage du modèle

Le modèle (≈ 1,1 Go) ne va **jamais** dans `assets/` : il est téléchargé au premier lancement, dans le stockage privé, en **Wi-Fi de préférence**.

```dart
import 'dart:io';

import 'package:http/http.dart' as http;

// Téléchargement du modèle avec fichier temporaire
class ModelDownloader {
  Future<void> download({
    required Uri url,
    required File destination,
    required void Function(double progress) onProgress,
  }) async {
    await destination.parent.create(recursive: true);
    final part = File('${destination.path}.part');
    final client = http.Client();

    try {
      final response = await client.send(http.Request('GET', url));
      if (response.statusCode != 200) {
        throw HttpException('Téléchargement refusé (${response.statusCode})');
      }

      final total = response.contentLength ?? 0;
      final sink = part.openWrite();
      var received = 0;

      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress(received / total);
      }
      await sink.close();

      if (total > 0 && await part.length() != total) {
        throw const HttpException('Fichier incomplet');
      }
      await part.rename(destination.path);
    } finally {
      client.close();
    }
  }
}
```

URL du fichier : `https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/<nom-du-fichier>.gguf` (nom à copier depuis la page du dépôt).

Règles : écrire dans un `.part` puis renommer (un fichier partiel n'est jamais pris pour un modèle valide), vérifier la taille, contrôler l'espace disque avant de commencer, afficher la taille et la progression à l'utilisateur. Pour la reprise après coupure, passer à `background_downloader`.

### Étape 3. `Lfm3Engine`

On garde **tes noms** (`resolveModelPath`, `load`, `chat`, `dispose`) : l'UI du texte joint reste inchangée.

**V1 : réponse complète, avec les seuls appels confirmés** (`LlamaEngine.load`, `ChatSession`, `send`, `dispose`, issus du README) :

```dart
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

// Moteur LFM3 local basé sur llamadart
class Lfm3Engine {
  static const modelFile = 'LFM3-1.7B-Q4_K_M.gguf';

  LlamaEngine? _engine;
  ChatSession? _session;

  Future<String> resolveModelPath() async {
    final dir = await getApplicationSupportDirectory();
    final model = File('${dir.path}/models/$modelFile');

    if (!await model.exists()) {
      throw StateError('Modèle introuvable : ${model.path}');
    }

    return model.path;
  }

  Future<void> load() async {
    if (_engine != null) return;

    final path = await resolveModelPath();
    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.parse(path)),
    );

    _engine = engine;
    _session = ChatSession(
      engine,
      systemPrompt: 'Tu es un assistant concis. Réponds en français.',
    );
  }

  Stream<String> chat(String userMessage) async* {
    final session = _session;
    if (session == null) {
      throw StateError('Le modèle n’est pas chargé.');
    }

    yield await session.send(userMessage);
  }

  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
    _session = null;
  }
}
```

La V1 renvoie la réponse **en un bloc** (un seul élément dans le `Stream`) : l'UI du texte joint fonctionne telle quelle, et tu valides tout le reste (chargement, historique, mémoire) avant de t'occuper du streaming.

**À confirmer dans la documentation de l'API avant la V2** (le README ne les montre pas) :

| À confirmer | Pourquoi |
|---|---|
| **Taille du contexte** : où la fixer, et sa valeur **par défaut** | Visée : **4096**. Le contexte annoncé du modèle est de 256K : si le défaut en dépend, la RAM explose |
| Nombre de threads et couches GPU | Android : CPU, 3 à 4 threads (laisser des cœurs à l'UI) ; iOS : tester Metal contre CPU |
| Champs de `GenerationParams` | Appliquer **température 0,1 · top_k 50 · pénalité de répétition 1,1 · maxTokens 512** |
| Méthode de **streaming** de `ChatSession` ou de `engine.create(...)` (type du flux, champ du texte) | Remplacer `yield await session.send(...)` par une boucle `await for` |
| `cancelGeneration()` : sur quel objet | Bouton stop |
| Option pour couper le **thinking** | Le raisonnement est actif par défaut dans LFM3 : coût en tokens et en temps sur mobile ; à mesurer actif et coupé |

**V2** : même classe, `chat()` produit les fragments au fil de l'eau, et un nouveau membre `Future<void> stop()` appelle `cancelGeneration()`. Les autres membres ne changent pas.

### Étape 4. Interface de chat

Reprends l'écran du texte joint (`ChatPage`) : il consomme déjà un `Stream<String>`. Cinq retouches :

1. `if (!mounted) return;` avant chaque `setState` placé après un `await`.
2. Un **état « modèle absent »** qui ouvre l'écran de téléchargement (étape 2), au lieu d'afficher une erreur brute.
3. Un indicateur « le modèle réfléchit… » tant qu'aucun texte n'est arrivé (la première réponse est plus lente).
4. Un **bouton stop** (actif avec la V2).
5. Un message clair si l'appareil manque de mémoire (voir étape 6).

### Étape 5. Mesures sur appareils

Trois appareils minimum : un récent, un milieu de gamme (4 Go de RAM), un d'entrée de gamme. Même fichier, même prompt, build **release**.

| Mesure | Comment |
|---|---|
| Chargement à froid | Temps entre `load()` et la fin de l'initialisation |
| Temps jusqu'au premier token | Prompts de 100 et de 1 000 tokens |
| Débit de génération | 128 tokens, moyenne de 3 essais |
| Mémoire | Pic de RAM (Android Studio Profiler, Xcode Instruments) |
| Thermique et batterie | 10 minutes de requêtes enchaînées, % de batterie, baisse de débit |

**Variantes à comparer** : Q4_K_M, Q4_0 QAD, et le thinking actif ou coupé. Retiens celle qui tient les seuils avec la meilleure qualité.

**Seuils de départ (hypothèses)** : premier token < 3 s ; ≥ 8 tok/s ; pic de RAM < 60 % de la RAM de l'appareil ; baisse de débit < 30 % après 10 minutes. Repère publié (chiffres du constructeur, iPhone 17 Pro, contexte 32K) : environ 43,6 tok/s en génération, et 1,90 Go de mémoire totale. **Aucune mesure publiée pour Android milieu ou bas de gamme** : tes mesures font foi.

**Règle de repli** : si un appareil ne tient pas les seuils, il utilise un modèle plus petit (LFM2.5-350M ou 1.2B) ou le backend (étude FastAPI), selon un profil d'appareil (RAM détectée).

### Étape 6. Durcissement

| Sujet | Action |
|---|---|
| **Arrière-plan** | Décharger le modèle (`dispose()`) quand l'app est masquée, le recharger au retour (`AppLifecycleListener`). Un modèle d'un Go en arrière-plan est un candidat idéal pour être tué par l'OS |
| **Mémoire** | Contexte fixé (4096), un seul moteur chargé, `maxTokens` plafonné |
| **Erreurs** | Chargement impossible (mémoire, fichier corrompu) : message clair, suppression du fichier suspect, proposition de retélécharger |
| **Thermique** | Limiter la longueur des réponses, pas de génération en boucle |
| **Historique** | Borner le nombre de tours conservés (le contexte est de 4096 tokens) |
| **Thinking** | Ne pas réinjecter le raisonnement des tours passés dans l'historique |
| **Confidentialité** | Tout reste sur l'appareil : le dire dans l'app |
| **Licence** | LFM Open License v1.0 : usage commercial gratuit sous un seuil de revenu annuel selon les analyses de lancement. Lire le texte avant publication **[à confirmer]** |

---

## 4. Plan B si l'étape 0 échoue

| Option | Quand | Coût |
|---|---|---|
| **A. Reconstruire `llama_cpp_dart` avec un llama.cpp récent** | `llamadart` ne charge pas LFM3 | Élevé : mettre à jour le sous-module `src/llama.cpp` à une version ≥ v0.8.0, relancer ses scripts (`build_android_aar.sh`, `build_apple_xcframework.sh`), puis ses *probes*. **Risque** : l'interface C de llama.cpp a pu changer depuis b10182, ce qui obligerait à régénérer les liaisons FFI |
| **B. Cactus** | Quand LFM3 apparaîtra dans ses modèles supportés | Moyen : sa documentation ne cite que LFM2, LFM2.5 et leurs variantes VL ; son API Flutter est composée de fonctions de haut niveau, avec un format de modèle propre |
| **C. Backend FastAPI** | Toujours utile comme secours | Voir `lfm3-fastapi-backend-study.md` : même modèle servi par `llama-server`, l'app l'appelle en HTTP |
| **D. Valider avec LFM2.5-1.2B** | Pour continuer à avancer sur l'UI pendant que LFM3 est bloqué | Faible : le moteur supporte déjà LFM2.5 ; seul le nom du fichier change dans `Lfm3Engine` |

L'option D n'est pas un échec : `Lfm3Engine` isole le modèle du reste de l'app, tu peux donc développer l'UI et les mesures avec LFM2.5, puis basculer sur LFM3 en changeant une constante.

---

## 5. Critères de fin

| # | Critère |
|---|---|
| ☐ | Étape 0 : LFM3 répond dans le script desktop |
| ☐ | L'app télécharge le modèle, vérifie sa taille et le charge sur un vrai appareil |
| ☐ | Conversation multi-tours cohérente (l'historique fonctionne) |
| ☐ | Contexte fixé explicitement, pic de RAM mesuré sur 3 appareils |
| ☐ | Streaming et bouton stop (V2) |
| ☐ | Déchargement du modèle en arrière-plan, rechargement au retour |
| ☐ | Seuils de la section 5 atteints, ou repli documenté par profil d'appareil |
| ☐ | Version de `llamadart` figée, licence du modèle relue |

---

## 6. Sources et limites

**Sources**

- [Page pub.dev de `llama_cpp_dart`](https://pub.dev/documentation/llama_cpp_dart/0.9.0-dev.6/) : README de la 0.9 (API `LlamaEngine`, binaires, sous-module llama.cpp épinglé à b10182).
- [Page pub.dev de `llamadart`](https://pub.dev/packages/llamadart) et son [changelog](https://pub.dev/packages/llamadart/changelog) : runtime natif llama.cpp v0.8.0, plateformes, `ChatSession`, `cancelGeneration()`, gestion des templates LFM2/LFM2.5.
- [LFM3-1.7B-GGUF (Hugging Face)](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF) : tailles des quantifications, build minimal b11960 (v0.8.0), réglages d'échantillonnage.
- [Documentation Cactus pour Flutter](https://docs.cactuscompute.com/v1.12/flutter) : modèles cités (LFM3 absent).
- [Guide matériel LFM3 local](https://runaihome.com/blog/lfm3-local-ai-hardware-guide-2026/) : chiffres iPhone 17 Pro (constructeur).

**Limites**

- **Aucun code n'a été compilé ni exécuté.** Les seuls appels `llamadart` utilisés viennent de son README (`LlamaEngine.load`, `create(...).text()`, `ChatSession`, `send`, `dispose`).
- Je n'ai pas pu lire la référence de l'API de `llamadart` : le streaming, la taille du contexte, les paramètres de génération, `cancelGeneration()` et l'option thinking sont à lire dans sa documentation (étape 3).
- La correspondance « llama.cpp v0.8.0 = build b11960 » vient de la page officielle du GGUF : le test de l'étape 0 est la seule preuve qui compte.
- Les seuils de performance sont des hypothèses.

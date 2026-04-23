# GarminSensorCapture — Android Companion App

Application Android compagnon qui reçoit les données de capteurs depuis la Garmin fēnix 8 Pro via le Connect IQ Mobile SDK, les stocke en JSONL, et permet leur export.

## Prérequis

- **Android Studio** : Hedgehog 2023.1 ou supérieur
- **Android SDK** : API 34 (compileSdk), API 26 minimum (minSdk)
- **Kotlin** : 1.9.0 (inclus dans Android Studio)
- **Connect IQ Mobile SDK** : intégré via Maven Central (téléchargement automatique par Gradle, aucune action manuelle)
- **Garmin Connect** installé sur le téléphone Android
- Device Android physique avec Bluetooth (émulateur possible pour tests UI)

## Connect IQ Mobile SDK

Le SDK est déclaré comme dépendance Maven Central dans `app/build.gradle` :

```gradle
implementation("com.garmin.connectiq:ciq-companion-app-sdk:2.4.0@aar")
```

**Aucune action manuelle requise.** Gradle télécharge automatiquement le SDK lors du premier build (`./gradlew assembleDebug` ou sync Android Studio). `mavenCentral()` est déclaré dans le `build.gradle` racine.

## Structure du projet

```
02_android_companion/
├── build.gradle                              ← Racine projet
├── app/
│   ├── build.gradle                          ← Module app (deps, SDK versions)
│   ├── src/main/
│   │   ├── AndroidManifest.xml               ← Permissions, activités
│   │   ├── java/com/garmin/sensorcapture/
│   │   │   ├── MainActivity.kt               ← UI principale
│   │   │   ├── MainViewModel.kt              ← Logique UI (StateFlow)
│   │   │   ├── ConnectIQManager.kt           ← SDK singleton
│   │   │   ├── SessionManager.kt             ← Cycle de vie session
│   │   │   ├── GarminReceiver.kt             ← Réception paquets CIQ
│   │   │   ├── FileLogger.kt                 ← Écriture JSONL
│   │   │   ├── ExportManager.kt              ← Export/partage fichiers
│   │   │   └── models/
│   │   │       └── GarminPacket.kt           ← Data classes
│   │   └── res/
│   │       ├── layout/activity_main.xml      ← Layout UI
│   │       └── values/strings.xml            ← Chaînes de caractères
├── sample_output/
│   └── sample_session.jsonl                  ← Exemple de sortie
└── README.md
```

## Build

### Via Android Studio
1. `File → Open → 02_android_companion`
2. Attendre la synchronisation Gradle
3. `Run → Run 'app'` (sélectionner votre device Android)

### Via ligne de commande
```bash
cd D:/CLAUDE_PROJECTS/GARMIN/02_android_companion

# Build debug
./gradlew assembleDebug

# Installer sur device connecté
./gradlew installDebug

# Build release
./gradlew assembleRelease
```

## Permissions requises

Accordées automatiquement au premier lancement (Android 12+) :
- `BLUETOOTH_SCAN` : scan des appareils BLE
- `BLUETOOTH_CONNECT` : connexion au device Garmin

Accordées automatiquement (Android < 10) :
- `WRITE_EXTERNAL_STORAGE` : écriture des fichiers JSONL

**Important** : Désactiver l'optimisation batterie pour Garmin Connect ET SensorCapture pour éviter les coupures BLE en arrière-plan.

## Test sur device

### Prérequis
1. Garmin Connect installé et connecté à un compte Garmin
2. fēnix 8 Pro appairée via Bluetooth dans Garmin Connect
3. Watch app SensorCapture installée sur la montre

### Étapes de test
1. Installer l'APK sur Android
2. Vérifier SDK Status = "READY" (peut prendre 15-30s)
3. Vérifier Watch Status = "CONNECTED"
4. Sur la montre : ouvrir SensorCapture → presser START
5. Vérifier que "Packets" s'incrémente sur Android
6. Laisser tourner 30-60s
7. Presser STOP sur la montre
8. Utiliser "Export JSONL" pour récupérer les données

### Logs de debug
Filtrer Logcat avec les tags suivants :
```
ConnectIQManager | GarminReceiver | FileLogger | MainActivity | SessionManager
```

## Sortie attendue

Fichier JSONL dans :
`/data/data/com.garmin.sensorcapture/files/sessions/<sessionId>.jsonl`

Format d'une ligne :
```json
{
  "received_at": "2024-04-22T14:30:22.543Z",
  "session_id": "20240422_143022",
  "pv": 1,
  "sid": "20240422_143022",
  "pi": 0,
  "dtr": 1713794022000,
  "s": [...],
  "gps": {...},
  "meta": {"bat": 85, "temp": 22.5},
  "ef": 0
}
```

Voir `sample_output/sample_session.jsonl` pour un exemple complet.

## Throughput attendu

En conditions normales (BLE stable, < 5m) :
- 1 paquet/seconde = ~25 samples/seconde d'IMU
- Taille fichier : ~3-5 KB/seconde
- Session de 10 minutes : ~3-5 MB

## Dépannage

Voir `04_docs/06_troubleshooting.md` sections 2 et 3.

## Notes de compatibilité

- Android 8.0+ (API 26) requis (H-010 dans `04_docs/04_hypotheses.md`)
- La communication passe via Garmin Connect app (relai obligatoire)
- Le Connect IQ Mobile SDK requiert Garmin Connect 4.0+ sur Android

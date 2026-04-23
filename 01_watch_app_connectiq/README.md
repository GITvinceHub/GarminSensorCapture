# GarminSensorCapture — Watch App (Connect IQ)

Application Connect IQ pour Garmin fēnix 8 Pro qui capture les données IMU (accéléromètre, gyroscope, magnétomètre), GPS et cardiaque, et les transmet via BLE à l'application Android compagnon.

## Prérequis

- **Garmin Connect IQ SDK** : version 6.x ou supérieure
  - https://developer.garmin.com/connect-iq/sdk/
- **Java JDK 11+** (requis par le compilateur Monkey C)
- **VS Code** avec l'extension Monkey C (recommandé)
- **Profil device** `fenix8pro` installé dans le SDK Manager
- **Clé développeur** (`.der`) pour signer l'application

## Structure des fichiers

```
01_watch_app_connectiq/
├── manifest.xml                    ← Déclaration app, devices, permissions
├── source/
│   ├── GarminSensorApp.mc          ← Entry point Application.AppBase
│   ├── MainView.mc                 ← Interface utilisateur (écran montre)
│   ├── MainDelegate.mc             ← Gestion boutons (START/STOP/long press)
│   ├── SessionManager.mc           ← Orchestrateur de session
│   ├── SensorManager.mc            ← Lecture IMU (accel/gyro/mag/HR)
│   ├── PositionManager.mc          ← GPS via Toybox.Position
│   ├── PacketSerializer.mc         ← Sérialisation JSON compact v1
│   ├── CommunicationManager.mc     ← Canal BLE vers Android
│   └── BatchManager.mc             ← Accumulation et envoi par lots
├── resources/
│   ├── strings/strings.xml         ← Chaînes localisées (EN/FR)
│   ├── layouts/layout.xml          ← Layout XML de la vue principale
│   └── properties/properties.xml  ← Propriétés configurables
├── docs/
│   └── limits_journal.md           ← Journal des limites Connect IQ
└── README.md                       ← Ce fichier
```

## Installation du SDK

### Linux/macOS
```bash
wget https://developer.garmin.com/downloads/connect-iq/sdks/connectiq-sdk-lin-X.Y.Z.zip
unzip connectiq-sdk-lin-X.Y.Z.zip -d ~/connectiq-sdk
export CIQ_SDK_HOME=~/connectiq-sdk
export PATH=$PATH:$CIQ_SDK_HOME/bin
```

### Windows
1. Télécharger `connectiq-sdk-win-X.Y.Z.zip` depuis developer.garmin.com
2. Dézipper dans `C:\Garmin\ConnectIQ`
3. Ajouter `C:\Garmin\ConnectIQ\bin` au PATH système

### Installer le profil device
```bash
sdkmanager install fenix8pro
```

## Build

### 1. Créer le fichier monkey.jungle
Créer `monkey.jungle` à la racine du projet :
```
project.manifest = manifest.xml
base.sourcePath = source
base.resourcePath = resources
```

### 2. Générer une clé développeur
```bash
openssl genrsa -out developer_key.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
```

### 3. Compiler (mode debug)
```bash
monkeyc \
  -o bin/GarminSensorCapture_debug.prg \
  -f monkey.jungle \
  -y developer_key.der \
  -d fenix8pro
```

### 4. Compiler (mode release)
```bash
monkeyc \
  -o bin/GarminSensorCapture.prg \
  -f monkey.jungle \
  -y developer_key.der \
  -d fenix8pro \
  --release
```

## Déploiement simulateur

```bash
# Lancer le simulateur Connect IQ
connectiq &

# Déployer l'app sur le simulateur
monkeydo bin/GarminSensorCapture_debug.prg fenix8pro
```

## Déploiement sur device réel

### Via USB
1. Connecter la montre via câble USB
2. Montre visible comme lecteur USB/MTP
3. Copier `bin/GarminSensorCapture.prg` dans `GARMIN/APPS/`
4. Éjecter en sécurité
5. L'app apparaît dans "Apps" sur la montre

### Via Garmin Express
1. Ouvrir Garmin Express
2. Glisser-déposer le `.prg` dans la section apps

## Utilisation

1. Ouvrir l'app SensorCapture sur la montre
2. L'écran affiche "IDLE" + statut GPS + statut BLE
3. Appuyer **START** pour démarrer la capture
4. L'écran affiche "RECORDING" + compteur de paquets
5. Appuyer **BACK** ou **START** pour arrêter
6. Les données sont transmises en temps réel à l'app Android

### Long press sur START
Marque un événement dans la session (lap/waypoint). Utile pour annoter des moments spécifiques.

## Configuration

Les paramètres configurables sont dans `resources/properties/properties.xml` :

| Propriété | Valeur par défaut | Description |
|-----------|------------------|-------------|
| `CompanionAppId` | a3b4c5d6-... | UUID de l'app Android (ne pas changer) |
| `MaxQueueSize` | 100 | Buffer max paquets en mémoire |
| `BatchSize` | 25 | Samples par paquet |
| `BatchTimeoutMs` | 1000 | Délai max avant envoi (ms) |
| `ReconnectIntervalMs` | 30000 | Délai de reconnexion BLE (ms) |
| `EnableMagnetometer` | true | Activer/désactiver le magnétomètre |
| `DebugLogging` | false | Logs verbeux (désactiver en prod) |

## Permissions requises

- `Sensor` : accès IMU (accel, gyro, mag, HR)
- `Positioning` : accès GPS
- `Communications` : canal BLE vers Android
- `FitContributor` : accès aux données Fit (facultatif)

## Limites connues

Voir `docs/limits_journal.md` pour la liste complète.

Principaux :
- Heap Connect IQ : ~260 KB → buffer max conservateur de 100 paquets
- Fréquence capteur non garantie à 25 Hz (voir H-001 dans `04_docs/04_hypotheses.md`)
- Magnétomètre peut être indisponible sur certains firmwares (H-015)

## Journaux (logs)

Les `System.println()` sont visibles :
- En simulateur : dans la console de debug
- Sur device : via port série (nécessite câble spécifique Garmin)
- Via l'outil `monkeydo --debug` en mode développeur

## Dépannage

Voir `04_docs/06_troubleshooting.md` section 1.

## Hypothèses non validées

Voir `04_docs/04_hypotheses.md` pour la liste complète des hypothèses qui doivent être validées sur hardware réel avant production.

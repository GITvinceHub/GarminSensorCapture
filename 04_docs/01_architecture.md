# Architecture Système — Garmin fēnix 8 Pro + Android + Python

## Vue d'ensemble

Le système collecte des données de capteurs depuis une montre Garmin fēnix 8 Pro, les transmet en temps réel à une application Android compagnon, les stocke au format JSONL, puis les analyse via un pipeline Python.

---

## Diagramme ASCII des composants

```
┌─────────────────────────────────────────────────────────────────┐
│                    GARMIN fēnix 8 Pro                           │
│                                                                  │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────────────┐ │
│  │ SensorManager│  │PositionManager│  │   BatchManager       │ │
│  │              │  │               │  │                      │ │
│  │ • Accel 25Hz │  │ • GPS 1Hz     │  │ • Accumulate samples │ │
│  │ • Gyro 25Hz  │  │ • lat/lon/alt │  │ • Batch 25 samples   │ │
│  │ • Mag 25Hz   │  │ • speed/hdg   │  │ • Flush on timeout   │ │
│  │ • HR 1Hz     │  │ • accuracy    │  │ • Protect memory     │ │
│  └──────┬───────┘  └──────┬────────┘  └──────────┬───────────┘ │
│         │                  │                       │             │
│         └──────────────────┴──────────────────────┘             │
│                                    │                             │
│                          ┌─────────▼──────────┐                 │
│                          │  SessionManager     │                 │
│                          │                     │                 │
│                          │ • IDLE/RECORDING/   │                 │
│                          │   STOPPING states   │                 │
│                          │ • session_id gen    │                 │
│                          │ • packet counters   │                 │
│                          └─────────┬───────────┘                │
│                                    │                             │
│                          ┌─────────▼───────────┐                │
│                          │  PacketSerializer   │                 │
│                          │                     │                 │
│                          │ • JSON compact v1   │                 │
│                          │ • max 4096 chars    │                 │
│                          │ • error_flags       │                 │
│                          └─────────┬───────────┘                │
│                                    │                             │
│                          ┌─────────▼───────────┐                │
│                          │ CommunicationManager│                 │
│                          │                     │                 │
│                          │ • BLE channel       │                 │
│                          │ • queue 20 packets  │                 │
│                          │ • ACK handling      │                 │
│                          │ • auto-reconnect    │                 │
│                          └─────────┬───────────┘                │
│                                    │                             │
│                          ┌─────────▼───────────┐                │
│                          │     MainView        │                 │
│                          │                     │                 │
│                          │ • Status display    │                 │
│                          │ • Packet counter    │                 │
│                          │ • GPS fix status    │                 │
│                          │ • Link status       │                 │
│                          └─────────────────────┘                │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                    Bluetooth LE (BLE)
                    Protocol JSON v1
                    Max 4KB/packet
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│                    ANDROID COMPANION APP                         │
│                                                                  │
│  ┌──────────────────────┐  ┌─────────────────────────────────┐  │
│  │  ConnectIQManager    │  │      GarminReceiver             │  │
│  │                      │  │                                 │  │
│  │ • SDK init           │  │ • IQApplicationEventListener   │  │
│  │ • Device discovery   │  │ • onMessageReceived()          │  │
│  │ • Channel management │  │ • JSON parsing                 │  │
│  │ • Status monitoring  │  │ • Packet validation            │  │
│  └──────────────────────┘  └─────────────────┬───────────────┘  │
│                                               │                  │
│  ┌────────────────────────┐  ┌────────────────▼──────────────┐  │
│  │    SessionManager      │  │       FileLogger              │  │
│  │                        │  │                               │  │
│  │ • Start/Stop session   │  │ • Append JSONL lines          │  │
│  │ • session_id gen       │  │ • 100MB rotation              │  │
│  │ • State flow           │  │ • BufferedWriter              │  │
│  └────────────────────────┘  └───────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────┐  ┌───────────────────────────────┐  │
│  │    MainViewModel       │  │      ExportManager            │  │
│  │                        │  │                               │  │
│  │ • UiState StateFlow    │  │ • exportJsonl()               │  │
│  │ • Throughput calc      │  │ • exportZip()                 │  │
│  │ • Error tracking       │  │ • shareFile()                 │  │
│  └────────────────────────┘  └───────────────────────────────┘  │
│                                                                  │
│                    MainActivity (UI)                             │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                    JSONL File Storage
                    (Internal Storage)
                    sessions/*.jsonl
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│                   PYTHON ANALYSIS PIPELINE                       │
│                                                                  │
│  ┌──────────────┐   ┌──────────────┐   ┌────────────────────┐  │
│  │   parser.py  │   │normalizer.py │   │    metrics.py      │  │
│  │              │──▶│              │──▶│                    │  │
│  │ • Read JSONL │   │ • imu_df     │   │ • duration         │  │
│  │ • Validate   │   │ • gps_df     │   │ • frequency        │  │
│  │ • Error hdlg │   │ • Units conv │   │ • packet loss      │  │
│  └──────────────┘   │ • Resample   │   │ • acc/gyro stats   │  │
│                     └──────────────┘   │ • HR stats         │  │
│                                        │ • GPS distance     │  │
│                                        └────────┬───────────┘  │
│                                                 │               │
│                     ┌──────────────┐   ┌────────▼───────────┐  │
│                     │  reporter.py │   │    plotter.py      │  │
│                     │              │◀──│                    │  │
│                     │ • summary.txt│   │ • accel plots      │  │
│                     │ • imu_data   │   │ • gyro plots       │  │
│                     │   .csv       │   │ • HR plot          │  │
│                     │ • gps_data   │   │ • GPS track        │  │
│                     │   .csv       │   │ • altitude profile │  │
│                     │ • metrics    │   │ • overview         │  │
│                     │   .json      │   └────────────────────┘  │
│                     └──────────────┘                            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Flux de données

### Flux principal (en temps réel)

```
Capteurs (25Hz) ──▶ SensorManager ──▶ BatchManager (25 samples)
                                              │
GPS (1Hz) ──────▶ PositionManager ───────────▼
                                       PacketSerializer
                                              │
                                     [JSON compact ≤4KB]
                                              │
                                    CommunicationManager
                                              │
                                          BLE Channel
                                              │
                                      GarminReceiver
                                              │
                                         FileLogger
                                              │
                                      sessions/*.jsonl
```

### Flux analyse (post-session)

```
sessions/*.jsonl ──▶ parser.py ──▶ normalizer.py ──▶ metrics.py
                                                           │
                                                     plotter.py ──▶ PNG charts
                                                           │
                                                     reporter.py ──▶ CSV/JSON/TXT
```

---

## Décisions techniques

### 1. Format JSON compact (protocole v1)
**Décision** : Utiliser des clés JSON courtes (1-3 caractères) pour minimiser la taille des paquets.
**Raison** : BLE a une MTU limitée. Chaque octet économisé réduit la fragmentation et la latence.
**Compromis** : Lisibilité réduite, mais le protocole est documenté dans `02_protocol_communication.md`.

### 2. Batching 25 échantillons
**Décision** : Accumuler 25 échantillons IMU avant envoi (≈1s à 25Hz).
**Raison** : Réduire overhead BLE (header par paquet). Balance latence vs efficacité.
**Compromis** : Latence maximale de 1s avant réception sur Android.

### 3. Queue mémoire montre (max 100 paquets)
**Décision** : Buffer circulaire de 100 paquets sur la montre.
**Raison** : Heap Connect IQ limité (~260KB). À 25 samples/paquet × ~200 bytes/sample ≈ 5KB/paquet.
**Compromis** : Perte de données si déconnexion BLE > 100s.

### 4. JSONL sur Android
**Décision** : Stocker les données en JSONL (JSON Lines) côté Android.
**Raison** : Format simple, appendable, compatible pandas, facilement streamable.
**Compromis** : Pas de compression native, mais facilite debug.

### 5. Architecture modulaire Python
**Décision** : Pipeline en 5 modules indépendants (parser → normalizer → metrics → plotter → reporter).
**Raison** : Testabilité individuelle, réutilisabilité, séparation des préoccupations.

### 6. StateFlow Android
**Décision** : Utiliser Kotlin StateFlow/SharedFlow pour la communication ViewModel → UI.
**Raison** : Pattern moderne Android (Jetpack), lifecycle-aware, thread-safe.

---

## Couches applicatives

```
┌─────────────────────────────────────────────────────────┐
│                    COUCHE PRÉSENTATION                   │
│  MainView (MC)          MainActivity (Kotlin)           │
│  MainDelegate (MC)      activity_main.xml               │
└─────────────────────────────────┬───────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────┐
│                    COUCHE LOGIQUE MÉTIER                 │
│  SessionManager (MC)    MainViewModel (Kotlin)          │
│  BatchManager (MC)      SessionManager (Kotlin)         │
│  PacketSerializer (MC)  GarminReceiver (Kotlin)         │
└─────────────────────────────────┬───────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────┐
│                    COUCHE DONNÉES / CAPTEURS             │
│  SensorManager (MC)     FileLogger (Kotlin)             │
│  PositionManager (MC)   ExportManager (Kotlin)          │
│  CommunicationManager   ConnectIQManager (Kotlin)       │
└─────────────────────────────────────────────────────────┘
```

---

## Contraintes système

| Contrainte | Valeur | Source |
|------------|--------|--------|
| Heap Connect IQ | ~260 KB | Garmin SDK docs |
| Taille max paquet BLE | 4096 bytes | Décision protocole |
| Samples par paquet | 25 max | Décision protocole |
| Queue montre | 100 paquets | Contrainte mémoire |
| Rotation fichier Android | 100 MB | Décision produit |
| minSdk Android | 26 (Android 8.0) | Hypothèse |
| Connect IQ SDK | 6.x | Hypothèse |

---

## Technologies utilisées

| Composant | Technologie | Version |
|-----------|-------------|---------|
| Watch App | Monkey C / Connect IQ | SDK 6.x |
| Android App | Kotlin | 1.9.0 |
| Android SDK | Android | 34 (target) / 26 (min) |
| Communication | Connect IQ Mobile SDK | dernière |
| BLE | Bluetooth Low Energy | via Connect IQ |
| Stockage Android | JSONL + File API | - |
| Analyse | Python | 3.10+ |
| DataFrames | pandas | 2.0+ |
| Calcul | numpy, scipy | latest |
| Visualisation | matplotlib | 3.7+ |

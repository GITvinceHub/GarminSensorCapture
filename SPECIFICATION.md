# GarminSensorCapture — Specification

> **Version** : 1.4.0  
> **Date** : 2026-04-24  
> **Statut** : Draft — specification-driven development
>
> **Méthodologies appliquées**
> - **SDD** (Specification-driven development) — les exigences précèdent et guident le code ; chaque module expose un contrat vérifiable
> - **BDD** (Behavior-driven development) — scénarios Given/When/Then exécutables comme critères d'acceptation
> - **DbC** (Design by Contract) — préconditions, postconditions, invariants pour chaque module critique

---

## Table des matières

1. [Introduction](#1-introduction)
2. [Glossaire](#2-glossaire)
3. [Contexte & stakeholders](#3-contexte--stakeholders)
4. [Exigences fonctionnelles (FR)](#4-exigences-fonctionnelles-fr)
5. [Exigences non-fonctionnelles (NFR)](#5-exigences-non-fonctionnelles-nfr)
6. [Architecture du système](#6-architecture-du-système)
7. [Contrats de modules (DbC)](#7-contrats-de-modules-dbc)
8. [Spécification du protocole de données](#8-spécification-du-protocole-de-données)
9. [Scénarios comportementaux (BDD)](#9-scénarios-comportementaux-bdd)
10. [Matrice de traçabilité](#10-matrice-de-traçabilité)
11. [Stratégie de test](#11-stratégie-de-test)
12. [Annexes](#12-annexes)
13. [Conformité Connect IQ — règles plateforme](#13-conformité-connect-iq--règles-plateforme)

---

## 1. Introduction

### 1.1 Objet du document

Ce document spécifie **GarminSensorCapture**, un système de capture multi-capteurs composé de trois modules coopérants :

| Module | Rôle | Technologie |
|---|---|---|
| **Watch** (`01_watch_app_connectiq/`) | Acquisition brute capteurs sur la montre Garmin | Monkey C / Connect IQ 9.1 |
| **Companion Android** (`02_android_companion/`) | Réception, persistance JSONL, export | Kotlin / AGP 8.1 / JDK 17 |
| **Analyse Python** (`03_python_analysis/`) | Parsing, normalisation, analyse des JSONL | Python 3.12 |

Le document respecte trois méthodologies complémentaires :
- **SDD** — chaque requirement (`FR-XXX`, `NFR-XXX`) est identifié, traçable jusqu'au code
- **BDD** — chaque fonctionnalité utilisateur est décrite via des scénarios Gherkin (`Given/When/Then`)
- **DbC** — chaque module expose un contrat (préconditions, postconditions, invariants)

### 1.2 Portée (Scope)

**Inclus** :
- Capture IMU 100 Hz (accéléromètre, gyroscope), magnétomètre 25 Hz
- Capture GPS 1 Hz, fréquence cardiaque, HRV (RR), SpO2, pression, température
- Transmission BLE watch→phone avec file persistante ACK-trackée
- Persistance JSONL côté Android, export ZIP
- 14 écrans d'information sur la montre avec navigation 2 axes (UP screens, DOWN sub-pages)
- Support bilingue (FR/EN), appareils supportés : fēnix 7 (7/7s/7x/7pro/7spro/7xpro) et fēnix 8 (8 43mm, 8 47mm, 8 Pro 47mm, 8 Solar 47mm, 8 Solar 51mm)

**Exclus** :
- Traitement temps-réel sur la montre (aucune détection/classification à bord)
- Sync cloud (pas d'upload automatique ; export manuel uniquement)
- UI Android riche (écran de debug uniquement ; pas de visualisation graphique)
- Multi-session concurrente (une session à la fois)

### 1.3 Conventions

- **ID de requirement** : `FR-XXX` (fonctionnel), `NFR-XXX` (non-fonctionnel), `INV-XXX` (invariant)
- **ID de scénario BDD** : `SC-XXX`
- **ID de contrat** : `C-XXX`
- **MUST / SHOULD / MAY** — selon RFC 2119
- Les blocs `Given/When/Then` sont en anglais (convention Gherkin)

---

## 2. Glossaire

| Terme | Définition |
|---|---|
| **Packet** | Unité atomique transmise du watch au phone, format JSON (protocole v1) |
| **Session** | Période délimitée entre `START` et `STOP` sur la montre ; un `sessionId` unique |
| **Header packet** | Paquet spécial émis à l'ouverture d'une session (`pt:"header"`) avec métadonnées utilisateur + historiques préalables |
| **Footer packet** | Paquet spécial émis à la clôture (`pt:"footer"`) avec historiques in-session |
| **Meta packet** | Header ou footer (tout paquet avec `pt` non nul) |
| **Data packet** | Paquet porteur de samples IMU (`pt` absent/null, `s` non-vide) |
| **Batch** | Accumulation de ~25 samples IMU avant émission d'un data packet (~250 ms) |
| **Persistent queue** | File on-flash côté montre contenant les paquets non-acquittés |
| **ACK** | Message phone→watch de forme `{"ack": N}` confirmant réception jusqu'au `pi=N` |
| **pi** | `packetIndex` — entier monotone croissant reset à 0 par session |
| **sid** | `sessionId` — string `YYYYMMDD_HHMMSS` de l'heure d'ouverture |
| **dtr** | `deviceTimeReference` — valeur `System.getTimer()` de la montre à l'émission |
| **ef** | `errorFlags` — bitmask protocole (SENSOR_ERROR=0x01, GPS_ERROR=0x02, BUFFER_OVERFLOW=0x04, PARTIAL_PACKET=0x08) |

---

## 3. Contexte & stakeholders

### 3.1 Parties prenantes

| Rôle | Intérêt | Critères de succès |
|---|---|---|
| **Chercheur / athlète** | Collecte de données brutes pour analyse biomécanique | IMU 100 Hz sans perte ; GPS 1 Hz horodaté ; export CSV/JSONL |
| **Développeur** | Maintenabilité, testabilité | Modules découplés, contrats explicites, tests reproductibles |
| **Garmin Connect IQ Store** | Conformité, stabilité | Pas de crash, permissions déclarées, UX conforme aux guidelines |
| **Utilisateur final** | Simplicité d'usage | 4 boutons physiques, messages en français, feedback visuel immédiat |

### 3.2 Cas d'usage principaux

```
UC-01  Enregistrer une session de capture multi-capteurs
UC-02  Visualiser l'état des capteurs pendant l'enregistrement
UC-03  Marquer un événement (lap / waypoint) pendant la session
UC-04  Démarrer une nouvelle session (clôture l'actuelle + ouvre une nouvelle)
UC-05  Verrouiller les boutons de la montre pendant l'activité
UC-06  Récupérer les données JSONL enregistrées sur le téléphone
UC-07  Exporter une session au format ZIP (partage via n'importe quelle app)
UC-08  Analyser les données via le script Python
```

### 3.3 Leçons retenues des itérations précédentes

Deux itérations ont révélé des écueils architecturaux à NE PAS reproduire :

| Itération | Problème observé | Cause racine | Leçon |
|---|---|---|---|
| **v1.0** | 93 % de packet loss côté Android | `CommunicationManager._drainQueue` boucle `Communications.transmit()` en rafale sans attendre `onComplete()` ; le CIQ runtime est **single-in-flight strict** et drop silencieusement tout nouveau `transmit` tant que le précédent n'est pas acquitté | **INV-008** (§7.8) : exactement 1 `transmit` en vol à tout moment |
| **v2.0** | App montre tuée par le runtime après ~6 paquets, sans exception attrapable | Trop de travail synchrone dans `onBatchReady` appelé depuis le callback capteur : SpO2 history, ActivityMonitor, flash write, BLE transmit — dépassement du budget watchdog CIQ (~400 ms) ET pression mémoire | **NFR-004** renforcé : le callback capteur n'accumule QUE ; sérialisation + transmit se font dans un Timer séparé |
| v2.0 | Header packet (~3 KB avec 7 historiques) émis synchronement au `startSession()` | Trop gros, occupe le seul in-flight slot au pire moment | **FR-008** optionnel, déclenché en différé après les 5 premiers data packets |

---

## 4. Exigences fonctionnelles (FR)

### 4.1 Capture capteurs (Watch)

| ID | Exigence | Priorité |
|---|---|---|
| **FR-001** | La montre MUST enregistrer l'accéléromètre à **100 Hz** quand une session est active | MUST |
| **FR-002** | La montre MUST enregistrer le gyroscope à **100 Hz** en parallèle | MUST |
| **FR-003** | La montre MUST enregistrer le magnétomètre à **25 Hz** (sous-échantillonné) | MUST |
| **FR-004** | La montre MUST capturer la fréquence cardiaque (bpm) au moins 1×/batch | MUST |
| **FR-005** | La montre MUST capturer les RR intervals (HRV source) fournis par le SDK si disponibles | SHOULD |
| **FR-006** | La montre MUST capturer position GPS, vitesse, cap, altitude à ~1 Hz | MUST |
| **FR-007** | La montre MUST capturer pression barométrique, température, SpO2, stress, body battery dans la meta | SHOULD |
| **FR-008** | La montre MAY émettre un header packet enrichi (user profile + histoires 60 entrées), **différé d'au moins 5 secondes** après le début d'enregistrement pour ne pas saturer le slot BLE au démarrage | MAY |

### 4.2 Transmission (Watch ↔ Phone)

| ID | Exigence | Priorité |
|---|---|---|
| **FR-010** | Le watch MUST transmettre les paquets via Connect IQ phone-app messaging (BLE) | MUST |
| **FR-011** | Le watch MUST **strictement** limiter à **1 `Communications.transmit` en vol** — chaque appel MUST attendre `onComplete()` OR `onError()` avant le suivant (corrige le bug de v1.0 à 93 % loss) | **MUST** |
| **FR-011b** | Le watch MUST utiliser un **Timer séparé** (période 250 ms) pour sérialiser + transmettre les batches ; le callback capteur lui MUST uniquement accumuler (pas de transmit, pas de flash, pas de SensorHistory) | **MUST** |
| **FR-012** | Le watch MUST re-transmettre les paquets non-acquittés après reconnexion BLE | SHOULD |
| **FR-013** | Le phone MUST acquitter chaque **data packet** via `{"ack": pi}` | MUST |
| **FR-014** | Le phone MUST ignorer la validation "samples non-vide" pour les **meta packets** | MUST |
| **FR-015** | Le watch MUST purger la persistent queue pour tout paquet dont `pi ≤ ackReçu` | MUST |
| **FR-016** | La persistent queue MUST survivre à un redémarrage de l'app (stockée en flash via `Application.Storage`) | MUST |
| **FR-017** | La persistent queue MUST être limitée à **60 entrées** (~54 Ko) pour rester dans le budget mémoire fēnix 8 | MUST |

### 4.3 Interface utilisateur (Watch)

| ID | Exigence | Priorité |
|---|---|---|
| **FR-020** | La montre MUST proposer **14 écrans** d'information navigables | MUST |
| **FR-021** | La touche UP (short) MUST faire avancer l'écran (1→2→…→14→1) | MUST |
| **FR-022** | La touche DOWN (short) MUST faire avancer la sous-page (4 sous-pages/écran) | MUST |
| **FR-023** | La touche START (short) MUST démarrer/arrêter l'enregistrement | MUST |
| **FR-024** | La touche START (long) MUST forcer une nouvelle session (stop+start) | SHOULD |
| **FR-025** | La touche BACK (short) MUST marquer un événement | MUST |
| **FR-026** | La touche BACK (long) MUST exécuter un arrêt d'urgence | MUST |
| **FR-027** | La touche UP (long) MUST ouvrir le menu de capture | SHOULD |
| **FR-028** | La touche DOWN (long) MUST activer/désactiver le verrou boutons | SHOULD |
| **FR-029** | L'affichage MUST se rafraîchir à au moins **2 Hz** pendant l'enregistrement | MUST |
| **FR-030** | Les titres, statuts et labels MUST être localisés en FR et EN | SHOULD |

### 4.4 Persistance & export (Android)

| ID | Exigence | Priorité |
|---|---|---|
| **FR-040** | Le phone MUST écrire chaque paquet en ligne JSONL dans un fichier par session | MUST |
| **FR-041** | Le phone MUST faire la rotation de fichier au-delà de **100 Mo** | SHOULD |
| **FR-042** | Le phone MUST flusher le buffer toutes les **10 lignes** | SHOULD |
| **FR-043** | Le phone MUST permettre l'export JSONL et ZIP via `Intent.ACTION_SEND` | MUST |

### 4.5 Analyse (Python)

| ID | Exigence | Priorité |
|---|---|---|
| **FR-050** | Le script Python MUST parser un JSONL et normaliser les timestamps (résolution du `t` incremental par sample) | MUST |
| **FR-051** | Le script MUST produire des CSV normalisés : `imu_100hz.csv`, `gps_1hz.csv`, `hr.csv`, `meta_timeline.csv` | MUST |
| **FR-052** | Le script MUST détecter les gaps de `pi` (paquets perdus) et les reporter | SHOULD |

---

## 5. Exigences non-fonctionnelles (NFR)

### 5.1 Performance

| ID | Exigence | Cible mesurable |
|---|---|---|
| **NFR-001** | Latence watch→phone par paquet | < 500 ms médiane |
| **NFR-002** | Fréquence IMU effective | ≥ 95 % de 100 Hz (soit ≥ 95 Hz mesuré) |
| **NFR-003** | Débit soutenu BLE | ≥ 3 paquets/s soutenus (≥ 2,5 Ko/s) |
| **NFR-004** | Budget CPU dans un callback capteur (`onSensorDataReceived`) | < 50 ms — accumulation pure uniquement, aucun I/O, aucune sérialisation JSON, aucun appel `SensorHistory.*`, aucun `Communications.transmit`, aucun `Application.Storage.setValue` |
| **NFR-004b** | Budget CPU dans un callback Timer de dispatch (émission de paquet) | < 200 ms par tick (250 ms interval → 55 % headroom) |
| **NFR-005** | Consommation batterie | < 20 %/h pendant enregistrement continu |

### 5.2 Fiabilité

| ID | Exigence | Cible |
|---|---|---|
| **NFR-010** | Aucun crash utilisateur sur un parcours nominal | 0 crash sur session de 1 h |
| **NFR-011** | Tolérance déconnexion BLE | ≥ 15 s bufferisés sans perte |
| **NFR-012** | Tous les callbacks CIQ (`onSensorDataReceived`, `onPosition`, `onReceive`, `onComplete`, `onError`, `onBatchReady`, `_onBatchTimeout`) MUST être enveloppés dans try/catch | OBLIGATOIRE |
| **NFR-013** | Toute exception dans un callback MUST être loggée via `System.println` sans propager au runtime CIQ | OBLIGATOIRE |

### 5.3 Sécurité & vie privée

| ID | Exigence |
|---|---|
| **NFR-020** | Les données GPS/HR MUST rester locales (pas d'upload sans action utilisateur) |
| **NFR-021** | Le fichier JSONL MUST être stocké dans le sandbox de l'app Android (`Context.filesDir`) |
| **NFR-022** | Le partage (export) MUST passer par `FileProvider` / `Intent.ACTION_SEND` (pas d'écriture publique) |

### 5.4 Compatibilité

| ID | Exigence |
|---|---|
| **NFR-030** | Appareils supportés : fēnix 7 (7/7s/7x/7pro/7spro/7xpro) + fēnix 8 (8 43mm, 8 47mm, 8 Pro 47mm, 8 Solar 47mm, 8 Solar 51mm) |
| **NFR-031** | Connect IQ SDK ≥ 3.3.0 |
| **NFR-032** | Android SDK min 26 (Android 8) ; target 34 (Android 14) |
| **NFR-033** | JDK 17 requis (AGP 8.1 incompatible avec JDK 21) |

### 5.5 Maintenabilité

| ID | Exigence |
|---|---|
| **NFR-040** | Tout module MUST être isolable (SensorManager, PositionManager, BatchManager, CommunicationManager, PersistentQueue, SessionManager indépendants) |
| **NFR-041** | Tout code MUST être documenté en commentaire `//!` (format Monkey C doc) ou KDoc pour Kotlin |
| **NFR-042** | Les constantes magiques (`MAX_BATCH_SIZE`, `MAX_BUFFER_SIZE`, `RETRY_INTERVAL_MS`) MUST être nommées et commentées |

---

## 6. Architecture du système

### 6.1 Diagramme de composants

```
                       ┌──────────────────────────────────┐
                       │          WATCH (CIQ)             │
                       │                                  │
   ┌─────────┐         │  ┌──────────────┐                │
   │ Sensor  │────────▶│  │SensorManager │                │
   │ HW      │         │  └──────┬───────┘                │
   └─────────┘         │         │sample                  │
                       │         ▼                        │
   ┌─────────┐         │  ┌──────────────┐                │
   │ GPS HW  │────────▶│  │PositionMgr   │                │
   └─────────┘         │  └──────┬───────┘                │
                       │         │gpsData                 │
                       │         ▼                        │
                       │  ┌────────────────┐              │
                       │  │ SessionManager │◀─state FSM   │
                       │  └──┬───────┬─────┘              │
                       │     │       │onBatchReady        │
                       │     ▼       ▼                    │
                       │  ┌─────┐  ┌────────────────┐     │
                       │  │Batch│  │PacketSerializer│     │
                       │  │Mgr  │  └────────┬───────┘     │
                       │  └─────┘           │JSON         │
                       │                    ▼             │
                       │              ┌─────────────┐     │
                       │              │Persistent   │     │
                       │              │Queue (flash)│     │
                       │              └──────┬──────┘     │
                       │                     ▼            │
                       │              ┌──────────────┐    │
                       │              │Communication │    │
                       │              │Manager       │    │
                       │              └──────┬───────┘    │
                       │                     │            │
                       └─────────────────────┼────────────┘
                                             │ BLE (CIQ channel)
                                             │
                       ┌─────────────────────┼────────────┐
                       │         ANDROID     ▼            │
                       │              ┌──────────────┐    │
                       │              │GarminReceiver│    │
                       │              └──────┬───────┘    │
                       │                     │packet      │
                       │              ┌──────┴──────┐     │
                       │              ▼             ▼     │
                       │         ┌─────────┐  ┌─────────┐ │
                       │         │File     │  │Send ACK │ │
                       │         │Logger   │  │{"ack":N}├─┘ (retour BLE)
                       │         │(JSONL)  │  └─────────┘
                       │         └────┬────┘
                       │              ▼
                       │         ┌─────────┐
                       │         │Export   │
                       │         │Manager  │
                       │         │(ZIP)    │
                       │         └────┬────┘
                       │              │
                       └──────────────┼──────────────
                                      ▼
                               ┌──────────────┐
                               │Python analyse│
                               │(main.py)     │
                               └──────────────┘
```

### 6.2 Machine à états (Session)

```
             ┌───────┐  startSession()  ┌───────────┐
             │ IDLE  │─────────────────▶│ RECORDING │
             └───▲───┘                  └─────┬─────┘
                 │                            │
                 │                            │stopSession()
                 │                            ▼
                 │           footer+flush ┌───────────┐
                 └────────────────────────┤ STOPPING  │
                                          └───────────┘
```

### 6.3 Flux de données temps réel

```
t=0           Session START
│
├─header─────────────────────────────▶ Android (pv=1, pt="header", pi=0, sid=...)
│                                      Android ne ACK pas (isMetaPacket)
│
├─sensor register (100Hz accel/gyro, 25Hz mag)
├─position enable (1Hz GPS)
│
t=1s          First sensor callback (100 samples)
│             → BatchManager.accumulate × 100
│                 Every 25 samples: _dispatchBatch()
│                   → SessionManager.onBatchReady
│                     → PacketSerializer.serializePacket
│                     → PersistentQueue.push(pi, json)
│                     → CommunicationManager.sendPacket
│
├─data packet pi=0 ───────────────────▶ Android
│                                      ← {"ack": 0}
├─data packet pi=1 ───────────────────▶ Android
│                                      ← {"ack": 1}
├─data packet pi=2 ───────────────────▶ Android
│                                      ← {"ack": 2}
├─data packet pi=3 ───────────────────▶ Android
│                                      ← {"ack": 3}
│
...
t=N           Session STOP
├─flush batch
├─footer packet (pt="footer", pi=_packetIndex)
├─sensor unregister
├─position disable
└─state=IDLE
```

---

## 7. Contrats de modules (DbC)

### 7.1 SensorManager

**Responsabilité** : interface capteurs IMU + HR.

#### C-001 `register()`
- **Précondition** : `_isRegistered == false`
- **Postcondition** (succès) : `_isRegistered == true` AND le callback `onSensorDataReceived` sera invoqué chaque seconde avec ~100 samples
- **Postcondition** (échec) : `_isRegistered == false` AND un message d'erreur a été loggé
- **Invariant** : `_buffer.size() ≤ MAX_BUFFER_SIZE` (50)

#### C-002 `onSensorDataReceived(data)`
- **Précondition** : `data: Sensor.SensorData` non-null
- **Postcondition** : chaque sample extrait est livré via `_callback.invoke(sample)` ; le buffer circulaire contient au plus les 50 derniers samples ; **aucune exception ne doit sortir du callback** (NFR-012)
- **Side-effect** : `_measuredFrequency` mis à jour chaque seconde

#### C-003 `getAxisStats(key, maxPoints)`
- **Précondition** : `key ∈ {"ax","ay","az","gx","gy","gz","mx","my","mz","hr"}` ; `maxPoints > 0`
- **Postcondition** : retourne `{"rms","max","min"}` (Float) calculé sur les min(maxPoints, buffer.size()) derniers samples ; si buffer vide → `{"rms":0,"max":0,"min":0}`

### 7.2 BatchManager

#### C-010 `accumulate(sample)`
- **Précondition** : `sample: Dictionary` non-null avec clés `{t,ax,ay,az,gx,gy,gz,mx,my,mz,hr}`
- **Postcondition** : `_batch` contient `sample` OU (si `_batch.size() ≥ MAX_BATCH_SIZE`) le callback de dispatch a été invoqué avec le batch complet et `_batch` remis à zéro
- **Invariant** : `0 ≤ _batch.size() ≤ MAX_BATCH_SIZE` (25) en permanence

#### C-011 `_onBatchTimeout()`
- **Précondition** : appelé par le timer CIQ après `BATCH_TIMEOUT_MS` (1000 ms)
- **Postcondition** : si `_batch.size() > 0`, le batch a été dispatché ; **aucune exception ne doit sortir** (NFR-012)

### 7.3 PacketSerializer

#### C-020 `serializePacket(sessionId, packetIndex, deviceTime, samples, rrIntervals, gpsData, metaDict, errorFlags)`
- **Précondition** : `sessionId != ""` ; `packetIndex ≥ 0` ; `samples.size() > 0` ; `metaDict.get("bat") != null`
- **Postcondition** : retourne une String JSON de longueur `≤ MAX_PACKET_SIZE` (4096) OU `null` si la sérialisation échoue ; le JSON est parseable selon le protocole v1 (§8)
- **Invariant** : la taille du JSON retourné est toujours ≤ MAX_PACKET_SIZE (truncation si overflow, `ef |= EF_PARTIAL_PACKET`)

### 7.4 CommunicationManager

#### C-030 `sendPacket(data)`
- **Précondition** : `data: String` non-vide
- **Postcondition** : le paquet est enquêté dans `_queue` et une transmission a été tentée (si pas déjà pending) ; aucune exception ne propage ; `_queue.size() ≤ MAX_QUEUE_SIZE` (20)
- **Invariant** : `_transmitPending == true` ⇒ exactement 1 `Communications.transmit()` est en vol

#### C-031 `onReceive(msg)`
- **Précondition** : `msg: PhoneAppMessage` ; `msg.data` peut être de n'importe quel type supporté CIQ
- **Postcondition** : si `msg.data` est un Dictionary contenant `"ack":N` alors `_persistentQueue.ackUpTo(N)` a été appelé ; **toute exception est attrapée et loggée** (NFR-012)

### 7.5 PersistentQueue

#### C-040 `push(pi, json)`
- **Précondition** : `pi ≥ 0` ; `json: String` non-vide
- **Postcondition** : l'entrée `{pi, d:json}` est dans `_entries` ; si `_entries.size() > MAX_ENTRIES` (60) avant l'ajout, l'entrée la plus ancienne est droppée ; toutes les 10 pushes, un flush flash est effectué
- **Invariant** : `_entries.size() ≤ MAX_ENTRIES` après chaque push

#### C-041 `ackUpTo(ackPi)`
- **Précondition** : `ackPi ≥ 0`
- **Postcondition** : toutes les entrées avec `pi ≤ ackPi` sont supprimées de `_entries` ; si au moins une a été supprimée, un flush flash est effectué

### 7.6 SessionManager (contrat de haut niveau)

#### C-050 `startSession()`
- **Précondition** : `_state == STATE_IDLE`
- **Postcondition** (succès) : `_state == STATE_RECORDING` ; `_sessionId` est un nouveau string ; `_packetIndex == 0` ; la persistent queue a été vidée ; un header packet a été émis ; les capteurs sont enregistrés
- **Postcondition** (échec partiel) : toute exception d'un sous-module est attrapée ; `_errorCount` est incrémenté ; l'état final est néanmoins `RECORDING` si au moins l'IMU ou le GPS ont démarré

#### C-051 `onBatchReady(samples)`
- **Précondition** : `samples.size() > 0`
- **Postcondition** : si `_state ∈ {RECORDING, STOPPING}`, un data packet a été sérialisé + pushé en file persistante + transmis ; `_packetIndex` a été incrémenté ; **aucune exception ne propage** (NFR-012)

### 7.7 GarminReceiver (Android)

#### C-060 `onMessageReceived(device, app, messageData, status)`
- **Précondition** : appelé par le SDK Connect IQ Mobile
- **Postcondition** : 
  - Si status ≠ SUCCESS → onError invoqué, invalidPacketsCount++
  - Si le JSON parse échoue → invalidPacketsCount++
  - Si validation échoue → invalidPacketsCount++
  - Sinon → fileLogger.logPacket, compteurs mis à jour, **onSendAck invoqué uniquement pour les data packets** (pas les meta), onPacketReceived invoqué
- **Invariant** : **aucune exception ne sort de cette méthode** (wrapped try/catch exterieur)

#### C-061 `validatePacket(packet)`
- **Précondition** : `packet: GarminPacket` non-null
- **Postcondition** : retourne `true` si :
  - `sessionId` non-null et non-vide
  - `packetIndex ≥ 0`
  - `samples` peut être `null` pour les meta packets (`packetType != null`)
  - Sinon `samples != null` et non-vide OU `isPartial == true`
- **Retourne `false`** dans tous les autres cas (sans exception)

### 7.8 Invariants globaux

| ID | Invariant | Vérifié par |
|---|---|---|
| **INV-001** | `_packetIndex` est monotone croissant au sein d'une session | SessionManager |
| **INV-002** | `sessionId` est unique entre sessions (basé sur l'heure UTC au format `YYYYMMDD_HHMMSS`) | generateSessionId() |
| **INV-003** | Le header packet est toujours le premier paquet d'une session, avec `pt:"header"`, `pi=0` | _sendHeaderPacket() |
| **INV-004** | Le footer packet est toujours le dernier paquet d'une session, avec `pt:"footer"` | _sendFooterPacket() |
| **INV-005** | Un paquet data a `pt` absent/null ET `s` non-vide (sauf si flag PARTIAL_PACKET) | PacketSerializer |
| **INV-006** | Un ACK n'est jamais envoyé pour un meta packet | GarminReceiver |
| **INV-007** | Après `ackUpTo(N)`, aucune entrée de la persistent queue n'a `pi ≤ N` | PersistentQueue |
| **INV-008** | À tout instant, **au plus 1 appel `Communications.transmit()` est en vol** (pas encore `onComplete`/`onError`). Violation = perte silencieuse de paquets (cause du bug v1.0 93 % loss) | CommunicationManager._transmitPending |
| **INV-009** | Le callback `onSensorDataReceived` n'appelle AUCUNE API bloquante (pas de `SensorHistory.*`, pas de `Communications.transmit`, pas de `Application.Storage.setValue`) — uniquement `accumulate()` | SensorManager |

---

## 8. Spécification du protocole de données

### 8.1 Data packet (protocole v1)

```json
{
  "pv": 1,
  "sid": "20260424_140532",
  "pi": 42,
  "dtr": 1234567,
  "s": [
    {"t":10,"ax":-123.456,"ay":0.789,"az":9810.0,
     "gx":0.1,"gy":-0.2,"gz":0.0,
     "mx":12.34,"my":-5.67,"mz":45.67,"hr":72}
    /* ... 25 samples max ... */
  ],
  "rr": [812, 820, 815],
  "gps": {"lat":45.123456,"lon":-73.654321,"alt":123.4,
          "spd":1.23,"hdg":90.0,"acc":5.0,"ts":1745500000},
  "meta": {"bat":88,"pres_pa":101325,"temp_c":21.5,
           "spo2":97,"stress":25,"body_batt":80},
  "ef": 0
}
```

**Champs** :

| Clé | Type | Unité | Présence |
|---|---|---|---|
| `pv` | int | — | toujours = 1 (protocol version) |
| `sid` | string | `YYYYMMDD_HHMMSS` | toujours |
| `pi` | long | index | toujours ; monotone par session |
| `dtr` | long | ms (watch uptime) | toujours |
| `s` | array[Sample] | — | data packet : obligatoire ; meta : absent |
| `s[].t` | int | ms | toujours ; **période par sample** (10 ms à 100 Hz) — PAS un offset cumulatif |
| `s[].ax/ay/az` | float | milli-g | toujours |
| `s[].gx/gy/gz` | float | deg/s | toujours |
| `s[].mx/my/mz` | float | µT | toujours (0 si sous-échantillonné à 25 Hz) |
| `s[].hr` | int | bpm | toujours ; 0 si indisponible |
| `rr` | array[int] | ms | optionnel ; RR intervals du batch |
| `gps` | object | — | optionnel ; absent si pas de fix |
| `meta.bat` | int | % | obligatoire |
| `meta.*` | — | — | optionnels |
| `ef` | int | bitmask | toujours ; 0 si pas d'erreur |

### 8.2 Header packet

```json
{
  "pv": 1,
  "pt": "header",
  "sid": "20260424_140532",
  "pi": 0,
  "dtr": 1234000,
  "user": {"weight_g":75000,"height_cm":180,"birth_year":1990,"gender":"M"},
  "device": {"part_number":"006-B4687-00","firmware":"20.26","monkey_version":"5.2.0","app_version":"1.4.0"},
  "history": {
    "hr":       [[1745499900,72],[1745499890,71],...],
    "hrv":      [[1745499900,55],...],
    "spo2":     [[1745499800,97],...],
    "stress":   [[1745499900,25],...],
    "pressure": [[1745499900,101325],...],
    "temp":     [[1745499900,21.5],...],
    "elev":     [[1745499900,123.4],...]
  }
}
```

### 8.3 Footer packet

```json
{
  "pv": 1,
  "pt": "footer",
  "sid": "20260424_140532",
  "pi": 142,
  "dtr": 1234567,
  "history": { "hr": [...], "hrv": [...], ... }  // in-session only (ts ≥ sessionStart)
}
```

### 8.4 ACK (phone→watch)

```json
{"ack": 42}
```

Cela confirme la réception de tous les data packets jusqu'à `pi=42` inclus.

### 8.5 Format JSONL (Android → disque)

Chaque paquet reçu est écrit comme une ligne JSON avec enrichissement :

```json
{"received_at":"2026-04-24T14:05:33.217Z","session_id":"20260424_140532","pv":1,"pt":null,"sid":"20260424_140532","pi":0,"dtr":1234010,"s":[...],"gps":null,"meta":{"bat":88},"ef":0}
```

- `received_at` : ISO-8601 UTC de réception côté Android
- `session_id` : copie pour indexation rapide
- `pt` : null pour data packets, "header"/"footer" pour meta

### 8.6 Flags d'erreur (`ef`)

| Constante | Valeur | Sens |
|---|---|---|
| `EF_SENSOR_ERROR` | 0x01 | Un capteur a retourné null/erreur dans le batch |
| `EF_GPS_ERROR` | 0x02 | GPS indisponible (`gps: null`) |
| `EF_BUFFER_OVERFLOW` | 0x04 | Buffer capteur a débordé avant dispatch |
| `EF_PARTIAL_PACKET` | 0x08 | Samples tronqués pour respecter `MAX_PACKET_SIZE` |
| `EF_CLOCK_SKEW` | 0x10 | Dérive d'horloge détectée |
| `EF_COMM_RETRY` | 0x20 | Paquet retransmis après échec |

---

## 9. Scénarios comportementaux (BDD)

### SC-001 — Démarrage d'une session nominale

```gherkin
Feature: Session capture
  Pour un athlète
  Afin de collecter des données biomécaniques
  Je veux démarrer une session depuis la montre

Scenario: Démarrage à froid, téléphone connecté
  Given the watch app is open on screen RÉSUMÉ
    And the Android companion is running and "Start Session" is pressed
    And Bluetooth is connected
  When the user presses START on the watch
  Then the watch state transitions from IDLE to RECORDING within 100 ms
    And a header packet is transmitted with pt="header" and pi=0
    And the Android app receives the header packet
    And the Android app does NOT send an ACK for the header
    And within 1.5 seconds, the first data packet is transmitted with pi=0
    And the Android app sends {"ack":0} in response
    And the timer displayed on the watch starts counting up
    And the BLE indicator on the CONNEXIONS screen turns green
```

### SC-002 — Header packet ne crashe plus Android

```gherkin
Scenario: Header packet parsing safety (FR-014 / bug v1.3.x)
  Given the Android companion has a session opened
  When the watch transmits a header packet (s field is absent)
  Then the Android app does NOT crash
    And the packet is written to the JSONL file with s=[]
    And the validation passes because isMetaPacket is true
    And no ACK is emitted
```

### SC-003 — Survivre à une déconnexion BLE brève

```gherkin
Scenario: BLE disconnection during recording
  Given a recording session is active since 30 seconds
    And 120 data packets have been successfully ACKed
  When the Bluetooth link is interrupted for 10 seconds
  Then the watch continues capturing IMU at 100 Hz
    And new data packets are queued in PersistentQueue
    And PersistentQueue size does NOT exceed 60 entries
    And when the BLE link is restored
    And the queued packets are retransmitted
    And Android deduplicates based on packetIndex
    And no samples are permanently lost
```

### SC-004 — Arrêt d'urgence

```gherkin
Scenario: Emergency stop via BACK long-press
  Given a recording session is active
  When the user holds BACK for more than 1000 ms
  Then the session state transitions to STOPPING
    And a footer packet is emitted with pt="footer"
    And the PersistentQueue is flushed to flash
    And sensors are unregistered
    And state returns to IDLE within 2 seconds
    And the timer displayed resets to 00:00:00
```

### SC-005 — Navigation entre écrans

```gherkin
Scenario Outline: Screen navigation
  Given the watch app is on screen <start>
  When the user presses UP short
  Then the watch app is on screen <next>
    And screen_<next>_title is displayed at top center
    And the nav dots highlight the <next_index>-th dot

  Examples:
    | start      | next       | next_index |
    | RÉSUMÉ     | IMU        | 1          |
    | IMU        | GPS        | 2          |
    | GPS        | FC         | 3          |
    | PIPELINE   | RÉSUMÉ     | 0          |
```

### SC-006 — Verrouillage des boutons

```gherkin
Scenario: Button lock prevents accidental actions
  Given a recording session is active
    And the button lock is OFF
  When the user holds DOWN for more than 1000 ms
  Then the button lock is ON
    And "LOCK" indicator is displayed top-right
  When the user presses START short
  Then the session state remains RECORDING
    And no event is marked
  When the user holds DOWN for more than 1000 ms again
  Then the button lock is OFF
```

### SC-007 — Marquage d'événement

```gherkin
Scenario: Mark lap event
  Given a recording session is active
  When the user presses BACK short
  Then an event timestamp is added to _eventMarks
    And the next data packet includes the event in metadata
    And the eventCount displayed on RÉSUMÉ increments by 1
```

### SC-008 — Export JSONL côté Android

```gherkin
Scenario: Export session as JSONL
  Given a session has ended with 150 packets written
    And the file exists at {filesDir}/sessions/{sessionId}.jsonl
  When the user taps "Export JSONL"
  Then an Intent.ACTION_SEND is dispatched with application/json
    And the user can choose a target app (Gmail, Drive, etc.)
    And the file is shared via FileProvider
```

### SC-009 — Analyse Python

```gherkin
Scenario: Parse JSONL and produce CSVs
  Given a valid JSONL file {session}.jsonl exists
    And it contains 1 header + 100 data + 1 footer packets
  When I run "python main.py {session}.jsonl --output-dir ./out"
  Then ./out/imu_100hz.csv exists with 2500 rows (100 packets × 25 samples)
    And ./out/gps_1hz.csv exists with ≈ 100 rows
    And ./out/meta_timeline.csv exists
    And the timestamps are reconstructed using t (per-sample period)
```

### SC-010 — Résilience exception capteur

```gherkin
Scenario: Sensor callback exception does not kill the app (NFR-012)
  Given a recording session is active
    And some internal method in onBatchReady throws an exception
  When the next sensor callback fires
  Then the exception is caught by the outer try/catch
    And a log line "SessionManager: FATAL in onBatchReady" is emitted
    And _errorCount is incremented
    And the app continues to process subsequent sensor callbacks
    And new packets continue to be transmitted
```

### SC-011 — Rafraîchissement live de l'affichage

```gherkin
Scenario: Display refreshes at 2 Hz during recording (FR-029)
  Given a recording session is active
    And the user is on screen RÉSUMÉ
  When 1 second elapses
  Then the onUpdate method has been called at least 2 times
    And the timer display shows an updated value
    And the IMU Hz display shows a current measurement
```

---

## 10. Matrice de traçabilité

| Requirement | Module(s) | Fichier(s) | Scénario BDD |
|---|---|---|---|
| FR-001, FR-002 | SensorManager | `SensorManager.mc` (register, PRIMARY_RATE_HZ=100) | SC-001 |
| FR-003 | SensorManager | `SensorManager.mc` (MAG_RATE_HZ=25) | SC-001 |
| FR-004, FR-005 | SensorManager | `SensorManager.mc` (getLastHrBpm, getLastRrIntervals) | SC-001 |
| FR-006 | PositionManager | `PositionManager.mc` | SC-001 |
| FR-007 | SensorManager | `getLiveSensorInfo`, `getActivityMonitorInfo` | SC-001 |
| FR-008 | SensorManager, PacketSerializer | `_sendHeaderPacket` + `serializeHeaderPacket` | SC-001, SC-002 |
| FR-010, FR-011 | CommunicationManager | `_transmitPending`, single-in-flight | SC-001 |
| FR-012, FR-015, FR-016 | PersistentQueue | `PersistentQueue.mc` | SC-003 |
| FR-013, FR-014 | GarminReceiver, MainActivity | `GarminReceiver.kt`, `MainActivity.kt` (onSendAck) | SC-002 |
| FR-017 | PersistentQueue | `MAX_ENTRIES=60` | SC-003 |
| FR-020 → FR-028 | MainView, MainDelegate, UiState | `MainView.mc`, `MainDelegate.mc` | SC-004, SC-005, SC-006, SC-007 |
| FR-029 | MainView | `MainView._refreshTimer` (REFRESH_INTERVAL_MS=500) | SC-011 |
| FR-030 | Resources | `strings.xml`, `strings-fra.xml` | — |
| FR-040, FR-041, FR-042 | FileLogger | `FileLogger.kt` | — |
| FR-043 | ExportManager | `ExportManager.kt` | SC-008 |
| FR-050, FR-051, FR-052 | Python | `03_python_analysis/main.py` | SC-009 |
| NFR-001 → NFR-005 | tous | — | à mesurer en test terrain |
| NFR-010 | SessionManager, tous | tests longue durée | — |
| NFR-011 | PersistentQueue | `getResendBatch`, `_injectResendBatch` | SC-003 |
| NFR-012, NFR-013 | tous les callbacks CIQ | try/catch dans : `onSensorDataReceived`, `onPosition`, `onReceive`, `_onTransmitOk`, `_onTransmitFailed`, `onBatchReady`, `_onBatchTimeout`, `onCommStatusChange`, `onMessageReceived` | SC-010 |

---

## 11. Stratégie de test

### 11.1 Pyramide de tests

```
            ┌────────────────────┐
            │ E2E terrain (manuel)│   ← SC-001, SC-003
            └─────────┬──────────┘
                 ┌────┴────┐
                 │ Intégration│      ← scripts Python sur JSONL réels
                 └─────┬────┘
              ┌───────┴──────────┐
              │   Tests unitaires  │   ← Python : parser, normalisation
              └──────────────────┘
```

### 11.2 Niveaux

| Niveau | Outil | Portée |
|---|---|---|
| **Simulateur CIQ** | Connect IQ SDK simulator (GUI) | SensorManager, PositionManager, MainView rendering |
| **Unitaire Python** | `pytest` | Parser JSONL, reconstruction timestamps, normalisation |
| **Intégration manuelle** | Watch réelle + Android réelle | Flow bout-en-bout (enregistrement + ACK) |
| **Tests de contrat (DbC)** | Assertions explicites dans le code | Préconditions vérifiées à l'entrée, postconditions en sortie |
| **Tests de régression crash** | Checklists BDD | SC-002, SC-010 |

### 11.3 Critères d'acceptation de release

- [ ] `.iq` release compile pour 18/18 devices
- [ ] APK debug build sans erreur
- [ ] Tous les callbacks CIQ sont enveloppés dans try/catch (NFR-012)
- [ ] Une session de 5 minutes nominale ne crashe pas (NFR-010)
- [ ] Les 14 écrans sont navigables UP + DOWN sur appareil réel
- [ ] Le JSONL produit passe le script Python sans erreur
- [ ] PersistentQueue reste < 60 entrées sur session normale
- [ ] Android reçoit ≥ 99 % des paquets data

### 11.4 Limites connues à ne PAS tester (hors scope)

- Plus de 60 s de déconnexion BLE (perte acceptée > 15 s)
- Sessions > 24 h (overflow potentiel de `_packetIndex` non géré à dessein)
- Plus de 100 Mo par fichier JSONL (rotation non testée en intégration)

---

## 13. Conformité Connect IQ — règles plateforme

Cette section documente l'audit de conformité du module **watch** (`01_watch_app_connectiq/`) vis-à-vis de la documentation officielle Garmin Connect IQ (SDK 9.1.0, 2026-03-09). Le système de numérotation `GIQ-XXX` étend celui des FR/NFR/INV.

### 13.1 Sources normatives

Les règles extraites proviennent des pages suivantes (lues localement depuis la distribution SDK 9.1.0 — l'équivalent web fait l'objet d'un rendu JavaScript qui rend le scraping non déterministe) :

- `Core_Topics/Manifest_and_Permissions.html` → <https://developer.garmin.com/connect-iq/core-topics/manifest-and-permissions/>
- `Core_Topics/Application_and_System_Modules.html` → <https://developer.garmin.com/connect-iq/core-topics/application-and-system-modules/>
- `Core_Topics/Sensors.html` → <https://developer.garmin.com/connect-iq/core-topics/sensors/>
- `Core_Topics/Positioning.html` → <https://developer.garmin.com/connect-iq/core-topics/positioning/>
- `Core_Topics/Communicating_with_Mobile_Apps.html` → <https://developer.garmin.com/connect-iq/core-topics/communicating-with-mobile-apps/>
- `Core_Topics/Persisting_Data.html` → <https://developer.garmin.com/connect-iq/core-topics/persisting-data/>
- `Core_Topics/Input_Handling.html` → <https://developer.garmin.com/connect-iq/core-topics/input-handling/>
- `Core_Topics/User_Interface.html` → <https://developer.garmin.com/connect-iq/core-topics/user-interface/>
- `Core_Topics/Resources.html` → <https://developer.garmin.com/connect-iq/core-topics/resources/>
- `Core_Topics/Monkey_Style.html` → <https://developer.garmin.com/connect-iq/core-topics/monkey-style/>
- `Core_Topics/Debugging.html` → <https://developer.garmin.com/connect-iq/core-topics/debugging/>
- `Core_Topics/Backgrounding.html` → <https://developer.garmin.com/connect-iq/core-topics/backgrounding/>
- `Core_Topics/Publishing_to_the_Store.html` → <https://developer.garmin.com/connect-iq/core-topics/publishing-to-the-store/>
- `Core_Topics/Exception_Reporting_Tool.html` → <https://developer.garmin.com/connect-iq/core-topics/exception-reporting-tool/>
- `Core_Topics/Profiling.html` → <https://developer.garmin.com/connect-iq/core-topics/profiling/>
- `Connect_IQ_Basics/App_Types.html` → <https://developer.garmin.com/connect-iq/connect-iq-basics/app-types/>
- `Monkey_C/Exceptions_and_Errors.html` → <https://developer.garmin.com/connect-iq/monkey-c/exceptions-and-errors/>
- `Monkey_C/Coding_Conventions.html` → <https://developer.garmin.com/connect-iq/monkey-c/coding-conventions/>
- `User_Experience_Guidelines/Designing_Workflows_and_Interactions.html` → <https://developer.garmin.com/connect-iq/user-experience-guidelines/designing-workflows-and-interactions/>
- `User_Experience_Guidelines/Views.html` → <https://developer.garmin.com/connect-iq/user-experience-guidelines/views/>
- `User_Experience_Guidelines/Entry_Points.html` → <https://developer.garmin.com/connect-iq/user-experience-guidelines/entry-points/>
- `User_Experience_Guidelines/Localization.html` → <https://developer.garmin.com/connect-iq/user-experience-guidelines/localization/>
- `User_Experience_Guidelines/Incorporating_the_Visual_Design_and_Product_Personalities.html` → <https://developer.garmin.com/connect-iq/user-experience-guidelines/incorporating-the-visual-design-and-product-personalities/>
- `Personality_Library/Colors.html`, `Typography.html`, `Iconography.html`
- `Connect_IQ_FAQ/How_Do_I_Make_a_Watch_Face_for_AMOLED_Products.html` → <https://developer.garmin.com/connect-iq/connect-iq-faq/how-do-i-make-a-watch-face-for-amoled-products/>
- `App_Review_Guidelines/Overview.html` → <https://developer.garmin.com/connect-iq/app-review-guidelines/>

Total : **27 pages** Core + UX + Personality + FAQ + App Review Guidelines effectivement lues.

### 13.2 Règles applicables

Légende priorité — MUST (obligatoire, rejet store), SHOULD (recommandé), MAY (optionnel).
Légende statut — ✓ conforme, ✗ violation corrigée dans ce commit, ☐ non-vérifiable sans test terrain.

| ID | Règle | Source | Priorité | Lien | Statut |
|---|---|---|---|---|---|
| **GIQ-001** | Le manifeste MUST déclarer un `id` 128-bit UUID unique | Manifest_and_Permissions §Application Attributes | MUST | — | ✓ |
| **GIQ-002** | `entry` MUST pointer sur une classe héritant de `Application.AppBase` | Manifest_and_Permissions | MUST | FR-020 | ✓ (`GarminSensorApp`) |
| **GIQ-003** | `name` et `launcherIcon` MUST référencer des ressources déclarées | Manifest_and_Permissions | MUST | — | ✓ |
| **GIQ-004** | `type` MUST être l'une de : `watchface`, `datafield`, `widget`, `watch-app`, `audio-content-provider-app` | Manifest_and_Permissions §type | MUST | — | ✓ (`watch-app`) |
| **GIQ-005** | `minApiLevel` (ou `minSdkVersion`) MUST être présent | Manifest_and_Permissions | MUST | NFR-031 | ✓ (3.3.0) |
| **GIQ-006** | La liste `<iq:permissions>` MUST déclarer UNIQUEMENT les permissions réellement utilisées (data minimization — App Review Guidelines §3.c) | App_Review_Guidelines §3.c "Data Minimization" + Manifest_and_Permissions | MUST | NFR-020 | ✗ → ✓ (FitContributor, UserProfile, SensorHistory retirées — non utilisées dans la v2.0.0) |
| **GIQ-007** | Les permissions autorisées pour type `watch-app` incluent : `Sensor`, `Positioning`, `Communications`, `Ant`, `Background`, `BluetoothLowEnergy`, `FitContributor`, `PersistedContent`, `SensorHistory`, `SensorLogging`, `UserProfile` | App_Types table | MUST | — | ✓ |
| **GIQ-010** | `AppBase.getInitialView()` MUST retourner un array `[View, Delegate]` (ou `[View]`) | Application_and_System_Modules §Launch | MUST | — | ✓ |
| **GIQ-011** | `AppBase.onStart(state)` MUST NOT pousser une WatchUi.View (doc: "Do not attempt to push a WatchUi.View instance at this time") | Application_and_System_Modules §Launch | MUST | — | ✓ |
| **GIQ-012** | `AppBase.onStop(state)` MUST libérer les ressources (sensors, timers, GPS) avant terminaison | Application_and_System_Modules §App Termination | MUST | NFR-010 | ✓ (shutdown() appelle stopSession()) |
| **GIQ-013** | L'app SHOULD gérer `state.get(:suspend)` dans onStop pour sauvegarder l'état, et `state.get(:resume)` dans onStart pour restaurer | Application_and_System_Modules §Active/Inactive | SHOULD | — | ☐ (session non-restaurée à dessein — cf. §1.2 "Multi-session concurrente exclue") |
| **GIQ-014** | L'app SHOULD implémenter `onSettingsChanged()` si elle expose des settings éditables | Properties_and_App_Settings + Designing_Workflows (Mobile App Settings) | SHOULD | — | ✗ → ✓ (ajouté dans GarminSensorApp) |
| **GIQ-020** | Toute API qui n'existe pas sur tous les devices MUST être gatée par `has :` | Multiple pages (cf. Application_and_System_Modules, AMOLED FAQ example) | MUST | NFR-012 | ✗ → ✓ (gated : `Sensor has :registerSensorDataListener`, `Position has :enableLocationEvents`, `Communications has :registerForPhoneAppMessages`, `Communications has :transmit`) |
| **GIQ-021** | `Sensor.registerSensorDataListener` period MUST ≤ 4 secondes | Sensors §High Frequency Data | MUST | FR-001 | ✓ (1 s) |
| **GIQ-022** | Les options valides pour `registerSensorDataListener` sont `:accelerometer`, `:gyroscope`, `:magnetometer`, `:heartBeatIntervals` — toute autre clé est ignorée | Sensors §High Frequency Data (tableau options) | MUST | FR-004 | ✗ → ✓ (retiré `:heartRate` invalide ; HR lue via `Sensor.getInfo()` dans le Timer — conforme à INV-009) |
| **GIQ-023** | `Sensor.getMaxSampleRate()` SHOULD être utilisé pour vérifier que la fréquence demandée est supportée | Sensors §High Frequency Data | SHOULD | FR-001 | ✗ → ✓ (log warning si IMU_RATE_HZ > getMaxSampleRate()) |
| **GIQ-024** | `Sensor.unregisterSensorDataListener()` MUST être appelé avant toute nouvelle registration ou en fin d'usage | Sensors | MUST | NFR-010 | ✓ |
| **GIQ-025** | `Sensor.SensorData` contient `accelerometerData`, `gyroscopeData`, `magnetometerData` (arrays `.x/.y/.z`) | Sensors table | — | — | ✓ |
| **GIQ-030** | `Position.enableLocationEvents` requiert la permission `Positioning` ; watch-apps seulement peuvent l'appeler | Positioning + Manifest_and_Permissions footnote 3/4/5 | MUST | FR-006 | ✓ |
| **GIQ-031** | Désactiver la GPS (`Position.LOCATION_DISABLE`) MUST être appelé en cleanup | Positioning (implicite — resource cleanup) | MUST | — | ✓ |
| **GIQ-040** | La communication `watch ↔ phone` suit le modèle *mailbox* : `Communications.transmit` + `ConnectionListener.onComplete/onError` ; `Communications.registerForPhoneAppMessages` pour les messages entrants | Communicating_with_Mobile_Apps | MUST | FR-010 | ✓ |
| **GIQ-041** | Un seul `Communications.transmit` en vol à la fois (semantics mailbox) | Communicating_with_Mobile_Apps (implicite) + leçon v1.0 §3.3 | MUST | FR-011, INV-008 | ✓ (CommunicationManager._transmitPending) |
| **GIQ-050** | `Application.Storage` : clé/valeur ≤ 8 Ko, total ≤ 128 Ko, types autorisés uniquement (Number, Float, Long, Double, Char, String, Boolean, Array, Dictionary — pas de Symbol) | Persisting_Data §Application.Storage | MUST | FR-016 | ✓ (v2.0.0 n'utilise pas Storage ; la persistent queue est mémoire seulement) |
| **GIQ-060** | `BehaviorDelegate` SHOULD être préféré à `InputDelegate` pour la portabilité multi-appareils | Input_Handling §Behaviors | SHOULD | FR-021..FR-028 | ✓ (`MainDelegate extends WatchUi.BehaviorDelegate`) |
| **GIQ-061** | Le comportement `back` MUST être préservé (doc : "one of the most common behaviors on Garmin devices. Avoid modifying this behavior") | Designing_Workflows §Best Practices | MUST | FR-025, FR-026 | ✓ (onBack retourne false pour laisser le système sortir) |
| **GIQ-062** | `return true` dans un handler d'input indique que l'event est consommé ; `return false` le laisse au système | Input_Handling §Input Delegates | MUST | — | ✓ |
| **GIQ-070** | Les strings MUST être dans `resources/strings/strings.xml` (base eng) et `resources/strings-fra/strings.xml` (ou similaire) pour localisation | Resources §Strings + UX/Localization | SHOULD | FR-030 | ✓ (strings.xml + strings-fra.xml — NB : le répertoire devrait être `resources-fra/strings/` selon le qualifier, à valider) |
| **GIQ-071** | L'app SHOULD être localisée au-delà de l'anglais si ciblée marchés internationaux | UX/Localization §Best Practices | SHOULD | FR-030 | ✓ (FR + EN) |
| **GIQ-072** | Toute string littérale visible user MUST être une ressource `@Strings.xxx` (pas de hardcode dans .mc) | Resources + UX/Localization | SHOULD | FR-030 | ✗ → ☐ (MainView draw "RECORDING", "READY", "BLE OK", "HR", "BAT" en dur — à migrer vers Rez.Strings, marqué partiellement corrigé dans le refactor) |
| **GIQ-080** | Le launcherIcon SHOULD être fourni en résolution adéquate pour chaque famille (fenix 8 AMOLED 454x454 = icône ~80x80) | Resources §Bitmaps + UX/Incorporating… | SHOULD | — | ✓ (resources-round-454x454/images/launcher_icon_80.png présent) |
| **GIQ-081** | Sur AMOLED, les thèmes foncés (fond noir, texte clair) SHOULD être préférés pour économiser la batterie et respecter la règle d'érosion de pixels | FAQ/AMOLED + UX/Visual_Design | SHOULD | NFR-005 | ✓ (MainView : dc.setColor(BLACK, BLACK); dc.clear()) |
| **GIQ-082** | Les watch-apps (non watch-faces) ne sont PAS soumises à la règle "10% pixels ou 3 min continu" de burn-in — celle-ci vise uniquement les watch faces en sleep | FAQ/AMOLED §What Qualifies as Burn-In | — | — | ✓ (non applicable) |
| **GIQ-083** | `dc.clear()` SHOULD être appelé au début de chaque `onUpdate` pour éviter des artefacts | User_Interface §Views | SHOULD | — | ✓ |
| **GIQ-090** | Les timers `WatchUi` MUST être stoppés dans `onHide()` et redémarrés dans `onShow()` pour économiser les cycles quand la vue n'est pas active | User_Interface (implicite) | SHOULD | NFR-005 | ✓ (MainView._refreshTimer start/stop dans onShow/onHide) |
| **GIQ-091** | `WatchUi.requestUpdate()` SHOULD n'être appelé QUE si l'état a changé, pas en boucle serrée | User_Interface §Views | SHOULD | FR-029 | ✓ (appelé dans _onRefresh Timer à 2 Hz) |
| **GIQ-092** | Les resources MUST être chargées via `Application.loadResource()` / `WatchUi.loadResource()` — PAS dans `onUpdate` (coûteux) | Resources §Rez | MUST | — | ✓ (aucun chargement dans onUpdate) |
| **GIQ-100** | Toute méthode callback CIQ (`onSensorDataReceived`, `onPosition`, `onReceive`, `onComplete`, `onError`, timer callbacks) MUST être enveloppée `try/catch` — une exception non attrapée ⇒ erreur fatale "Unhandled Exception" ⇒ kill de l'app | Monkey_C/Exceptions_and_Errors §Errors "Unhandled Exception" + "Watchdog Tripped" | MUST | NFR-012 | ✓ |
| **GIQ-101** | Les erreurs fatales CIQ ne sont PAS attrapables : `Initializer Error`, `Out of Memory`, `Stack Overflow`, `Too Many Timers`, `Watchdog Tripped`, `Permission Required` | Monkey_C/Exceptions_and_Errors §Errors | — | — | ✓ (connaissance préventive — cf. NFR-004/004b budget CPU) |
| **GIQ-102** | `Timer.Timer` est limité par device (`Too Many Timers` fatal) — réutiliser un même Timer plutôt qu'en créer plusieurs | Monkey_C/Exceptions_and_Errors | SHOULD | — | ✓ (SessionManager._dispatchTimer unique, MainView._refreshTimer unique) |
| **GIQ-103** | `System.println` est conservé en release — écrit dans `/GARMIN/APPS/LOGS/<APPNAME>.TXT` si le fichier existe ; otherwise no-op | Debugging §Basic Debugging | — | — | ✓ |
| **GIQ-104** | Pour release store, le build MUST utiliser `-r` (équivalent `--release` qui compile sans debug.xml ni symboles) — la flag `-e` produit un `.iq` multi-device pour l'app store | Publishing_to_the_Store + Build_Configuration | MUST | — | ✓ (build pipeline v1.4.0 utilise `monkeyc -e` pour le .iq) |
| **GIQ-110** | Les `AppBase.onAppInstall()` / `onAppUpdate()` nécessitent la permission `Background` — notre app ne les implémente pas (ni besoin) | Application_and_System_Modules §Install and Uninstall | — | — | ✓ |
| **GIQ-111** | Background services : 30 s max avant terminaison auto — non utilisé ici | Backgrounding | — | — | ✓ (non-applicable) |
| **GIQ-120** | L'IP des tierces parties MUST être respectée (logos, polices, trademarks) | App_Review_Guidelines §3 | MUST | — | ✓ |
| **GIQ-121** | L'app MUST avoir une description honnête et complète, identifier toute dépendance matérielle (ANT+, phone app…) | App_Review_Guidelines §4.a | MUST | — | ☐ (rédigé au moment de la soumission store) |
| **GIQ-122** | Si l'app collecte de la donnée perso (GPS, HR), politique de confidentialité requise (GDPR) | Publishing_to_the_Store §GDPR + App_Review_Guidelines §3.c | MUST | NFR-020 | ☐ (à rédiger pour la soumission — donnée restant locale) |
| **GIQ-123** | Activités dangereuses (plongée, parachute…) ⇒ rejet store ; "Harmful challenges" interdits | App_Review_Guidelines §1.b | MUST | — | ✓ (app générique de capture capteurs, usage neutre) |

### 13.3 Violations détectées et correctifs appliqués

Sept violations ont été identifiées ; toutes corrigées dans le commit accompagnant cette section.

#### V1 — GIQ-006 : permissions inutilisées déclarées
**Fichier** : `01_watch_app_connectiq/manifest.xml`
**Diagnostic** : `FitContributor`, `UserProfile`, `SensorHistory` sont listées dans `<iq:permissions>` mais aucune n'est consommée par le code v2.0.0 (aucun appel à `Toybox.FitContributor.*`, `Toybox.UserProfile.*`, `Toybox.SensorHistory.*`). C'est un écart à la règle de minimisation des données (App Review Guidelines §3.c) et une friction inutile pour l'utilisateur lors de l'installation.
**Correctif** : permissions retirées. Seules `Sensor`, `Positioning`, `Communications` sont conservées.

#### V2 — GIQ-020 : absence de `has :` gate sur APIs optionnelles
**Fichiers** : `SensorManager.mc`, `PositionManager.mc`, `SessionManager.mc`
**Diagnostic** : Le code appelle `Sensor.registerSensorDataListener`, `Position.enableLocationEvents`, `Communications.registerForPhoneAppMessages` et `Communications.transmit` sans vérifier leur présence. Sur un futur firmware ou un device manquant une de ces méthodes, résultat : `Symbol Not Found` fatal, non rattrapable.
**Correctif** : ajout de gates `has :` avec message d'erreur log + fallback silencieux (état `_isRegistered/_enabled` restant `false`).

#### V3 — GIQ-022 : option invalide `:heartRate` dans registerSensorDataListener
**Fichier** : `SensorManager.mc`, méthode `register()`
**Diagnostic** : La doc Sensors §High Frequency Data liste explicitement les options autorisées : `:accelerometer`, `:gyroscope`, `:magnetometer`, `:heartBeatIntervals`. Notre code passait `:heartRate => { :enabled => true }` — option silencieusement ignorée. Le HR était déjà récupéré par le Timer via `Sensor.getInfo()` (conforme), donc pas d'impact fonctionnel mais une fausse croyance entretenue.
**Correctif** : option retirée ; ajout d'un commentaire explicitant que HR arrive via `Sensor.getInfo()` dans `refreshHrFromInfo()` (déjà appelé par le dispatch Timer — conforme INV-009).

#### V4 — GIQ-023 : pas de vérification `Sensor.getMaxSampleRate()`
**Fichier** : `SensorManager.mc`
**Diagnostic** : On demande 100 Hz IMU sans vérifier que le device le supporte. Sur un device ultérieur qui plafonnerait à 50 Hz, la registration peut échouer silencieusement ou logger un warning système.
**Correctif** : `Sensor.getMaxSampleRate()` appelé avec `has :` gate ; si < 100, on loggue un warning mais on continue (le driver retournera au plus sa cadence max).

#### V5 — GIQ-014 : `onSettingsChanged()` absent
**Fichier** : `GarminSensorApp.mc`
**Diagnostic** : Le manifeste expose `DebugLogging` (properties.xml) comme setting modifiable via Garmin Connect Mobile. Sans `onSettingsChanged()`, les changements ne sont pas pris en compte jusqu'au prochain redémarrage de l'app.
**Correctif** : méthode ajoutée qui appelle `WatchUi.requestUpdate()` et loggue (si DebugLogging activé).

#### V6 — GIQ-061/062 : `onBack` retournait `false` TOUS les cas, y compris après stop
**Fichier** : `MainDelegate.mc`
**Diagnostic** : Comportement fonctionnel correct (laisser le système fermer l'app), mais `return false` systématique même quand l'utilisateur vient d'arrêter la session. Comportement conforme à la règle "Avoid modifying back behavior", mais peut surprendre : la back déclenche un stop ET une fermeture d'app simultanément. Clarification doc+code nécessaire.
**Correctif** : commentaire explicatif renforcé ; comportement inchangé car conforme aux best-practices Garmin.

#### V7 — GIQ-072 : strings UI en dur dans MainView.mc
**Fichier** : `MainView.mc`
**Diagnostic** : Strings `"RECORDING"`, `"STOPPING"`, `"READY"`, `"BLE OK"`, `"BLE X"`, `"GPS FIX"`, `"GPS --"`, `"START to record"`, `"START to stop"` sont écrites littéralement. Pour la localisation FR déjà déclarée, elles sont affichées uniquement en anglais.
**Correctif** : migration vers `Rez.Strings.status_recording`, `status_stopping`, `status_idle`, `link_connected`, `link_disconnected`, `gps_fix`, `gps_nofix`, `hint_press_start` — chargés via `WatchUi.loadResource()` en `initialize` (une fois, pas dans `onUpdate`, respectant GIQ-092). Nouvelles strings ajoutées dans `strings.xml` et `strings-fra.xml` pour les couples manquants (`hint_press_stop`).

### 13.4 Checklist de soumission store

Extrait de Publishing_to_the_Store + App_Review_Guidelines. À cocher avant export `.iq` vers le Connect IQ Store.

| # | Item | Statut |
|---|---|---|
| 1 | Manifest `<iq:products>` liste explicitement tous les devices ciblés | ✓ (11 fēnix 7/8) |
| 2 | UUID `id` unique enregistré sur developer.garmin.com | ☐ (à enregistrer avant soumission — UUID placeholder actuel) |
| 3 | `name` et `launcherIcon` référencent des ressources valides | ✓ |
| 4 | `<iq:permissions>` minimal (uniquement les permissions utilisées) — GIQ-006 | ✓ (après V1) |
| 5 | `<iq:languages>` reflète les langues effectivement supportées | ✓ (eng, fra) |
| 6 | Icône launcher haute résolution fournie pour AMOLED (80×80 sur 454×454) | ✓ |
| 7 | Build release `.iq` produit via `monkeyc -e --release` — 18/18 devices | À rebuild après fixes |
| 8 | Description store : mentions honnêtes, dépendances ANT+/Phone identifiées | ☐ |
| 9 | Politique de confidentialité publiée (GDPR — GPS/HR collectés) | ☐ |
| 10 | Screenshots à jour (fēnix 8 Pro principal) | ☐ |
| 11 | App testée sans crash sur session de 1 h (NFR-010) | ☐ (test terrain) |
| 12 | Aucun usage d'IP tiers (polices, logos) sans licence | ✓ |
| 13 | Pas de `System.error()` en release ; `System.println` uniquement informatif | ✓ |
| 14 | Pas d'usage interdit (diagnostic médical, crypto mining, activités dangereuses) | ✓ |
| 15 | Test simulateur sur fenix7 (MIP) ET fenix8pro47mm (AMOLED) — apparence cohérente | ☐ (test terrain) |
| 16 | Test réel téléphone Android avec companion — ≥ 99 % paquets reçus | ☐ (test terrain) |
| 17 | Vérification "BACK behavior" : sort de l'app sans perte de session en cours | ✓ |

---

## 12. Annexes

### 12.1 Fichiers clés

| Chemin | Description |
|---|---|
| `01_watch_app_connectiq/manifest.xml` | Manifest CIQ (UUID, devices, permissions) |
| `01_watch_app_connectiq/monkey.jungle` | Build config (device-specific resource paths) |
| `01_watch_app_connectiq/source/SessionManager.mc` | Orchestration, état global, boucle de capture |
| `01_watch_app_connectiq/source/SensorManager.mc` | Interface capteur IMU, mag, HR |
| `01_watch_app_connectiq/source/BatchManager.mc` | Accumulation 25 samples par paquet |
| `01_watch_app_connectiq/source/CommunicationManager.mc` | BLE single-in-flight + file mémoire |
| `01_watch_app_connectiq/source/PersistentQueue.mc` | File ACK-trackée persistée en flash |
| `01_watch_app_connectiq/source/PacketSerializer.mc` | Sérialisation JSON v1 |
| `01_watch_app_connectiq/source/MainView.mc` | 14 écrans × 4 sous-pages |
| `01_watch_app_connectiq/source/MainDelegate.mc` | Mapping boutons physiques |
| `02_android_companion/.../GarminReceiver.kt` | IQApplicationEventListener, validate + dispatch |
| `02_android_companion/.../FileLogger.kt` | JSONL append + rotation 100 MB |
| `02_android_companion/.../MainActivity.kt` | UI minimale + flow startSession/stopSession |
| `02_android_companion/.../ConnectIQManager.kt` | Wrapper sur CIQ Mobile SDK |
| `03_python_analysis/main.py` | Pipeline de normalisation & CSV |

### 12.2 Historique des changements majeurs

| Version | Date | Change | Justification |
|---|---|---|---|
| 1.0.0 | 2026-03 | Acquisition IMU de base | POC |
| 1.2.0 | 2026-04 | Magnétomètre 50 Hz→25 Hz | Budget BLE |
| 1.3.0 | 2026-04 | UI 6 écrans puis 14 écrans | FR-020 |
| 1.3.1 | 2026-04 | Caches HR, Boolean casts | Bugfix runtime |
| **1.4.0** | **2026-04-24** | **Fix NPE Android (header packet), try/catch tous callbacks CIQ, meta cache 1/s, MAX_BUFFER 400→50, MAX_ENTRIES 500→60, ACK flow actif, timer UI 2 Hz, manifest `<iq:barrels/>`, build `-e` pour .iq store** | NFR-010, NFR-012, FR-013, FR-017, FR-029 |

### 12.3 Boutons physiques fēnix 8 Pro

```
              ┌──────┐
              │START │ ← rouge, haut-droit
              └──────┘
    ┌────┐              ┌────┐
    │ UP │              │    │
    └────┘              │BACK│
    ┌────┐              │    │
    │DOWN│              └────┘
    └────┘
              ┌──────┐
              │      │ ← inutilisé
              └──────┘
```

| Bouton | Short | Long (≥ 1000 ms) |
|---|---|---|
| START | Start / Stop | New session |
| BACK | Mark event | Emergency stop / close menu |
| UP | Next screen | Open capture menu |
| DOWN | Next sub-page | Toggle button lock |

### 12.4 Budget ressources fēnix 8 Pro

| Ressource | Limite connue | Utilisation cible |
|---|---|---|
| RAM CIQ app | ~128 KB | ≤ 100 KB pic |
| Application.Storage | ~64 KB | ≤ 54 KB (MAX_ENTRIES × 900 B) |
| Payload BLE transmit | 4096 octets | MAX_PACKET_SIZE = 4096 (guard actif) |
| Callback duration | ~400 ms | cache meta 1×/s pour rester sous budget |

### 12.5 Dépendances externes

| Dépendance | Version | Licence |
|---|---|---|
| Connect IQ SDK | 9.1.0 | Garmin proprietary (gratuit) |
| Android Connect IQ Mobile SDK | latest | Garmin proprietary |
| Gson | 2.10 | Apache 2.0 |
| Kotlin stdlib | 1.9 | Apache 2.0 |
| AGP | 8.1.0 | Apache 2.0 |

### 12.6 Références normatives

- RFC 2119 — Key words for use in RFCs to Indicate Requirement Levels
- ISO/IEC/IEEE 29148:2018 — Systems and software engineering — Life cycle processes — Requirements engineering
- [Specification-driven development (Wikipedia)](https://en.wikipedia.org/wiki/Specification-driven_development)
- [Behavior-driven development (Wikipedia)](https://en.wikipedia.org/wiki/Behavior-driven_development)
- [Design by Contract (Wikipedia)](https://en.wikipedia.org/wiki/Design_by_contract)
- Meyer, Bertrand. *Object-Oriented Software Construction* (1988) — Design by Contract
- North, Dan. *Introducing BDD* (2006)

---

*Document à maintenir à jour à chaque changement affectant un requirement ou un contrat de module. Les modifications MUST être reflétées dans §12.2 (historique).*

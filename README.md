# GarminSensorCapture

**Version:** 1.0.0  
**Cible:** Garmin fēnix 8 Pro + Android + Python

Système complet de capture et d'analyse de données capteurs (IMU + GPS + FC) via Garmin fēnix 8 Pro, transport BLE vers Android, stockage JSONL, et pipeline d'analyse Python.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Garmin fēnix 8 Pro                                             │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Connect IQ App (Monkey C)                              │   │
│  │  SensorManager → BatchManager → PacketSerializer        │   │
│  │  PositionManager → CommunicationManager (BLE)           │   │
│  └──────────────────────────┬──────────────────────────────┘   │
└─────────────────────────────│───────────────────────────────────┘
                              │ BLE AppChannel
                              │ Protocol v1 JSON (25 samples/packet)
┌─────────────────────────────▼───────────────────────────────────┐
│  Android Smartphone                                             │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Kotlin Companion App                                   │   │
│  │  GarminReceiver → SessionManager → FileLogger (JSONL)   │   │
│  │  MainViewModel (StateFlow) → MainActivity (UI)          │   │
│  └──────────────────────────┬──────────────────────────────┘   │
└─────────────────────────────│───────────────────────────────────┘
                              │ Export (USB / Share)
                              │ *.jsonl
┌─────────────────────────────▼───────────────────────────────────┐
│  Python Analysis Pipeline                                       │
│  parser → normalizer → metrics → plotter → reporter            │
│  Output: CSV, JSON, PNG plots, summary.txt                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Structure du projet

```
GARMIN/
├── 01_watch_app_connectiq/   Application Monkey C (Connect IQ 6.x)
├── 02_android_companion/     Application Kotlin (Android API 26+)
├── 03_python_analysis/       Pipeline Python d'analyse
├── 04_docs/                  Documentation technique
├── 05_tests/                 Tests unitaires et plan de test
├── 06_release/               Notes de version, checklist, archivage
├── README.md                 Ce fichier
└── .gitignore
```

---

## Démarrage rapide

### 1. Pipeline Python (sans matériel)

```bash
cd 03_python_analysis
pip install -r requirements.txt
python main.py sample_data/sample_session.jsonl
```

### 2. Tests unitaires

```bash
cd D:/CLAUDE_PROJECTS/GARMIN
python -m pytest 05_tests/test_python/ -v
# Résultat attendu : 74 passed
```

### 3. Application montre

Voir `06_release/CHECKLIST_MISE_EN_ROUTE.md` et `04_docs/05_exploitation_guide.md`.

---

## Format des données de sortie

L'app Android produit **un fichier JSONL par session** (`{session_id}.jsonl`, exporté en `.zip` via le bouton "Export"). **Une ligne = un paquet** reçu de la montre via BLE.

### Exemple d'un paquet (abrégé)

```json
{
  "received_at": "2026-04-23T12:54:51.872Z",
  "session_id":  "20260423_125450",
  "pv":  1,
  "sid": "20260423_145435",
  "pi":  3,
  "dtr": 353029021,
  "s":   [ /* 25 samples IMU — voir plus bas */ ],
  "gps": { "lat": 48.8566, "lon": 2.3522, "alt": 35.0,
           "spd": 1.2, "hdg": 270.0, "acc": 5.0, "ts": 1713794022 },
  "meta": { "bat": 85, "temp": 22.5 },
  "ef":  0
}
```

### Champs au niveau du paquet

| Champ | Type | Unité | Description |
|-------|------|-------|-------------|
| `pv` | int | — | Protocol version (= 1) |
| `sid` | string | — | Session ID de la **montre** (`YYYYMMDD_HHMMSS`, heure locale montre) |
| `session_id` | string | — | Session ID **Android** (ajouté à la réception). Peut différer de `sid` à cause du fuseau horaire. |
| `pi` | int | — | Packet index monotone depuis le début de session. Des trous (`pi=3, pi=5, pi=6…`) révèlent les pertes BLE. |
| `dtr` | int | ms | Device timer = `System.getTimer()` sur la montre = ms depuis boot montre. **Pas un timestamp Unix.** |
| `received_at` | string | ISO 8601 UTC | Horloge wall-clock Android à la réception du paquet. À utiliser pour l'heure absolue. |
| `s` | array | — | Batch de samples IMU (25 éléments — voir table suivante) |
| `gps` | object / null | — | Snapshot GPS si fix valide ; absent si pas de fix ou fix trop ancien (> 5 s) |
| `meta` | object | — | Métadonnées système (batterie, température) |
| `ef` | int (bitmask) | — | Error flags : bit 0 sensor, bit 1 GPS, bit 2 buffer overflow, bit 3 partial batch, bit 4 clock skew, bit 5 comm retry |

### Samples IMU (`s[]`, 25 éléments par paquet)

| Champ | Type | Unité | Description |
|-------|------|-------|-------------|
| `t` | int | ms | **Période inter-sample** (40 = 25 Hz, 10 = 100 Hz). Constant sur tous les samples d'un batch. Timestamp absolu d'un sample #idx : `dtr + idx * t`. |
| `ax`, `ay`, `az` | float | milli-g | Accélération sur axes X/Y/Z. Gravité terrestre ≈ 1000 mg sur l'axe vertical (montre au repos, poignet à plat). |
| `gx`, `gy`, `gz` | float | °/s | Vitesse angulaire gyroscope sur X/Y/Z (~0 au repos). |
| `mx`, `my`, `mz` | float | µT | Champ magnétique magnétomètre sur X/Y/Z (microtesla). Sensible à l'orientation et aux perturbations métalliques. |
| `hr` | int | bpm | Fréquence cardiaque instantanée. Lue une seule fois par batch (~1 Hz effective) et **dupliquée** sur les 25 samples. |

### Snapshot GPS (`gps`, présent si fix valide)

| Champ | Type | Unité | Description |
|-------|------|-------|-------------|
| `lat` | float | degrés décimaux | Latitude (ex : 48.856614 pour Paris) |
| `lon` | float | degrés décimaux | Longitude (ex : 2.352222) |
| `alt` | float | m | Altitude au-dessus du niveau de la mer |
| `spd` | float | m/s | Vitesse au sol |
| `hdg` | float | ° (0-359) | Cap (heading), 0 = Nord |
| `acc` | float | m | Précision horizontale approximative : 5 m bonne, 15 m utilisable, 50 m mauvaise, 100 m non disponible |
| `ts` | int | secondes Unix | Timestamp du fix GPS (epoch) |

> ⚠️ **Bug v1.0.0** : le champ `alt` contient la valeur d'`acc` mappée (5/15/50/100) au lieu de l'altitude réelle, et `acc` est toujours 0. Corrigé dans la v1.1+.

### Métadonnées (`meta`)

| Champ | Type | Unité | Description |
|-------|------|-------|-------------|
| `bat` | int | % | Niveau de batterie montre (0-100) |
| `temp` | float | °C | Température capteur interne — optionnel, pas toujours présent |

### Fréquences d'acquisition

| Capteur | Fréquence hardware | Fréquence encodée (`t`) | Commentaire |
|---------|--------------------|-------------------------|-------------|
| Accéléromètre | 25 Hz (v1.0) / 100 Hz (v1.1+) | 40 / 10 ms | Via `Sensor.registerSensorDataListener` |
| Gyroscope | 25 Hz (v1.0) / 100 Hz (v1.1+) | 40 / 10 ms | Même batch que accel |
| Magnétomètre | 25 Hz (limite hardware) | 40 ms (v1.0) / répété 4× (v1.1+) | Sur fēnix, le mag ne monte pas au-dessus de 25 Hz |
| Fréquence cardiaque | ~1 Hz effective | dupliquée sur le batch | Poll `Sensor.getInfo().heartRate` 1× par batch |
| GPS | 1 Hz nominal, ~0.5 Hz effective | — | `LOCATION_CONTINUOUS`, fixes > 5 s rejetés |

### Pipeline d'analyse

Le fichier JSONL peut être traité par la pipeline Python (`03_python_analysis/main.py`) qui produit :
- **`imu_data.csv`** — une ligne par sample IMU, timestamps absolus reconstruits, accel converti en g
- **`gps_data.csv`** — une ligne par fix GPS
- **`metrics.json`** — durée, fréquence effective, taux de perte, statistiques (norm accel, plage HR, distance GPS)
- **`summary.txt`** — rapport lisible
- **`*.png`** — graphiques (accel XYZ, gyro XYZ, HR, trace GPS, profil altitude)

Voir [`04_docs/02_protocol_communication.md`](04_docs/02_protocol_communication.md) et [`04_docs/03_data_schema.md`](04_docs/03_data_schema.md) pour les détails d'implémentation et le schéma exact des DataFrames Python.

---

## Tests

| Composant | Tests | Type |
|-----------|-------|------|
| parser.py | 30 | Automatisé (pytest) |
| normalizer.py | 21 | Automatisé (pytest) |
| metrics.py | 23 | Automatisé (pytest) |
| Application montre | 4 | Manuel (simulateur/device) |
| Application Android | 4 | Manuel (device) |
| Intégration E2E | 2 | Manuel (device pair) |

---

## Documentation

| Document | Contenu |
|----------|---------|
| `04_docs/01_architecture.md` | Diagrammes d'architecture, flux de données |
| `04_docs/02_protocol_communication.md` | Protocole JSON v1, champs, error flags |
| `04_docs/03_data_schema.md` | Schéma JSONL, colonnes DataFrames |
| `04_docs/04_hypotheses.md` | Hypothèses techniques (H-001 à H-015) |
| `04_docs/05_exploitation_guide.md` | Guide de build, déploiement, analyse |
| `04_docs/06_troubleshooting.md` | Dépannage par symptôme |
| `05_tests/test_plan.md` | Plan de test, niveaux, critères |
| `05_tests/test_cases.md` | Cas de test détaillés |
| `05_tests/checklist_integration.md` | Checklist de validation complète |
| `06_release/RELEASE_NOTES_v1.0.0.md` | Notes de version |
| `06_release/CHECKLIST_MISE_EN_ROUTE.md` | Guide de mise en route |

---

## Limites connues

- Pas de capture en arrière-plan sur la montre (contrainte Connect IQ)
- Magnétomètre potentiellement indisponible en simulateur (H-005)
- GPS cold start : 1–15 minutes en extérieur
- Buffer limité à 100 paquets sur la montre (~180KB heap)
- Export Android non testé sur Android 14 (API 34)

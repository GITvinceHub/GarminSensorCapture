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

### Types de paquets (depuis v1.2.0)

Le flux JSONL contient **deux types de paquets** discriminés par le champ optionnel `pt` :

1. **Packet de données** (`pt` absent, ~1/sec par défaut) — un batch de samples IMU + meta enrichi. Format historique de protocol v1.
2. **Packet d'en-tête de session** (`pt: "header"`, un seul, `pi=0`) — profil utilisateur, info device, et historiques capteurs (HR, HRV, SpO2, stress, pression, température, élévation).

### Exemple — packet de données (abrégé)

```json
{
  "received_at": "2026-04-23T12:54:51.872Z",
  "session_id":  "20260423_125450",
  "pv":  1,
  "sid": "20260423_145435",
  "pi":  3,
  "dtr": 353029021,
  "s":   [ /* 25 samples IMU — voir plus bas */ ],
  "rr":  [812, 798, 825],
  "gps": { "lat": 48.8566, "lon": 2.3522, "alt": 35.0,
           "spd": 1.2, "hdg": 270.0, "acc": 5.0, "ts": 1713794022 },
  "meta": { "bat": 85, "spo2": 98, "spo2_age_s": 60,
            "pres_pa": 101325, "alt_baro_m": 35.2, "temp_c": 22.5,
            "cadence": 0, "heading_rad": 1.57,
            "resp": 14, "stress": 35, "body_batt": 75,
            "steps_day": 6500, "dist_day_m": 4200, "floors_day": 12 },
  "ef":  0
}
```

### Exemple — packet d'en-tête de session

```json
{
  "pv": 1,
  "pt": "header",
  "sid": "20260423_145435",
  "pi": 0,
  "dtr": 353028000,
  "user": { "weight_g": 75000, "height_cm": 180, "birth_year": 1990,
            "gender": "M" },
  "device": { "part_number": "006-B...", "firmware": "12.04",
              "monkey_version": "4.2.0", "app_version": "1.2.0" },
  "history": {
    "hr":       [[1713794022, 72], [1713793962, 70], ...],
    "hrv":      [[1713790000, 42], ...],
    "spo2":     [[1713790000, 98], ...],
    "stress":   [[1713790000, 35], ...],
    "pressure": [[1713790000, 101325], ...],
    "temp":     [[1713790000, 22.5], ...],
    "elev":     [[1713790000, 35.2], ...]
  }
}
```

Chaque entrée historique est `[ts_unix_s, value]`, tri **newest first**, **capped à 60 entrées par type** pour tenir dans la taille max de paquet BLE (4 KB). Pas suffisant ? Les historiques complets restent dispo sur la montre via `SensorHistory` — on peut les re-émettre périodiquement dans une future version.

### Champs au niveau du paquet (données)

| Champ | Type | Unité | Description |
|-------|------|-------|-------------|
| `pv` | int | — | Protocol version (= 1) |
| `pt` | string | — | Packet type : **absent** = packet de données ; `"header"` = en-tête de session |
| `sid` | string | — | Session ID de la **montre** (`YYYYMMDD_HHMMSS`, heure locale montre) |
| `session_id` | string | — | Session ID **Android** (ajouté à la réception). Peut différer de `sid` à cause du fuseau horaire. |
| `pi` | int | — | Packet index monotone depuis le début de session (0 pour le header). Des trous révèlent les pertes BLE. |
| `dtr` | int | ms | Device timer = `System.getTimer()` sur la montre = ms depuis boot montre. **Pas un timestamp Unix.** |
| `received_at` | string | ISO 8601 UTC | Horloge wall-clock Android à la réception du paquet. À utiliser pour l'heure absolue. |
| `s` | array | — | Batch de samples IMU (25 éléments — voir table suivante) |
| `rr` | array of int | ms | **RR intervals** du batch (1-3 valeurs par seconde typiquement). Pour analyse HRV. Absent si HR non disponible. |
| `gps` | object / null | — | Snapshot GPS si fix valide ; absent si pas de fix ou fix trop ancien (> 5 s) |
| `meta` | object | — | Métadonnées système enrichies (voir plus bas) |
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

### Métadonnées (`meta`) — enrichies en v1.2.0

Tous les champs sauf `bat` sont **optionnels** (absents si non disponibles sur ce device / non mesurés).

#### Toujours présent
| Champ | Type | Unité | Description |
|-------|------|-------|-------------|
| `bat` | int | % | Niveau de batterie montre (0-100) |

#### Capteurs continus (Sensor.getInfo — poll par batch)
| Champ | Type | Unité | Description |
|-------|------|-------|-------------|
| `pres_pa` | int | Pa | Pression barométrique absolue |
| `alt_baro_m` | float | m | Altitude barométrique (plus stable que GPS alt sur court terme) |
| `temp_c` | float | °C | Température capteur interne (**biais** : chaleur du poignet + processeur) |
| `cadence` | int | rpm | Cadence pas/min (marche/course) ou pédalage (vélo si paired). 0 si hors activité. |
| `power_w` | int | W | Puissance (vélo/running, si device supporté / capteur externe paired) |
| `heading_rad` | float | rad | Cap magnétique dérivé du magnétomètre |

#### Capteurs lents / ActivityMonitor (valeur + âge optionnel)
| Champ | Type | Unité | Description |
|-------|------|-------|-------------|
| `spo2` | int | % | Saturation en oxygène la plus récente connue (0-100) |
| `spo2_age_s` | int | s | Âge de la mesure `spo2` en secondes |
| `resp` | int | breaths/min | Fréquence respiratoire (dernière mesure) |
| `stress` | int | 0-100 | Niveau de stress Garmin (propriétaire, basé HRV) |
| `body_batt` | int | 0-100 | Body Battery Garmin (propriétaire, énergie physiologique) |
| `steps_day` | int | — | Pas cumulés depuis minuit (jour courant) |
| `dist_day_m` | int | m | Distance cumulée depuis minuit (jour courant) |
| `floors_day` | int | — | Étages montés depuis minuit (jour courant) |

> ℹ️ **Sur la SpO2, respiration, stress, body battery** : ces capteurs ne sont **pas continus**. Ils sont mesurés périodiquement (minutes) voire on-demand. Le champ reflète la dernière mesure connue, pas une valeur temps réel. Pour SpO2, activer "All-day Pulse Ox" dans les paramètres montre sinon la valeur date de la dernière mesure manuelle (possiblement heures/jours).

### En-tête de session (packet `pt: "header"`, envoyé 1× au start)

#### `user` — profil utilisateur (champs optionnels selon config Garmin Connect)
| Champ | Type | Unité | Description |
|-------|------|-------|-------------|
| `weight_g` | int | grammes | Poids utilisateur (typiquement 70000 = 70 kg) |
| `height_cm` | int | cm | Taille |
| `birth_year` | int | année | Année de naissance (pour calcul âge) |
| `gender` | string | — | `"M"` ou `"F"` |

#### `device` — info matériel et logiciel
| Champ | Type | Description |
|-------|------|-------------|
| `part_number` | string | Numéro de pièce Garmin (identifie le modèle précis) |
| `firmware` | string | Version firmware de la montre |
| `monkey_version` | string | Version Connect IQ runtime sur la montre |
| `app_version` | string | Version de l'app GarminSensorCapture (ex : `"1.2.0"`) |

#### `history` — historiques pré-session (max 60 entrées/type, newest first)
Chaque entrée : `[timestamp_unix_s, valeur]`. Les types disponibles :

| Clé | Unité | Description |
|-----|-------|-------------|
| `hr` | bpm | Historique fréquence cardiaque |
| `hrv` | ms (RMSSD) | Historique variabilité cardiaque |
| `spo2` | % | Historique SpO2 (sessions Pulse Ox manuelles ou All-day) |
| `stress` | 0-100 | Historique stress |
| `pressure` | Pa | Historique pression barométrique |
| `temp` | °C | Historique température capteur |
| `elev` | m | Historique élévation barométrique |

Les historiques peuvent être vides si la feature est désactivée sur la montre (ex : SpO2 sans All-day Pulse Ox).

### Fréquences d'acquisition

| Capteur | Fréquence hardware | Où dans le JSON | Commentaire |
|---------|--------------------|-----------------|-------------|
| Accéléromètre | 25 Hz (v1.0) / 100 Hz (v1.1+) | `s[].ax/ay/az` | Via `Sensor.registerSensorDataListener` |
| Gyroscope | 25 Hz (v1.0) / 100 Hz (v1.1+) | `s[].gx/gy/gz` | Même batch que accel |
| Magnétomètre | 25 Hz (limite hardware) | `s[].mx/my/mz` | Hold 4× sur samples primaires en v1.1+ |
| Fréquence cardiaque | ~1 Hz | `s[].hr` (dupliqué) | Poll `Sensor.getInfo().heartRate` 1× par batch |
| RR intervals | Par battement (~1-3/s) | `rr[]` niveau paquet | Extraits de `HeartRateData.heartBeatIntervals` (v1.2+) |
| GPS | 1 Hz nominal, ~0.5 Hz effective | `gps` | `LOCATION_CONTINUOUS`, fixes > 5 s rejetés |
| Pression barométrique | Polled ~1/sec | `meta.pres_pa` | `Sensor.Info.pressure` |
| Altitude barométrique | Polled ~1/sec | `meta.alt_baro_m` | `Sensor.Info.altitude` |
| Température interne | Polled ~1/sec | `meta.temp_c` | Biais thermique poignet/CPU |
| Cadence / Power / Heading | Polled ~1/sec | `meta.cadence`, `power_w`, `heading_rad` | Disponible selon contexte / capteurs externes |
| Respiration | Polled ~1/sec, valeur change ~1/min | `meta.resp` | `ActivityMonitor.Info.respirationRate` |
| Stress | Polled ~1/sec, valeur change ~3/min | `meta.stress` | Propriétaire Garmin |
| Body Battery | Polled ~1/sec, valeur change ~30/min | `meta.body_batt` | Propriétaire Garmin |
| SpO2 | On-demand / All-day (1/min max) | `meta.spo2` + `spo2_age_s` | Pulse Ox — voir notes |
| Steps/dist/floors | Polled ~1/sec, valeur change selon activité | `meta.steps_day`, `dist_day_m`, `floors_day` | Cumuls jour courant |
| **Historiques** (tous types) | Pré-session | `history.*` du packet header | Capped à 60 entrées/type |

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

# GarminSensorCapture — Python Analysis Pipeline

Pipeline d'analyse des données de capteurs Garmin. Prend en entrée un fichier JSONL produit par l'application Android et génère des métriques, graphiques, et rapports CSV/JSON.

## Prérequis

- Python 3.10 ou supérieur
- pip

## Installation

```bash
cd D:/CLAUDE_PROJECTS/GARMIN/03_python_analysis
pip install -r requirements.txt
```

### Packages installés
| Package | Version | Usage |
|---------|---------|-------|
| numpy | ≥1.24 | Calcul numérique |
| pandas | ≥2.0 | DataFrames |
| matplotlib | ≥3.7 | Visualisation |
| scipy | ≥1.11 | Traitement signal |
| pyarrow | ≥12.0 | Export Parquet (optionnel) |

## Usage

```bash
# Analyser le fichier d'exemple
python main.py sample_data/sample_session.jsonl

# Spécifier un répertoire de sortie
python main.py path/to/session.jsonl --output-dir ./output/session1

# Mode verbeux (logs DEBUG)
python main.py session.jsonl -v

# Sans génération de graphiques (plus rapide)
python main.py session.jsonl --no-plots
```

## Sorties générées

Dans le répertoire `--output-dir` (défaut: `./output`) :

```
output/
├── summary.txt           ← Rapport texte lisible humain
├── imu_data.csv          ← Données IMU complètes (une ligne par sample)
├── gps_data.csv          ← Données GPS (une ligne par fix)
├── metrics.json          ← Métriques numériques (machine-readable)
├── accelerometer_xyz.png ← Courbes ax, ay, az vs temps
├── gyroscope_xyz.png     ← Courbes gx, gy, gz vs temps
├── heart_rate.png        ← Fréquence cardiaque vs temps
├── gps_track.png         ← Tracé GPS lat/lon coloré par vitesse
├── altitude_profile.png  ← Profil altimétrique vs temps
└── sensor_overview.png   ← Dashboard multi-panneaux
```

## Structure des modules

```
modules/
├── __init__.py     ← Package init
├── parser.py       ← Lecture et validation JSONL
├── normalizer.py   ← Conversion unités, création DataFrames
├── metrics.py      ← Calcul métriques session
├── plotter.py      ← Génération graphiques PNG
└── reporter.py     ← Écriture CSV, JSON, summary.txt
```

### parser.py
- Lit le fichier JSONL ligne par ligne
- Valide les champs obligatoires (`pv`, `sid`, `pi`, `dtr`, `s`)
- Gère les erreurs JSON (lignes invalides ignorées avec warning)
- Retourne une liste de dicts validés

### normalizer.py
- Convertit les paquets bruts en DataFrames pandas
- Conversions d'unités : milli-g → g, secondes GPS → ms Unix
- Trie par timestamp, marque les doublons
- Interpolation linéaire des petits gaps (< 200ms)

### metrics.py
- Durée, fréquence réelle, comptage
- Estimation perte de paquets (gaps > 2× période nominale)
- Statistiques IMU : norme accéléromètre/gyroscope (mean/std/max)
- Statistiques FC : mean/min/max/std
- GPS : distance totale (Haversine), vitesse max, dénivelés
- Score qualité 0-100

### plotter.py
- Graphiques individuels (accel, gyro, HR, GPS, altitude)
- Dashboard multi-panneaux (sensor_overview.png)
- Backend Agg (non-interactif, compatible headless)

### reporter.py
- `summary.txt` : rapport lisible, aligné en colonnes
- `imu_data.csv` : DataFrame IMU complet
- `gps_data.csv` : DataFrame GPS complet
- `metrics.json` : métriques en JSON (avec gestion NaN → null)

## Format des données d'entrée

Chaque ligne du fichier JSONL est un paquet conforme au protocole v1 :

```json
{
  "received_at": "2024-04-22T14:30:22.000Z",
  "pv": 1,
  "sid": "20240422_143022",
  "pi": 0,
  "dtr": 1713794022000,
  "s": [{"t": 0, "ax": 15.0, "ay": -983.0, "az": 124.0,
          "gx": 0.5, "gy": -0.3, "gz": 0.1, "hr": 72}],
  "gps": {"lat": 48.8566, "lon": 2.3522, "alt": 35.0,
          "spd": 1.2, "hdg": 270.0, "acc": 5.0, "ts": 1713794022},
  "meta": {"bat": 85, "temp": 22.5},
  "ef": 0
}
```

Voir `04_docs/02_protocol_communication.md` pour la documentation complète.

## Exemple de sortie summary.txt

```
============================================================
  Garmin Sensor Capture — Session Report
============================================================
  Generated:  2024-04-22 14:31:05 UTC

── Session Info ─────────────────────────────────────────
  Session ID    : 20240422_143022
  Duration      : 9.00 s
  Start time    : 2024-04-22 14:30:22 UTC
  End time      : 2024-04-22 14:30:31 UTC

── IMU Data ─────────────────────────────────────────────
  Packets       : 10
  Samples       : 250
  Frequency     : 25.000 Hz  (nominal: 25 Hz)
  Packet loss   : 0.00 %
...
```

## Tests

```bash
cd D:/CLAUDE_PROJECTS/GARMIN
pip install pytest
python -m pytest 05_tests/test_python/ -v
```

## Dépannage

**ImportError: No module named 'numpy'**
```bash
pip install -r requirements.txt
```

**FileNotFoundError**
```bash
# Vérifier le chemin
python main.py sample_data/sample_session.jsonl
```

**Graphiques vides**
- Activer les logs verbeux : `python main.py session.jsonl -v`
- Vérifier que le JSONL contient des données valides

**Performance lente (> 30s pour < 100K lignes)**
- Utiliser `--no-plots` pour sauter les graphiques
- Vérifier que matplotlib et numpy sont à jour

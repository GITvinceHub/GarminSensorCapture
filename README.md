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

## Protocole

Chaque paquet BLE est un objet JSON v1 :

```json
{
  "pv": 1,
  "sid": "20240422_143022",
  "pi": 42,
  "dtr": 1713794022000,
  "s": [
    {"t": 0, "ax": 15.0, "ay": -983.0, "az": 124.0,
     "gx": 0.5, "gy": -0.3, "gz": 0.1, "hr": 72}
  ],
  "gps": {"lat": 48.8566, "lon": 2.3522, "alt": 35.0,
          "spd": 1.2, "hdg": 270.0, "acc": 5.0, "ts": 1713794022},
  "meta": {"bat": 85, "temp": 22.5},
  "ef": 0
}
```

Voir `04_docs/02_protocol_communication.md` pour la documentation complète.

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

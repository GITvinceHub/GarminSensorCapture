# Release Notes — v1.0.1 (patch)

**Date** : 2026-04-24
**Branche** : `rewrite/v2.0.0-from-spec`
**Précédente** : v1.0.0

---

## Bugs corrigés

### [BUG-001] Crash montre après ~8 paquets (~2 secondes d'enregistrement)

**Symptôme** : L'app passait en RECORDING, le compteur atteignait 8 paquets, le timer restait bloqué à 00:00:00, puis l'app se fermait et retournait au launcher Connect IQ.

**Cause** : À 100 Hz avec `Sensor.registerSensorDataListener({ :period => 1 })`, le runtime CIQ livre 100 samples par callback. La boucle `for i = 0; i < 100` appelait `BatchManager.accumulate()` 100 fois, déclenchant 4 dispatches de batch récursifs depuis l'intérieur du callback sensor. Après ~2s (32 dispatches accumulés), la pile CIQ et/ou le heap étaient épuisés.

**Fix** :
- `SensorManager.mc` : `PRIMARY_RATE_HZ` 100 → **25 Hz** (H-017)
- `SensorManager.mc` : `MAG_DOWNSAMPLE_RATIO` 4 → **1** (mag et IMU même rate)
- `SensorManager.mc` : `_measuredFrequency` initialisé à **0.0f**
- `ViewModel.mc` : diviseur `computeImuQuality` **100.0 → 25.0**

---

### [BUG-002] Valeurs live nulles avant l'enregistrement

**Symptôme** : Avant START, les écrans affichaient IMU 0%, GPS NO FIX, FC --- bpm — impossible de vérifier la qualité du signal.

**Cause** : Les capteurs et le GPS n'étaient enregistrés que dans `startSession()`. En état IDLE, aucune donnée live n'était disponible.

**Fix** :
- `SessionManager.mc` : `register()` + `enable()` déplacés dans `setup()` — live preview dès l'ouverture (H-018)
- `SessionManager.mc` : `stopSession()` ne désenregistre plus les capteurs — ils continuent après STOP
- `SessionManager.mc` : `startSession()` allégé — capteurs déjà actifs

---

## Fichiers modifiés

| Fichier | Type | Description |
|---------|------|-------------|
| `01_watch_app_connectiq/source/SensorManager.mc` | Bug fix | Rate 100→25 Hz, downsample 4→1, freq init 0.0f |
| `01_watch_app_connectiq/source/SessionManager.mc` | Bug fix | Live preview : sensors démarrés dans setup() |
| `01_watch_app_connectiq/source/ViewModel.mc` | Bug fix | Diviseur IMU quality 100→25 |
| `01_watch_app_connectiq/manifest.xml` | Version | 1.3.0 → 1.0.1 |
| `04_docs/04_hypotheses.md` | Doc | Ajout H-017, H-018 |
| `04_docs/06_troubleshooting.md` | Doc | Section 7 : BUG-001 et BUG-002 documentés |

---

## Risques résiduels introduits par ce patch

| Risque | Sévérité | Action |
|--------|----------|--------|
| Batterie IDLE + capteurs actifs : +3-5 %/h estimé (H-018) | Faible | Mesurer sur device réel |
| Fréquence réelle IMU à 25 Hz non confirmée sur fēnix 8 Pro (H-001/H-017) | Moyen | Lire `getMeasuredFrequency()` en log |

---

## Tests

- 77/77 tests Python passés (inchangés — patches côté montre uniquement)
- Tests montre : à effectuer sur fēnix 8 Pro physique (voir `05_tests/checklist_integration.md`)

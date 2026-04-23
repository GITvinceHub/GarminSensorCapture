# Schéma des données — Garmin Sensor Capture

## Vue d'ensemble

Ce document décrit le schéma complet des données à chaque étape du pipeline : format JSONL stocké par Android, tables Python reconstruites à partir des paquets.

---

## 1. Format JSONL Android

Chaque ligne du fichier `.jsonl` est un objet JSON correspondant à un paquet reçu, enrichi de métadonnées de réception.

### Structure d'une ligne JSONL

```json
{
  "received_at": "2024-04-22T14:30:22.543Z",
  "session_id": "20240422_143022_A1B2C3",
  "pv": 1,
  "sid": "20240422_143022_A1B2C3",
  "pi": 42,
  "dtr": 1713794022000,
  "s": [
    {"t": 0, "ax": 12.0, "ay": -983.0, "az": 124.0, "gx": 0.5, "gy": -0.3, "gz": 0.1, "mx": 22.5, "my": -15.3, "mz": 44.1, "hr": 72},
    {"t": 40, "ax": 15.0, "ay": -980.0, "az": 121.0, "gx": 0.6, "gy": -0.2, "gz": 0.2, "mx": 22.4, "my": -15.2, "mz": 44.0, "hr": 72}
  ],
  "gps": {"lat": 48.8566, "lon": 2.3522, "alt": 35.0, "spd": 1.2, "hdg": 270.0, "acc": 5.0, "ts": 1713794022},
  "meta": {"bat": 85, "temp": 22.5},
  "ef": 0
}
```

### Champs JSONL (ligne complète)

| Champ | Type JSON | Ajouté par | Description |
|-------|-----------|-----------|-------------|
| `received_at` | String (ISO8601) | Android | Timestamp de réception côté Android (UTC) |
| `session_id` | String | Android | Copie du sid pour indexation rapide |
| `pv` | Number | Montre | Version protocole |
| `sid` | String | Montre | Session ID |
| `pi` | Number | Montre | Index paquet |
| `dtr` | Number | Montre | Device time reference (Unix ms) |
| `s` | Array | Montre | Samples capteurs |
| `gps` | Object | Montre | Données GPS (peut être null) |
| `meta` | Object | Montre | Métadonnées (peut être null) |
| `ef` | Number | Montre | Error flags bitmask |

---

## 2. Table IMU (Python — `imu_df`)

Produite par `normalizer.py` à partir du champ `s` de chaque paquet. Chaque ligne correspond à un échantillon capteur individuel.

### Schéma de la table IMU

| Colonne | Type Python | Type pandas | Unité | Obligatoire | Description |
|---------|-------------|-------------|-------|-------------|-------------|
| `timestamp_ms` | int | int64 | ms Unix | OUI | `dtr + t` (temps absolu de l'échantillon) |
| `session_id` | str | object | - | OUI | Session ID |
| `packet_index` | int | int64 | - | OUI | Index du paquet source (`pi`) |
| `sample_index` | int | int64 | - | OUI | Index de l'échantillon dans le paquet |
| `ax_g` | float | float64 | g | OUI | Accélération X (milli-g / 1000) |
| `ay_g` | float | float64 | g | OUI | Accélération Y (milli-g / 1000) |
| `az_g` | float | float64 | g | OUI | Accélération Z (milli-g / 1000) |
| `gx_dps` | float | float64 | deg/s | OUI | Vitesse angulaire X |
| `gy_dps` | float | float64 | deg/s | OUI | Vitesse angulaire Y |
| `gz_dps` | float | float64 | deg/s | OUI | Vitesse angulaire Z |
| `mx_uT` | float | float64 | µT | NON | Champ magnétique X (0.0 si absent) |
| `my_uT` | float | float64 | µT | NON | Champ magnétique Y |
| `mz_uT` | float | float64 | µT | NON | Champ magnétique Z |
| `hr_bpm` | float | float64 | bpm | NON | Fréquence cardiaque (NaN si 0 ou absent) |
| `received_at` | str | object | ISO8601 | OUI | Timestamp réception Android |
| `is_duplicate` | bool | bool | - | OUI | True si timestamp_ms dupliqué |
| `interpolated` | bool | bool | - | OUI | True si échantillon interpolé |

### Conversions d'unités IMU

| Capteur | Unité source (montre) | Unité cible (Python) | Formule |
|---------|----------------------|---------------------|---------|
| Accéléromètre | milli-g | g | `valeur / 1000` |
| Gyroscope | deg/s | deg/s | *identique* |
| Gyroscope (optionnel) | deg/s | rad/s | `valeur × π/180` |
| Magnétomètre | µT | µT | *identique* |
| FC | bpm | bpm | *identique* ; 0 → NaN |

### Valeurs par défaut IMU

| Colonne | Valeur si absent/invalide |
|---------|--------------------------|
| `mx_uT`, `my_uT`, `mz_uT` | 0.0 |
| `hr_bpm` | NaN |
| `interpolated` | False |
| `is_duplicate` | False |

---

## 3. Table GPS (Python — `gps_df`)

Produite par `normalizer.py` à partir du champ `gps` de chaque paquet. Une ligne par paquet GPS valide.

### Schéma de la table GPS

| Colonne | Type Python | Type pandas | Unité | Obligatoire | Description |
|---------|-------------|-------------|-------|-------------|-------------|
| `timestamp_ms` | int | int64 | ms Unix | OUI | `ts × 1000` (GPS epoch → ms) |
| `session_id` | str | object | - | OUI | Session ID |
| `packet_index` | int | int64 | - | OUI | Index paquet source |
| `lat_deg` | float | float64 | degrés | OUI | Latitude WGS84 |
| `lon_deg` | float | float64 | degrés | OUI | Longitude WGS84 |
| `alt_m` | float | float64 | mètres | NON | Altitude MSL (NaN si absent) |
| `speed_ms` | float | float64 | m/s | NON | Vitesse sol (NaN si absent) |
| `heading_deg` | float | float64 | degrés | NON | Cap (NaN si absent) |
| `accuracy_m` | float | float64 | mètres | NON | Précision horizontale (NaN si absent) |
| `received_at` | str | object | ISO8601 | OUI | Timestamp réception Android |
| `is_duplicate` | bool | bool | - | OUI | True si timestamp_ms dupliqué |

### Conversions GPS

| Champ | Traitement |
|-------|------------|
| `lat`, `lon` | Arrivée en degrés depuis PositionManager (conversion radians→degrés effectuée sur montre) |
| `ts` (Unix s) → `timestamp_ms` | Multiplier par 1000 |
| `alt` absent | NaN |
| `spd` absent | NaN |
| `hdg` absent | NaN |
| `acc` absent | NaN |

### Valeurs par défaut GPS

| Colonne | Valeur si absent |
|---------|-----------------|
| `alt_m` | NaN |
| `speed_ms` | NaN |
| `heading_deg` | NaN |
| `accuracy_m` | NaN |

---

## 4. Table métriques (Python — `metrics` dict)

Produite par `metrics.py`. Exportée dans `metrics.json`.

### Clés du dictionnaire metrics

| Clé | Type | Unité | Description |
|-----|------|-------|-------------|
| `session_id` | str | - | Session ID |
| `duration_s` | float | s | Durée totale session |
| `sample_count` | int | - | Nombre d'échantillons IMU valides |
| `actual_frequency_hz` | float | Hz | Fréquence réelle mesurée |
| `nominal_frequency_hz` | float | Hz | Fréquence nominale (25 Hz) |
| `packet_count` | int | - | Nombre de paquets parsés |
| `packet_loss_estimate` | float | % | Estimation perte (gaps > 2×période) |
| `acc_norm_mean` | float | g | Moyenne norme accélération |
| `acc_norm_std` | float | g | Écart-type norme accélération |
| `acc_norm_max` | float | g | Maximum norme accélération |
| `gyro_norm_mean` | float | deg/s | Moyenne norme gyroscope |
| `gyro_norm_std` | float | deg/s | Écart-type norme gyroscope |
| `gyro_norm_max` | float | deg/s | Maximum norme gyroscope |
| `hr_mean` | float | bpm | FC moyenne |
| `hr_min` | float | bpm | FC minimum |
| `hr_max` | float | bpm | FC maximum |
| `hr_std` | float | bpm | FC écart-type |
| `hr_samples` | int | - | Nombre de samples FC valides |
| `gps_sample_count` | int | - | Nombre de fixes GPS |
| `gps_distance_m` | float | m | Distance GPS totale |
| `gps_max_speed_ms` | float | m/s | Vitesse GPS maximale |
| `altitude_gain_m` | float | m | Dénivelé positif |
| `altitude_loss_m` | float | m | Dénivelé négatif |
| `data_quality_score` | float | 0-100 | Score qualité global |

---

## 5. Fichiers de sortie Python

| Fichier | Format | Contenu |
|---------|--------|---------|
| `imu_data.csv` | CSV avec header | Table IMU complète |
| `gps_data.csv` | CSV avec header | Table GPS complète |
| `metrics.json` | JSON | Dictionnaire métriques |
| `summary.txt` | Texte lisible | Rapport humain |
| `accelerometer_xyz.png` | PNG (DPI 150) | Courbes ax, ay, az |
| `gyroscope_xyz.png` | PNG (DPI 150) | Courbes gx, gy, gz |
| `heart_rate.png` | PNG (DPI 150) | Série temporelle FC |
| `gps_track.png` | PNG (DPI 150) | Tracé GPS coloré par vitesse |
| `altitude_profile.png` | PNG (DPI 150) | Profil altimétrique |
| `sensor_overview.png` | PNG (DPI 150) | Dashboard multi-capteurs |

# Protocole de Communication — Garmin → Android (v1.0)

## Vue d'ensemble

Le protocole définit le format des paquets JSON transmis via Bluetooth LE entre l'application Connect IQ (montre) et l'application Android compagnon. La version actuelle est **v1.0**.

---

## Format de paquet

### Structure complète

```json
{
  "pv": 1,
  "sid": "20240422_143022_A1B2C3",
  "pi": 42,
  "dtr": 1713794022000,
  "s": [
    {
      "t": 0,
      "ax": 0.012,
      "ay": -0.983,
      "az": 0.124,
      "gx": 0.5,
      "gy": -0.3,
      "gz": 0.1,
      "mx": 22.5,
      "my": -15.3,
      "mz": 44.1,
      "hr": 72
    }
  ],
  "gps": {
    "lat": 48.8566,
    "lon": 2.3522,
    "alt": 35.0,
    "spd": 1.2,
    "hdg": 270.0,
    "acc": 5.0,
    "ts": 1713794022
  },
  "meta": {
    "bat": 85,
    "temp": 22.5
  },
  "ef": 0
}
```

---

## Description des champs

### Champs racine (obligatoires)

| Champ | Clé JSON | Type | Obligatoire | Description |
|-------|----------|------|-------------|-------------|
| Protocol Version | `pv` | Integer | OUI | Version du protocole (actuellement : 1) |
| Session ID | `sid` | String | OUI | Identifiant unique de session (format : YYYYMMDD_HHMMSS_deviceId) |
| Packet Index | `pi` | Long | OUI | Index du paquet dans la session (commence à 0, incrémental) |
| Device Time Reference | `dtr` | Long | OUI | Timestamp Unix milliseconds de la montre au moment de la sérialisation |
| Samples | `s` | Array | OUI | Tableau des échantillons capteurs (1 à 25 éléments) |

### Champs racine (optionnels)

| Champ | Clé JSON | Type | Obligatoire | Description |
|-------|----------|------|-------------|-------------|
| GPS Data | `gps` | Object | NON | Données GPS (absent si pas de fix) |
| Metadata | `meta` | Object | NON | Métadonnées appareil |
| Error Flags | `ef` | Integer | NON | Bitmask des erreurs (défaut : 0) |

---

### Objet Sample (`s[i]`)

| Champ | Clé | Type | Obligatoire | Unité | Description |
|-------|-----|------|-------------|-------|-------------|
| Time Offset | `t` | Long | OUI | ms | Offset depuis `dtr` (premier sample = 0) |
| Accel X | `ax` | Float | OUI | milli-g | Accélération axe X |
| Accel Y | `ay` | Float | OUI | milli-g | Accélération axe Y |
| Accel Z | `az` | Float | OUI | milli-g | Accélération axe Z |
| Gyro X | `gx` | Float | OUI | deg/s | Vitesse angulaire axe X |
| Gyro Y | `gy` | Float | OUI | deg/s | Vitesse angulaire axe Y |
| Gyro Z | `gz` | Float | OUI | deg/s | Vitesse angulaire axe Z |
| Mag X | `mx` | Float | NON | µT | Champ magnétique axe X |
| Mag Y | `my` | Float | NON | µT | Champ magnétique axe Y |
| Mag Z | `mz` | Float | NON | µT | Champ magnétique axe Z |
| Heart Rate | `hr` | Integer | NON | bpm | Fréquence cardiaque (0 = non disponible) |

**Note** : Les valeurs d'accéléromètre sont en **milli-g** (1000 milli-g = 1 g = 9.81 m/s²). La conversion vers g est effectuée dans le pipeline Python (normalizer.py).

---

### Objet GPS (`gps`)

| Champ | Clé | Type | Obligatoire | Unité | Description |
|-------|-----|------|-------------|-------|-------------|
| Latitude | `lat` | Double | OUI | degrés décimaux | Latitude WGS84 (-90 à +90) |
| Longitude | `lon` | Double | OUI | degrés décimaux | Longitude WGS84 (-180 à +180) |
| Altitude | `alt` | Float | NON | mètres | Altitude MSL |
| Speed | `spd` | Float | NON | m/s | Vitesse sol |
| Heading | `hdg` | Float | NON | degrés | Cap (0-360, nord = 0) |
| Accuracy | `acc` | Float | NON | mètres | Précision horizontale (CEP) |
| Timestamp | `ts` | Long | OUI | Unix seconds | Timestamp GPS (epoch) |

**Note** : L'API Connect IQ fournit lat/lon en **radians**. La conversion en degrés décimaux est effectuée dans `PositionManager.mc` avant sérialisation.

---

### Objet Metadata (`meta`)

| Champ | Clé | Type | Obligatoire | Unité | Description |
|-------|-----|------|-------------|-------|-------------|
| Battery | `bat` | Integer | NON | % | Niveau batterie (0-100) |
| Temperature | `temp` | Float | NON | °C | Température interne montre |

---

### Error Flags (`ef`)

Bitmask entier. Chaque bit représente un type d'erreur :

| Bit | Valeur | Nom | Description |
|-----|--------|-----|-------------|
| 0 | 0x01 | SENSOR_ERROR | Erreur lecture capteur IMU |
| 1 | 0x02 | GPS_ERROR | Erreur ou absence GPS |
| 2 | 0x04 | BUFFER_OVERFLOW | Buffer mémoire montre saturé |
| 3 | 0x08 | PARTIAL_PACKET | Paquet incomplet (données manquantes) |
| 4 | 0x10 | CLOCK_SKEW | Dérive horloge détectée |
| 5 | 0x20 | COMM_RETRY | Paquet réémis après échec |
| 6-31 | - | RESERVED | Réservé usage futur |

**Exemple** : `"ef": 6` signifie GPS_ERROR (0x02) + BUFFER_OVERFLOW (0x04).

---

## Contraintes de taille

### Taille maximale de paquet
- **Limite absolue** : 4096 bytes (4 KB) par paquet JSON sérialisé
- Si la sérialisation dépasse 4096 chars, le paquet est **tronqué** : les derniers samples sont retirés jusqu'à ce que la taille soit respectée
- L'error flag `PARTIAL_PACKET` (0x08) est positionné en cas de troncature

### Calcul taille typique (25 samples)
```
Header (~80 bytes) + 25 × sample (~110 bytes) + GPS (~120 bytes) + meta (~30 bytes)
= ~3030 bytes → dans les limites
```

### Batching
- **Maximum** : 25 samples par paquet
- **Trigger envoi** : 25 samples accumulés OU 1 seconde écoulée
- **Trigger urgence** : buffer montre > 80 éléments → envoi immédiat même si < 25 samples

---

## Gestion des versions

### Champ `pv` (Protocol Version)
- Toujours présent, valeur entière
- Version actuelle : `1`
- Versions futures : incrément si changement **incompatible** du schéma

### Compatibilité
| Version paquet | Handler Android v1 | Comportement |
|----------------|-------------------|--------------|
| 1 | v1 | Normal |
| 2+ | v1 | Log warning, tentative parse best-effort, champs inconnus ignorés |
| Absent | v1 | Rejeté (paquet invalide) |

---

## Gestion des pertes de paquets

### Détection
Le champ `pi` (packet index) est incrémental. Une discontinuité dans la séquence indique une perte :
```
pi=42, pi=43, pi=45  →  pi=44 perdu (1 paquet perdu)
```

### Tolérance
- Objectif : < 5% de paquets perdus en conditions normales (BLE stable)
- Seuil d'alerte : > 10% → afficher avertissement dans UI Android

### Comportement en cas de déconnexion BLE
1. **Montre** : continue d'enregistrer dans buffer circulaire (max 100 paquets)
2. **Montre** : si buffer plein → les plus anciens paquets sont écrasés, `ef |= BUFFER_OVERFLOW`
3. **Android** : détecte la déconnexion via `IQDeviceStatus`
4. **Montre** : tente reconnexion toutes les 30 secondes (max 10 tentatives)
5. **Après reconnexion** : reprise normale, gap détecté via `pi`

### Acquittements (ACK)
- Android envoie un ACK simple après chaque paquet reçu (message `{"ack": pi}`)
- La montre retire le paquet de sa queue d'envoi à réception de l'ACK
- Sans ACK après 5s : réémettre (max 3 tentatives), positionner `ef |= COMM_RETRY`

---

## Format Session ID

```
Format  : YYYYMMDD_HHMMSS_XXXXXX
Exemple : 20240422_143022_A1B2C3
```

Où `XXXXXX` est un identifiant dérivé du device ID Garmin (6 premiers chars hexadécimaux).

---

## Exemples de paquets

### Paquet minimal (1 sample, sans GPS)
```json
{"pv":1,"sid":"20240422_143022_A1B2C3","pi":0,"dtr":1713794022000,"s":[{"t":0,"ax":12,"ay":-983,"az":124,"gx":0.5,"gy":-0.3,"gz":0.1,"mx":22.5,"my":-15.3,"mz":44.1,"hr":72}],"ef":0}
```

### Paquet complet (25 samples avec GPS)
```json
{"pv":1,"sid":"20240422_143022_A1B2C3","pi":1,"dtr":1713794023000,"s":[{"t":0,"ax":15,"ay":-980,"az":120,"gx":0.5,"gy":-0.3,"gz":0.1,"mx":22.5,"my":-15.3,"mz":44.1,"hr":73},{"t":40,"ax":18,"ay":-978,"az":118,"gx":0.6,"gy":-0.2,"gz":0.2,"mx":22.4,"my":-15.2,"mz":44.2,"hr":73}],"gps":{"lat":48.8566,"lon":2.3522,"alt":35.0,"spd":1.2,"hdg":270.0,"acc":5.0,"ts":1713794023},"meta":{"bat":85,"temp":22.5},"ef":0}
```

### Paquet avec erreurs
```json
{"pv":1,"sid":"20240422_143022_A1B2C3","pi":100,"dtr":1713794122000,"s":[{"t":0,"ax":20,"ay":-975,"az":115,"gx":1.0,"gy":-0.5,"gz":0.3,"mx":0.0,"my":0.0,"mz":0.0,"hr":0}],"meta":{"bat":72,"temp":23.1},"ef":3}
```
(ef=3 = SENSOR_ERROR | GPS_ERROR)

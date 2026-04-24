# GarminSensorCapture — Guide de soumission Connect IQ Store

## Fichier prêt
```
bin/GarminSensorCapture.iq   ← fichier à uploader sur le store
```
18 devices compilés : fēnix 7/7s/7x/7pro/7spro/7xpro + fēnix 8 43mm/47mm/8Pro47mm/8Solar47mm/51mm

---

## Étapes de soumission

### 1. Compte développeur Garmin
→ https://developer.garmin.com  
Créer un compte, accepter les conditions de publication.

### 2. Créer l'app listing
→ https://apps.garmin.com/developer  
**"Publish App"** → type = **Watch App**

Renseigner :
- **App Name** : `SensorCapture`
- **UUID** : `a3b4c5d6-e7f8-1234-abcd-ef0123456789`  
  *(doit correspondre exactement au `id` dans manifest.xml sans tirets)*
- **Category** : Tools & Utilities → Data Collection
- **Price** : Free

### 3. Description — English (obligatoire)

**Short description** (≤ 200 chars) :
```
Multi-sensor raw data recorder. Captures IMU at 100 Hz, GPS, HR and metadata. Streams to Android companion app via BLE with persistent ACK-based queue.
```

**Long description** :
```
SensorCapture records synchronized raw sensor data from your fēnix watch and streams it in real time to an Android companion app over Bluetooth Low Energy.

SENSORS CAPTURED:
• Accelerometer + Gyroscope at 100 Hz
• Magnetometer at 25 Hz
• GPS position, speed and heading at 1 Hz
• Heart rate, HRV and RR intervals
• Barometric pressure, temperature, altitude
• SpO2, stress level, body battery

14 INFORMATION SCREENS:
Summary · IMU · GPS · Heart Rate · Metadata · Recording
BLE Link · Phone Storage · File Size · Buffer
Integrity · Time Sync · Battery · Pipeline Global

RELIABILITY FEATURES:
• Single-in-flight BLE transmit (no queue overflow)
• On-watch persistent packet queue — survives up to 5 min BLE disconnection
• ACK-based deletion — packets removed only after Android confirms receipt
• Automatic retransmission on reconnect

BUTTON MAPPING (fēnix 8 / 7):
• UP short: next screen   |  UP long: capture menu
• DOWN short: next sub-page  |  DOWN long: button lock
• START short: start/stop   |  START long: new session
• BACK short: mark event    |  BACK long: emergency stop

Requires the companion Android app (GarminDataCapture) to receive and save data.
```

### 4. Description — Français (optionnel mais recommandé)

**Courte** :
```
Enregistreur multi-capteurs bruts. Capture IMU à 100 Hz, GPS, FC et métadonnées. Diffuse vers une app Android via BLE avec file persistante ACK.
```

**Longue** : *(contenu de resources-fra/strings/strings.xml → app_description_long)*

### 5. Icônes — À FOURNIR PAR L'UTILISATEUR

| Fichier | Taille | Usage | Emplacement |
|---------|--------|-------|-------------|
| `launcher_icon.png` | **70 × 70 px** | Icône sur la montre (fēnix 7) | `resources/images/` |
| `launcher_icon_80.png` | **80 × 80 px** | Icône sur la montre (fēnix 8 AMOLED) | `resources-round-454x454/images/` |
| Store icon | **512 × 512 px** | Page web Connect IQ Store | Upload direct sur le portail |

**Design suggéré** : fond noir rond, lettre "S" ou radar/onde, couleur verte (#00FF7F).  
Format : PNG, fond transparent ou noir, pas de coins ronds (la montre les arrondit).

### 6. Screenshots — À CAPTURER DANS LE SIMULATEUR

Simulateur → fēnix 8 Pro 47mm (454 × 454) → `File → Screenshot`

| # | Écran recommandé | Contenu |
|---|-----------------|---------|
| 1 | RÉSUMÉ (recording) | Timer rouge, IMU/GPS/FC, BLE status bar |
| 2 | IMU sous-page ACC | RMS/MAX/MIN accéléromètre |
| 3 | GPS 3D | LAT/LON/ALT/VIT/CAP |
| 4 | PIPELINE (sous-page 0) | Checklist MONTRE/BLE/PHONE/WRITE |
| 5 | BATTERIE | % large + barre + consommation |

Format accepté : PNG, JPEG. Max 5 screenshots.  
Simulateur : Menu **Simulator → Screenshot** ou `Ctrl+S`.

### 7. Upload et validation

1. Sur apps.garmin.com → Upload `.iq` file
2. Le portail valide le manifest (UUID, permissions, devices)
3. Attacher les screenshots et l'icône store (512×512)
4. Remplir les descriptions ENG + FRA
5. Soumettre → review Garmin (généralement 1-5 jours ouvrables)

---

## Checklist avant soumission

- [x] `bin/GarminSensorCapture.iq` compilé (18/18 devices)
- [x] `manifest.xml` v1.3.0, UUID défini, permissions listées
- [x] Strings bilingues ENG + FRA (`strings.xml` + `strings-fra.xml`)
- [x] Resource override icônes fēnix 8 (454×454)
- [ ] **Icône 70×70** à créer et placer dans `resources/images/launcher_icon.png`
- [ ] **Icône 80×80** à créer et placer dans `resources-round-454x454/images/launcher_icon_80.png`
- [ ] **Icône store 512×512** à uploader sur le portail
- [ ] **5 screenshots** à capturer dans le simulateur
- [ ] Compte développeur Garmin créé
- [ ] App listing créé sur apps.garmin.com avec l'UUID correspondant

---

## Structure finale des fichiers

```
01_watch_app_connectiq/
├── bin/
│   └── GarminSensorCapture.iq          ← à uploader
├── manifest.xml                         ← v1.3.0, 11 devices
├── monkey.jungle                        ← icône override fēnix 8
├── resources/
│   ├── bitmaps.xml                      ← LauncherIcon (70×70)
│   ├── images/
│   │   └── launcher_icon.png            ← ⚠ REMPLACER (70×70)
│   └── strings/
│       ├── strings.xml                  ← anglais (défaut)
│       └── strings-fra.xml              ← français (auto si montre = FR)
├── resources-round-454x454/
│   ├── bitmaps.xml                      ← LauncherIcon (80×80)
│   └── images/
│       └── launcher_icon_80.png         ← ⚠ REMPLACER (80×80)
└── source/
    └── *.mc                             ← code source
```

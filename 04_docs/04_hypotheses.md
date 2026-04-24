# Journal des Hypothèses — Garmin Sensor Capture

Ce document liste toutes les hypothèses explicites du système qui n'ont pas encore été validées sur hardware réel. Chaque hypothèse doit être vérifiée avant mise en production.

**Légende** :
- STATUS: HYPOTHESE = non validé
- STATUS: VALIDÉ = confirmé sur hardware
- STATUS: RÉFUTÉ = invalidé, voir note de correction

---

## H-001 — Fréquence accéléromètre : 25 Hz

| Champ | Valeur |
|-------|--------|
| ID | H-001 |
| Hypothèse | La fréquence d'échantillonnage de l'accéléromètre du Garmin fēnix 8 Pro via Toybox.Sensor est de 25 Hz |
| Raison | La documentation Connect IQ ne spécifie pas la fréquence exacte. 25 Hz est la valeur typique pour les montres Garmin de la série fēnix selon les retours communautaires (forums Garmin Developer) |
| Impact | Calcul de timestamps relatifs, taille des batchs (25 samples = 1s), métriques de fréquence |
| Validation requise | Mesurer `period` dans `SensorInfo` sur le device réel. Implémenter compteur de fréquence dans `SensorManager.mc` |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-002 — Fréquence gyroscope : 25 Hz

| Champ | Valeur |
|-------|--------|
| ID | H-002 |
| Hypothèse | Le gyroscope est synchronisé avec l'accéléromètre à 25 Hz |
| Raison | L'API Toybox.Sensor retourne IMU et gyroscope dans le même callback SensorData, suggérant une synchronisation |
| Impact | Un seul timestamp `t` par sample couvre accel + gyro |
| Validation requise | Vérifier empiriquement que accel et gyro sont bien dans le même SensorData à la même fréquence |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-003 — Fréquence GPS : 1 Hz

| Champ | Valeur |
|-------|--------|
| ID | H-003 |
| Hypothèse | Le GPS fournit 1 position par seconde via Position.LOCATION_CONTINUOUS |
| Raison | Standard industrie pour les GPS de montres sport. Connect IQ avec LOCATION_CONTINUOUS typiquement ~1 Hz |
| Impact | GPS stocké séparément dans chaque paquet (1 objet GPS / paquet). Pas de GPS dans chaque sample |
| Validation requise | Mesurer la fréquence réelle des callbacks onPosition() sur device réel |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-004 — Fréquence cardiaque : 1 Hz

| Champ | Valeur |
|-------|--------|
| ID | H-004 |
| Hypothèse | La fréquence cardiaque est mise à jour 1 fois par seconde dans SensorData.heartRate |
| Raison | Les capteurs optiques de FC des montres Garmin fēnix typiquement ≤ 1 Hz pour les données brutes accessibles via SDK |
| Impact | La plupart des samples auront la même valeur de `hr` dans un batch de 25 samples |
| Note | La valeur `hr` dans chaque sample est la dernière valeur disponible au moment de l'échantillonnage IMU, pas une nouvelle mesure FC |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-005 — Taille max queue mémoire montre : 100 paquets

| Champ | Valeur |
|-------|--------|
| ID | H-005 |
| Hypothèse | Le buffer circulaire de la montre peut stocker jusqu'à 100 paquets en mémoire heap |
| Raison | Heap Connect IQ ≈ 260 KB. Un paquet (25 samples) JSON ≈ 2.5-3 KB. 100 paquets ≈ 250-300 KB — à la limite. Valeur conservative pour éviter OutOfMemoryError |
| Impact | Durée maximale de déconnexion BLE sans perte de données ≈ 100s |
| Validation requise | Tester en simulateur avec allocation maximale. Monitorer via System.getSystemStats() |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-006 — Timeout reconnexion mobile : 30 secondes

| Champ | Valeur |
|-------|--------|
| ID | H-006 |
| Hypothèse | Après déconnexion BLE, la montre tente une reconnexion toutes les 30 secondes |
| Raison | Compromis entre réactivité et consommation batterie. 30s est standard pour les appareils BLE en mode reconnexion |
| Impact | Latence max de récupération après coupure = 30s + temps de reconnexion |
| Validation requise | Tester sur device réel en déconnectant/reconnectant le Bluetooth Android |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-007 — Format session_id : "YYYYMMDD_HHMMSS_deviceId"

| Champ | Valeur |
|-------|--------|
| ID | H-007 |
| Hypothèse | Le session_id suit le format "YYYYMMDD_HHMMSS_XXXXXX" où XXXXXX est dérivé du device ID Garmin |
| Raison | Format lisible humain + unicité par device. Permet tri chronologique |
| Note | L'accès au device ID complet via Connect IQ SDK nécessite vérification. Si indisponible, utiliser les 6 premiers chars d'un UUID généré |
| Impact | Nommage des fichiers JSONL, identification des sessions dans le pipeline Python |
| Status | HYPOTHESE (device ID part) |
| Date | 2024-04-22 |

---

## H-008 — Paquets perdus tolérance : < 5%

| Champ | Valeur |
|-------|--------|
| ID | H-008 |
| Hypothèse | En conditions normales (BLE stable, montre et téléphone à < 5m), le taux de perte de paquets est inférieur à 5% |
| Raison | BLE 5.0 a un taux d'erreur de bit très faible. Les paquets de 3KB peuvent nécessiter plusieurs trames BLE (MTU ≈ 512 bytes) mais le protocole Connect IQ gère la fragmentation |
| Impact | Qualité des données, interpolation requise pour < 5% de gaps |
| Validation requise | Test de charge BLE : enregistrement 10 minutes, compter les gaps dans pi |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-009 — Bluetooth LE pour la communication

| Champ | Valeur |
|-------|--------|
| ID | H-009 |
| Hypothèse | La communication Connect IQ utilise Bluetooth Low Energy (BLE) via le Connect IQ Mobile SDK |
| Raison | Le Connect IQ Mobile SDK abstrait le transport. Le fēnix 8 Pro supporte BLE 5.0+ |
| Note | Le Connect IQ Mobile SDK nécessite Garmin Connect app installée sur Android pour fonctionner — cela agit comme relai |
| Impact | Latence ~10-50ms par paquet en conditions normales |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-010 — Android minSdk : 26 (Android 8.0)

| Champ | Valeur |
|-------|--------|
| ID | H-010 |
| Hypothèse | L'application Android cible minSdk 26 (Android 8.0 Oreo) |
| Raison | Le Connect IQ Mobile SDK requiert Android 6.0+ (minSdk 23). Choisir 26 pour accéder à APIs modernes (JobScheduler, Bluetooth LE amélioré, FileProvider v2) |
| Impact | Couverture réduite des anciens appareils Android (<26 exclu) |
| Validation requise | Vérifier la version minimale requise par le Connect IQ Mobile SDK actuel |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-016 — Connect IQ Mobile SDK : Maven Central v2.4.0

| Champ | Valeur |
|-------|--------|
| ID | H-016 |
| Hypothèse | Le Connect IQ Mobile SDK Android est disponible sur Maven Central sous `com.garmin.connectiq:ciq-companion-app-sdk:2.4.0` |
| Raison | Garmin a publié le SDK sur Maven Central pour simplifier l'intégration Gradle. Plus besoin de télécharger/placer l'AAR manuellement. |
| Impact | Aucune action manuelle pour le SDK. Build autonome via `./gradlew assembleDebug`. |
| Note | Si la version 2.4.0 est introuvable sur Maven Central au moment du build, essayer la dernière version disponible : `com.garmin.connectiq:ciq-companion-app-sdk:+` ou consulter https://mvnrepository.com/artifact/com.garmin.connectiq |
| Validation requise | Exécuter `./gradlew dependencies` et vérifier que l'artefact est résolu sans erreur |
| Status | HYPOTHESE |
| Date | 2026-04-22 |

---

## H-011 — Connect IQ SDK version : 6.x

| Champ | Valeur |
|-------|--------|
| ID | H-011 |
| Hypothèse | L'application watch utilise Connect IQ SDK version 6.x (minApiLevel 3.3.0 dans manifest) |
| Raison | Le fēnix 8 Pro est une montre récente (2024) supportant les dernières APIs Connect IQ |
| Note | minApiLevel="3.3.0" dans le manifest correspond au firmware Connect IQ 3.3.0 minimum requis sur la montre |
| Impact | Accès aux APIs capteurs récentes, animations UI avancées |
| Validation requise | Vérifier la version CIQ installée sur le fēnix 8 Pro réel |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-012 — Garmin fēnix 8 Pro = "fenix8pro" dans manifest

| Champ | Valeur |
|-------|--------|
| ID | H-012 |
| Hypothèse | L'identifiant produit du Garmin fēnix 8 Pro dans le manifest Connect IQ est "fenix8pro" |
| Raison | Convention de nommage Garmin : nom modèle en minuscules sans espaces. Exemples connus : "fenix7", "fenix7pro" |
| Note | Si "fenix8pro" est invalide, essayer "fenix8_pro" ou consulter la liste officielle dans Garmin Connect IQ SDK |
| Impact | Le manifest détermine les devices compatibles. Si l'ID est incorrect, l'app ne sera pas installable |
| Validation requise | Vérifier dans Garmin Connect IQ SDK Device Manager ou sur https://developer.garmin.com/connect-iq/compatible-devices/ |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-013 — Unités accéléromètre : milli-g

| Champ | Valeur |
|-------|--------|
| ID | H-013 |
| Hypothèse | L'API Toybox.Sensor retourne les données d'accéléromètre en milli-g (1000 = 1g) |
| Raison | Documentation Connect IQ mentionne que SensorData.accelerometer contient des valeurs en milli-g |
| Impact | Conversion /1000 dans normalizer.py pour obtenir des valeurs en g |
| Validation requise | En statique (montre à plat), az devrait être ≈ 1000 milli-g (1g) |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-014 — MTU BLE : suffisant pour 4KB

| Champ | Valeur |
|-------|--------|
| ID | H-014 |
| Hypothèse | Le MTU BLE négocié est suffisant ou le SDK Connect IQ fragmente automatiquement les messages > MTU |
| Raison | Connect IQ Mobile SDK gère la fragmentation/reassembly des messages. La limite de 4KB est une limite applicative, pas BLE |
| Impact | Si le SDK ne fragmente pas, limiter la taille des paquets à MTU (~512 bytes) |
| Validation requise | Tester l'envoi de messages de 3KB via Communications.transmit() et vérifier la réception complète |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

## H-015 — Magnétomètre accessible via SensorData

| Champ | Valeur |
|-------|--------|
| ID | H-015 |
| Hypothèse | Le magnétomètre du fēnix 8 Pro est accessible via Toybox.Sensor.SensorData |
| Raison | Le fēnix 8 Pro dispose d'un magnétomètre 3 axes. Certaines montres Garmin l'exposent dans SensorData |
| Note | Si SensorData.magnetometer est null ou non disponible, les valeurs mx/my/mz seront 0.0 et ef |= SENSOR_ERROR |
| Impact | Données magnétomètre optionnelles dans le schéma de données |
| Status | HYPOTHESE |
| Date | 2024-04-22 |

---

---

## H-017 — Sampling rate IMU abaissé à 25 Hz par défaut

| Champ | Valeur |
|-------|--------|
| ID | H-017 |
| Hypothèse | Le sampling rate accel/gyro est limité à 25 Hz (et non 100 Hz) dans SensorManager |
| Raison | À 100 Hz avec `:period => 1`, le callback sensor livre 100 samples d'un coup. Chaque groupe de 25 déclenche un dispatch batch **depuis l'intérieur de la boucle** du callback, soit 4 appels récursifs à `onBatchReady()` par tick. Sur fēnix 8 Pro (heap ~260 KB) cela épuise la pile et provoque un crash vers le 8ème paquet (~2s). À 25 Hz, le callback livre exactement 25 samples → 1 dispatch propre par tick. |
| Impact | Fréquence IMU nominale : 25 Hz. La fréquence réelle mesurée (`actual_frequency_hz` dans Python) doit être ≥ 23 Hz en conditions normales. |
| Validation requise | Mesurer `getMeasuredFrequency()` sur le device réel. Si le CIQ runtime livre moins de 25 samples/s, ajuster en conséquence. |
| Status | VALIDÉ (fix hardware confirmé — crash corrigé) |
| Date | 2026-04-24 |

---

## H-018 — Mode LIVE_PREVIEW systématique dès l'ouverture de l'app

| Champ | Valeur |
|-------|--------|
| ID | H-018 |
| Hypothèse | Les capteurs (IMU, FC) et le GPS sont démarrés dès `setup()` (ouverture app), pas seulement au `startSession()` |
| Raison | Sans preview, l'écran affichait IMU 0%, GPS NO FIX, FC --- avant tout enregistrement. L'utilisateur ne pouvait pas vérifier la qualité du signal avant de lancer une session. |
| Impact | `SensorManager.register()` et `PositionManager.enable()` sont appelés dans `setup()`. L'état IDLE voit des données live en temps réel. `startSession()` ne re-enregistre pas (idempotent). `stopSession()` ne désenregistre pas (les capteurs continuent). `cleanup()` est le seul point de désenregistrement. |
| Note | Les callbacks sensor tournent en permanence. La batterie consomme légèrement plus en mode IDLE que sans capteurs. Impact estimé : +3-5 %/h supplémentaire (à valider hardware). |
| Validation requise | Mesurer la consommation batterie en mode IDLE avec capteurs actifs vs inactifs. |
| Status | HYPOTHESE (implémenté, impact batterie à valider) |
| Date | 2026-04-24 |

---

## Résumé des risques

| ID | Risque si hypothèse incorrecte | Probabilité | Impact |
|----|-------------------------------|-------------|--------|
| H-001 | Fréquence réelle ≠ 25Hz → timestamps incorrects | Moyen | Haut |
| H-005 | OOM sur montre si buffer trop grand | Faible | Critique |
| H-012 | App non installable sur fēnix 8 Pro | Moyen | Critique |
| H-014 | Messages > MTU non reçus → silently dropped | Faible | Haut |
| H-015 | mx/my/mz toujours 0 → données inutiles | Moyen | Faible |

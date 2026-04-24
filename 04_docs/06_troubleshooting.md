# Guide de dépannage — Garmin Sensor Capture

## 1. Problèmes liés au SDK Connect IQ

### 1.1 Erreur de compilation : "Cannot find symbol"

**Symptôme** : `error: cannot find symbol: Toybox.Sensor.SensorData`

**Causes possibles** :
1. SDK Connect IQ trop ancien (< 3.3.0)
2. Profil device non installé
3. Import manquant dans le fichier .mc

**Solution** :
```bash
# Vérifier version SDK
monkeyc --version

# Réinstaller profil device
sdkmanager install fenix8pro

# Vérifier imports dans le .mc
import Toybox.Sensor;
```

---

### 1.2 Erreur manifest : "Unknown product ID"

**Symptôme** : Compilation réussie mais app non visible sur device

**Causes possibles** :
1. ID produit incorrect dans manifest.xml
2. Device non listé comme compatible

**Solution** :
- Consulter la liste officielle : https://developer.garmin.com/connect-iq/compatible-devices/
- Tester avec `fenix8` si `fenix8pro` n'est pas reconnu
- Utiliser l'attribut `id="fenix_8_pro"` si le SDK l'exige (vérifier la documentation de la version SDK)

---

### 1.3 OutOfMemoryError sur la montre

**Symptôme** : App crash avec erreur mémoire, ou comportement erratique

**Causes possibles** :
1. Buffer circulaire trop grand (hypothèse H-005)
2. Strings JSON trop volumineuses
3. Accumulation d'objets non libérés

**Solution** :
```monkeyc
// Réduire la taille du buffer dans BatchManager
const MAX_BUFFER_SIZE = 50;  // réduire de 100 à 50

// Monitorer la mémoire
var stats = System.getSystemStats();
System.println("Free mem: " + stats.freeMemory);
```

---

### 1.4 Simulateur ne démarre pas

**Symptôme** : Commande `connectiq` sans effet

**Solution** :
```bash
# Vérifier Java
java -version  # doit être 11+

# Vérifier JAVA_HOME
echo $JAVA_HOME

# Lancer avec logs
$CIQ_SDK_HOME/bin/connectiq --verbose
```

---

## 2. Problèmes Bluetooth / Connect IQ Mobile SDK

### 2.1 SDK Status reste "NOT_INITIALIZED"

**Symptôme** : L'app Android affiche "SDK: NOT_INITIALIZED" indéfiniment

**Causes possibles** :
1. Garmin Connect non installé
2. Garmin Connect non lancé en arrière-plan
3. ConnectIQ.aar absent ou corrompu

**Solution** :
1. Installer Garmin Connect depuis Play Store
2. Ouvrir Garmin Connect, se connecter avec un compte Garmin
3. Vérifier que l'AAR est dans `app/libs/` et référencé dans `build.gradle`
4. Forcer arrêt de Garmin Connect, redémarrer

**Log de diagnostic** (Android Logcat) :
```
tag: ConnectIQManager
```

---

### 2.2 Watch Status = "NOT_PAIRED"

**Symptôme** : La montre n'apparaît pas dans la liste des appareils

**Solution** :
1. Dans Garmin Connect → Appareils → Vérifier la montre
2. Bluetooth activé sur téléphone ET montre
3. Montre à moins de 10m du téléphone
4. Redémarrer Bluetooth téléphone (désactiver/réactiver)
5. Si problème persiste : oublier l'appairage, re-appairer

---

### 2.3 Messages non reçus (Packets = 0)

**Symptôme** : La montre est en mode RECORDING mais Android ne reçoit rien

**Diagnostic** :
```kotlin
// Vérifier dans GarminReceiver.kt
Log.d("GarminReceiver", "App status: $status")
Log.d("GarminReceiver", "Message data type: ${messageData?.javaClass}")
```

**Causes possibles** :
1. UUID watch app incorrect dans Android
2. La montre n'a pas confirmé l'ouverture du channel
3. Application Connect IQ crash silencieux

**Solution** :
- Vérifier que l'UUID dans `strings.xml` Android == `id` dans `manifest.xml` montre
- Sur la montre : fermer/rouvrir l'app
- Vérifier les System.println() de la montre via le simulateur

---

### 2.4 Communication intermittente

**Symptôme** : Les paquets arrivent irrégulièrement ou s'arrêtent sans raison

**Causes** :
1. Distance BLE trop grande
2. Interférences WiFi (canaux 1, 6, 11 chevauchent BLE)
3. Garmin Connect app en arrière-plan tué par OS Android

**Solution** :
1. Rester à < 5m du téléphone
2. Désactiver WiFi temporairement pour test
3. Dans Paramètres Android → Applications → Garmin Connect → Désactiver l'optimisation batterie
4. Idem pour SensorCapture

---

## 3. Problèmes GPS

### 3.1 Pas de fix GPS (gps=null dans tous les paquets)

**Symptôme** : Aucune donnée GPS, champ `gps` absent dans JSONL

**Causes** :
1. Session en intérieur
2. Cold start GPS (attendre 30-60s dehors)
3. Ciel couvert ou obstructions

**Solution** :
- Démarrer la session dehors, ciel dégagé
- Attendre l'indicateur GPS FIX sur l'écran de la montre avant de lancer la capture
- En cas de cold start long : fermer et rouvrir l'app montre

---

### 3.2 Coordonnées GPS incorrectes

**Symptôme** : Latitude/longitude ne correspondent pas à la position réelle

**Causes** :
1. Bug de conversion radians → degrés dans PositionManager.mc
2. Données obsolètes (vieux fix GPS)

**Vérification** :
```monkeyc
// Dans PositionManager.onPosition()
var latRad = info.position.toRadians()[0];
var lonRad = info.position.toRadians()[1];
var latDeg = latRad * 180.0 / Math.PI;
var lonDeg = lonRad * 180.0 / Math.PI;
// À 48.85° lat : latDeg doit ≈ 48.85
```

---

### 3.3 Fréquence GPS < 1 Hz

**Symptôme** : Les paquets consécutifs ont tous le même timestamp GPS

**Cause** : Le GPS est à 1 Hz mais les paquets IMU sont à 1 paquet/seconde aussi. Normal.

**Action** : Aucune. Le timestamp `ts` dans GPS ne change que quand un nouveau fix est disponible.

---

## 4. Problèmes de mémoire

### 4.1 Application montre lente / lag

**Symptôme** : Interface montre peu réactive, délai sur les boutons

**Causes** :
1. Buffer presque plein (> 80 éléments)
2. Sérialisation JSON trop fréquente
3. GC Connect IQ actif

**Solution** :
- Vérifier `BatchManager._buffer.size()` dans les logs
- Activer force-flush à 60% au lieu de 80%
- Réduire les appels System.println() en production

---

### 4.2 Rotation de fichier Android manquée

**Symptôme** : Fichier JSONL > 100 MB, FileLogger ne crée pas de nouveau fichier

**Vérification** :
```kotlin
// Dans FileLogger.kt — vérifier la logique
if (currentFile.length() > MAX_FILE_SIZE_BYTES) {
    rotateFile()
}
```

---

## 5. Problèmes de performances

### 5.1 Fréquence réelle < 25 Hz

**Symptôme** : `actual_frequency_hz` dans metrics.json < 23 Hz

**Causes** :
1. Charge CPU Connect IQ trop élevée (JSON serialization)
2. Fréquence hardware différente de l'hypothèse H-001

**Solution** :
- Profiler avec System.getTimer() autour du callback onSensorDataReceived
- Réduire la fréquence de log (System.println coûteux)
- Si fréquence hardware ≠ 25 Hz : mettre à jour H-001 et adapter le batch size

---

### 5.2 Throughput Android < 1 paquet/s

**Symptôme** : L'UI Android affiche un throughput < 1 paquet/s alors que la montre capture à 25Hz/25 samples = 1 paquet/s

**Causes** :
1. Lenteur du parsing JSON dans GarminReceiver
2. FileLogger lent (flush trop fréquent)
3. Congestion BLE

**Solution** :
```kotlin
// Utiliser BufferedWriter avec flush toutes les 10 lignes
private val buffer = BufferedWriter(FileWriter(file, true), 16384)
// flush() uniquement tous les 10 paquets ou en cas de stopSession
```

---

## 6. Problèmes Python

### 6.1 FileNotFoundError sur le fichier JSONL

```bash
# Vérifier que le fichier existe
ls -la path/to/session.jsonl

# Utiliser le fichier d'exemple
python main.py D:/CLAUDE_PROJECTS/GARMIN/03_python_analysis/sample_data/sample_session.jsonl
```

### 6.2 Graphiques vides (matplotlib)

**Symptôme** : Les PNG sont générés mais vides

**Causes** :
1. DataFrame IMU vide (tous les paquets invalides)
2. Erreur de normalisation silencieuse

**Solution** :
```python
# Activer les logs de debug
import logging
logging.basicConfig(level=logging.DEBUG)
python main.py session.jsonl
```

### 6.3 Erreur pandas : "cannot convert float NaN to integer"

**Cause** : Colonnes avec NaN dans des colonnes qui devraient être int

**Solution** :
```python
# Dans normalizer.py, utiliser Int64 nullable
df['packet_index'] = df['packet_index'].astype('Int64')
```

### 6.4 Tests pytest échouent

```bash
cd D:/CLAUDE_PROJECTS/GARMIN
pip install pytest
python -m pytest 05_tests/test_python/ -v

# Si erreur d'import modules
cd 03_python_analysis
python -m pytest ../05_tests/test_python/ -v
```

---

## 7. Bugs hardware confirmés (v1.0.1)

### 7.1 CRASH après ~8 paquets / ~2 secondes d'enregistrement

**Symptôme observé** : L'app passe en RECORDING, affiche 8 paquets, le timer reste bloqué à 00:00:00, puis l'app se ferme et retourne au launcher.

**Cause racine** : À 100 Hz avec `Sensor.registerSensorDataListener({ :period => 1 })`, le callback reçoit 100 samples d'un coup. La boucle interne dans `SensorManager._onSensorDataReceivedImpl` appelle `_callback.invoke(sample)` pour chaque sample. Quand `BatchManager.accumulate()` atteint 25, il dispatch un batch **depuis l'intérieur de la boucle** — 4 dispatches par tick, chacun déclenchant la chaîne complète : `SessionManager.onBatchReady()` → `PacketSerializer` → `CommunicationManager.sendPacket()`. À 2 secondes (8 ticks × 100 Hz = 800 samples = 32 dispatches accumulés), la pile CIQ et/ou le heap sont épuisés.

**Facteurs aggravants** :
- `_sendHeaderPacket()` alloue 7 tableaux d'historique au démarrage, déjà sous pression mémoire
- `System.getSystemStats()` + meta cache appelés 4× par tick au lieu de 1×

**Fix appliqué (v1.0.1)** :
- `PRIMARY_RATE_HZ` abaissé de 100 à **25 Hz** dans `SensorManager.mc`
- `MAG_DOWNSAMPLE_RATIO` passé de 4 à **1** (mag et IMU au même rate)
- `_measuredFrequency` initialisé à **0.0f** (indicateur "pas encore mesuré")
- `ViewModel.computeImuQuality` : diviseur corrigé de 100.0 à **25.0**

**Fichiers modifiés** : `SensorManager.mc`, `ViewModel.mc`

---

### 7.2 Valeurs live nulles avant enregistrement (IMU 0%, GPS 0%, FC ---)

**Symptôme observé** : Avant d'appuyer sur START, tous les indicateurs capteurs affichent 0% / NO FIX / --- bpm. Impossible de vérifier la qualité du signal avant de lancer une session.

**Cause racine** : `SensorManager.register()` et `PositionManager.enable()` n'étaient appelés que dans `startSession()`. En état IDLE, aucun capteur n'était enregistré → `getStatus()` retournait des zéros.

**Fix appliqué (v1.0.1)** :
- Dans `SessionManager.setup()` : appel immédiat de `register()` et `enable()` après le câblage des subsystèmes
- Dans `SessionManager.startSession()` : appels de register/enable supprimés (déjà actifs, idempotents)
- Dans `SessionManager.stopSession()` : appels de unregister/disable supprimés — les capteurs continuent en mode preview après l'arrêt d'une session
- Dans `SessionManager.cleanup()` (app close) : unregister/disable conservés

**Comportement attendu après fix** :
- Dès l'ouverture de l'app : IMU affiche ~25 Hz, FC affiche la FC réelle, GPS affiche FIX si signal disponible
- START lance l'enregistrement sur des capteurs déjà actifs → pas de délai de démarrage

**Fichiers modifiés** : `SessionManager.mc`

**Note batterie** : Les capteurs tournant en permanence (IDLE inclus), la consommation en veille est légèrement supérieure. Impact estimé : +3-5 %/h (à valider hardware — H-018).

---

## 8. Codes d'erreur de référence

| Code | Composant | Description | Action |
|------|-----------|-------------|--------|
| `ef=0x01` | Watch | Erreur lecture IMU | Vérifier capteur, redémarrer session |
| `ef=0x02` | Watch | Pas de fix GPS | Normal si intérieur |
| `ef=0x04` | Watch | Buffer overflow | Vérifier connexion BLE, réduire buffer |
| `ef=0x08` | Watch | Paquet tronqué | Réduire batch size ou taille samples |
| `ef=0x20` | Watch | Renvoi après échec | BLE instable, vérifier distance |
| `CIQ-001` | Android | SDK init failed | Vérifier ConnectIQ.aar et Garmin Connect |
| `CIQ-002` | Android | Device not found | Vérifier appairage Bluetooth |
| `CIQ-003` | Android | Message invalid | Vérifier format JSON montre |

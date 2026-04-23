# Checklist de Mise en Route — GarminSensorCapture v1.0.0

Ce guide vous permet de mettre en route l'ensemble du système en moins de 30 minutes (hors compilation).

---

## Étape 1 — Prérequis matériels

- [ ] Montre Garmin fēnix 8 Pro (ou fēnix 7/8 compatible)
- [ ] Smartphone Android API 26+ (Android 8.0+)
- [ ] PC Windows/Mac/Linux avec Android Studio installé
- [ ] Câble USB-C pour la montre (mise à jour firmware si nécessaire)
- [ ] Garmin Connect Mobile installé sur le smartphone et compte créé

---

## Étape 2 — Installation Python (analyse)

```bash
# Vérifier la version Python
python --version        # Doit afficher Python 3.10.x ou supérieur

# Installer les dépendances
cd D:/CLAUDE_PROJECTS/GARMIN/03_python_analysis
pip install -r requirements.txt

# Vérifier l'installation
python -c "import numpy, pandas, matplotlib, scipy; print('OK')"
```

- [ ] Python 3.10+ disponible
- [ ] `pip install -r requirements.txt` réussi (0 erreur)
- [ ] Vérification imports affiche "OK"

---

## Étape 3 — Test du pipeline Python sur données d'exemple

```bash
cd D:/CLAUDE_PROJECTS/GARMIN/03_python_analysis
python main.py sample_data/sample_session.jsonl --output-dir ./output/test_run

# Vérifier les fichiers générés
ls output/test_run/
```

Fichiers attendus :
- [ ] `summary.txt` — rapport texte lisible
- [ ] `metrics.json` — métriques en JSON
- [ ] `imu_data.csv` — données IMU brutes
- [ ] `gps_data.csv` — données GPS
- [ ] `accelerometer_xyz.png`
- [ ] `gyroscope_xyz.png`
- [ ] `heart_rate.png`
- [ ] `gps_track.png`
- [ ] `altitude_profile.png`
- [ ] `sensor_overview.png`

---

## Étape 4 — Exécution des tests unitaires Python

```bash
cd D:/CLAUDE_PROJECTS/GARMIN

# Installer pytest si nécessaire
pip install pytest

# Lancer les tests
python -m pytest 05_tests/test_python/ -v
```

Résultat attendu :
```
===== 74 passed in X.XXs =====
```

- [ ] 0 failures
- [ ] 0 errors

---

## Étape 5 — Compilation de l'application montre

### 5.1 Installation du SDK Connect IQ

1. Télécharger le SDK Connect IQ 6.x depuis : https://developer.garmin.com/connect-iq/sdk/
2. Installer Visual Studio Code + extension "Monkey C"
   OU utiliser Eclipse avec le plugin Connect IQ
3. Configurer le chemin SDK dans l'IDE

- [ ] SDK Connect IQ 6.x installé
- [ ] Clé de développeur générée sur developer.garmin.com

### 5.2 Compilation et test en simulateur

```bash
cd D:/CLAUDE_PROJECTS/GARMIN/01_watch_app_connectiq

# Avec VS Code + Monkey C extension :
# Ctrl+Shift+P → "Monkey C: Build Project"
# Puis : "Monkey C: Run in Simulator" → sélectionner "fenix8pro"
```

- [ ] Compilation réussie (0 erreur)
- [ ] Simulateur fēnix 8 Pro lance l'application
- [ ] Écran affiche "IDLE" au démarrage
- [ ] Bouton START change l'état en "RECORDING"

### 5.3 Déploiement sur montre physique

1. Connecter la montre en USB
2. Dans l'IDE : "Run on Device" → sélectionner la montre détectée
3. Ou copier le `.prg` compilé dans le dossier `GARMIN/APPS/` de la montre (USB mass storage)

- [ ] Application visible dans la liste des applications Connect IQ
- [ ] Application se lance sans crash
- [ ] Écran de statut s'affiche correctement

---

## Étape 6 — Compilation de l'application Android

### 6.1 Configuration initiale

1. Ouvrir Android Studio
2. `File → Open` → sélectionner `D:/CLAUDE_PROJECTS/GARMIN/02_android_companion/`
3. Attendre la synchronisation Gradle (première fois : 2–5 minutes)
4. Copier `ConnectIQ.aar` dans `app/libs/` (télécharger depuis Garmin Developer Portal)

- [ ] Projet ouvert sans erreur Gradle
- [ ] `ConnectIQ.aar` présent dans `app/libs/`
- [ ] Build Gradle réussi (aucune dépendance non résolue)

### 6.2 Déploiement sur Android

1. Activer "Mode développeur" sur le smartphone (7 tapotements sur "Numéro de build")
2. Activer "Débogage USB"
3. Dans Android Studio : Run → Run 'app'

- [ ] Application installée sur le smartphone
- [ ] Application se lance sans crash
- [ ] Écran principal visible

---

## Étape 7 — Test d'intégration Watch → Android

### 7.1 Pré-conditions

- Montre et smartphone appairés via Bluetooth dans les paramètres système
- Garmin Connect Mobile ouvert sur le smartphone
- Application companion ouverte sur le smartphone
- Application montre ouverte sur la montre

### 7.2 Test de connexion BLE

1. Sur la montre, appuyer sur START pour démarrer l'enregistrement
2. Observer le statut BLE sur la montre ("OPEN" attendu dans les 10s)
3. Observer le compteur de paquets sur l'Android qui s'incrémente

- [ ] BLE s'ouvre dans les 10 secondes
- [ ] Paquets reçus sur Android (compteur > 0 après 5s)
- [ ] Débit affiché ≈ 1 paquet/seconde

### 7.3 Session de test (2 minutes)

1. Enregistrer pendant 2 minutes en extérieur (pour GPS)
2. Bouger le poignet pendant l'enregistrement
3. Arrêter la session

Vérification :
- [ ] Compteur paquets Android ≈ 120 (2 min × 60 paquets/min)
- [ ] Perte paquets < 10%
- [ ] Taille fichier > 100 KB

---

## Étape 8 — Export et analyse Python

### 8.1 Export depuis Android

1. Appuyer sur le bouton "Export" dans l'application Android
2. Partager le fichier JSONL vers un dossier accessible sur PC
   (Options : email, Google Drive, câble USB, AirDrop)

- [ ] Fichier JSONL exporté avec succès
- [ ] Taille fichier > 0 octets

### 8.2 Analyse Python

```bash
# Remplacer le chemin par celui du fichier exporté
cd D:/CLAUDE_PROJECTS/GARMIN/03_python_analysis
python main.py /chemin/vers/session.jsonl --output-dir ./output/session_reel
```

- [ ] Aucune erreur lors du parsing (vérifier les WARNING dans les logs)
- [ ] Durée affichée ≈ 120s (2 minutes)
- [ ] Fréquence affichée ≈ 25.0 Hz
- [ ] Perte de paquets estimée < 10%
- [ ] Score qualité ≥ 60
- [ ] Tous les plots générés
- [ ] `gps_track.png` affiche une trajectoire visible (non un point unique)

---

## Étape 9 — Vérification finale

```bash
# Relancer les tests pour confirmer que rien n'a été cassé
cd D:/CLAUDE_PROJECTS/GARMIN
python -m pytest 05_tests/test_python/ -v
```

- [ ] 0 failures, 0 errors

---

## Résolution de problèmes rapide

| Symptôme | Cause probable | Solution |
|----------|---------------|----------|
| BLE ne s'ouvre pas | Garmin Connect Mobile pas en cours | Ouvrir Garmin Connect Mobile |
| BLE ne s'ouvre pas | COMPANION_APP_ID incorrect | Vérifier GUID dans CommunicationManager.mc vs ConnectIQManager.kt |
| Fréquence ≠ 25 Hz | Montre en économie d'énergie | Désactiver mode économie d'énergie sur fēnix |
| GPS = null | Cold start | Aller en extérieur, attendre 5–15 min |
| ImportError Python | Package manquant | `pip install -r requirements.txt` |
| 0 packets Android | App crash ou non connectée | Vérifier logs Android Studio (Logcat) |
| Fichier JSONL vide | Erreur FileLogger | Vérifier permissions WRITE_EXTERNAL_STORAGE Android |

---

## Contacts et ressources

- Documentation complète : `04_docs/`
- Troubleshooting détaillé : `04_docs/06_troubleshooting.md`
- Guide d'exploitation : `04_docs/05_exploitation_guide.md`
- Hypothèses techniques : `04_docs/04_hypotheses.md`
- Garmin Developer Portal : https://developer.garmin.com/connect-iq/
- Connect IQ API Reference : https://developer.garmin.com/connect-iq/api-docs/

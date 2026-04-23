# Journal des limites Connect IQ — GarminSensorCapture

## Vue d'ensemble

Ce document recense toutes les limitations connues de la plateforme Connect IQ qui affectent ou pourraient affecter l'application GarminSensorCapture.

---

## L-001 — Heap mémoire Connect IQ

| Champ | Valeur |
|-------|--------|
| ID | L-001 |
| Limite | ~260 KB de heap disponible pour l'app (variable selon device) |
| Impact | Buffer de 100 paquets × ~3KB = 300KB > limite → risque OOM |
| Mitigation | Buffer limité à 100 paquets (empirique). Flush urgent à 80 éléments. |
| Mesure | `System.getSystemStats().freeMemory` à surveiller |
| Référence | Garmin Connect IQ Developer Guide, Memory Management section |

---

## L-002 — Taille maximale d'un message Communications

| Champ | Valeur |
|-------|--------|
| ID | L-002 |
| Limite | Messages via `AppChannel.transmit()` : limite non documentée officiellement |
| Valeur assumée | 4096 bytes (communauté developers.garmin.com) |
| Impact | Paquets > 4096 bytes ignorés ou erreur silencieuse |
| Mitigation | Tronquer au niveau PacketSerializer.MAX_PACKET_SIZE = 4096 |
| Note | Si la limite réelle est plus basse (ex: 512 bytes), adapter le batch size |
| Référence | H-014 dans 04_hypotheses.md |

---

## L-003 — Fréquence d'accès aux capteurs

| Champ | Valeur |
|-------|--------|
| ID | L-003 |
| Limite | La fréquence d'échantillonnage est contrôlée par le firmware, pas l'app |
| Valeur attendue | 25 Hz (configurable via sampleRate dans setEnabledSensors) |
| Impact | Si firmware impose < 25 Hz → moins de samples/s → batch > 1s |
| Mitigation | Mesure de fréquence réelle dans SensorManager._measuredFrequency |
| Note | Certains devices Garmin limitent à 10 Hz ou 50 Hz selon le mode |
| Référence | H-001, H-002 dans 04_hypotheses.md |

---

## L-004 — Restrictions d'accès au magnétomètre

| Champ | Valeur |
|-------|--------|
| ID | L-004 |
| Limite | `SensorData.magnetometer` peut être null même si permission Sensor accordée |
| Conditions | Certains firmwares réservent le magnétomètre pour la boussole interne |
| Impact | mx/my/mz = 0.0 dans tous les paquets |
| Mitigation | Vérification null avant extraction, valeurs 0.0 considérées "non disponibles" |
| Référence | H-015 dans 04_hypotheses.md |

---

## L-005 — Limite de la queue Communications

| Champ | Valeur |
|-------|--------|
| ID | L-005 |
| Limite | La queue interne de `Communications.AppChannel` est limitée (taille inconnue) |
| Impact | Appels répétés à `transmit()` sans attendre ACK peuvent surcharger la queue |
| Symptôme | Erreur `BLE_QUEUE_FULL` dans `onTransmitComplete()` |
| Mitigation | Queue applicative de 20 paquets max dans CommunicationManager |
| Stratégie | Un seul `transmit()` en vol à la fois (attendre ACK avant suivant) |

---

## L-006 — Restrictions de l'API Timer

| Champ | Valeur |
|-------|--------|
| ID | L-006 |
| Limite | Maximum ~5-10 Timer.Timer actifs simultanément (non documenté) |
| Impact | BatchManager et CommunicationManager utilisent chacun un Timer |
| Mitigation | Utiliser au maximum 2-3 timers simultanés dans l'app |

---

## L-007 — Temps de démarrage GPS (cold start)

| Champ | Valeur |
|-------|--------|
| ID | L-007 |
| Limite | En cold start, le GPS peut prendre 30-90 secondes pour acquérir un fix |
| Impact | Les premiers paquets n'auront pas de données GPS (champ `gps` absent) |
| Mitigation | Afficher l'état GPS dans l'UI, attendre le fix avant de démarrer la session |
| Note | Hot start (< 15 min depuis dernier fix) : ~3-10 secondes |

---

## L-008 — Limitations de String en Monkey C

| Champ | Valeur |
|-------|--------|
| ID | L-008 |
| Limite | Les opérations de concaténation de String créent de nouveaux objets (GC pressure) |
| Impact | La sérialisation JSON de 25 samples fait ~30 concaténations → GC fréquent |
| Mitigation | Limiter au strict nécessaire, éviter les concaténations en boucle serrée |
| Alternative | Utiliser Lang.StringBuffer si disponible dans la version SDK |

---

## L-009 — Précision des timestamps System.getTimer()

| Champ | Valeur |
|-------|--------|
| ID | L-009 |
| Limite | `System.getTimer()` retourne des millisecondes depuis le démarrage de l'app |
| Impact | Pas de timestamp Unix absolu depuis System.getTimer(). Dérive possible |
| Mitigation | Utiliser `Time.now()` pour le timestamp absolu de session, `getTimer()` pour les offsets intra-batch |
| Note | `Time.now()` a une précision à la seconde (pas milliseconde) |

---

## L-010 — Restriction backgroundApp

| Champ | Valeur |
|-------|--------|
| ID | L-010 |
| Limite | Les watch-app Connect IQ ne s'exécutent pas en arrière-plan |
| Impact | Si l'utilisateur quitte l'app pendant l'enregistrement, la capture s'arrête |
| Mitigation | Afficher un avertissement dans l'UI ("Ne pas quitter l'app") |
| Alternative | Utiliser un background_service_app si capture longue durée requise (nécessite refactoring majeur) |

---

## Résumé des limites critiques

| ID | Sévérité | Impact principal |
|----|----------|-----------------|
| L-001 | CRITIQUE | OOM possible si buffer > 80 paquets |
| L-002 | CRITIQUE | Messages > 4KB silently dropped |
| L-003 | MAJEUR | Fréquence réelle inconnue avant validation hardware |
| L-010 | MAJEUR | Capture impossible si app quittée |
| L-004 | MINEUR | Magnétomètre peut être indisponible |
| L-008 | MINEUR | Performance GC lors sérialisation |

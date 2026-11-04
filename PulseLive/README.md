# PulseLive — installation

## Requis
- Mac + Xcode 26
- iPhone iOS 26+
- AirPods Pro 3 ou Powerbeats Pro 2
- Compte Apple gratuit suffit (app valable 7 jours, puis re-signer)

## Étapes
1. Xcode → New Project → iOS App → nom `PulseLive`, SwiftUI.
2. Supprime `ContentView.swift` + `PulseLiveApp.swift` générés. Glisse le `PulseLiveApp.swift` fourni.
3. Target → Signing & Capabilities → `+ Capability` → **HealthKit**.
4. `+ Capability` → **Background Modes** → coche **Workout processing**.
5. Target → Info → ajoute :
   - `NSHealthShareUsageDescription` = `Lire ta fréquence cardiaque.`
   - `NSHealthUpdateUsageDescription` = `Session temporaire, rien n'est sauvegardé.`
6. Branche l'iPhone → choisis-le → ▶︎ Run.
7. iPhone : Réglages → Général → VPN et gestion d'appareils → fais confiance au certificat.
8. AirPods : Réglages → tes AirPods → Fréquence cardiaque ON.

## Utilisation
Démarrer → BPM live, moyenne, min, max, durée, graphique.
Stop → session supprimée. Aucun workout, aucune calorie dans Santé.

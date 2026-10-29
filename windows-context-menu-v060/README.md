# GEKKO ARCHIVE — Intégration au menu moderne Windows 11

## Sources validées sur PC (30 octobre 2026)

- La DLL `native/GEKKOArchiveContext.cpp` et `package/AppxManifest.xml` produisent l’extension de menu MSIX **0.6.0.1**.
- Le sous-menu GEKKO ARCHIVE apparaît dans le menu **moderne** de l’Explorateur Windows 11.
- Les cinq commandes sont reliées au pont de lancement GEKKO ARCHIVE V0.5.0, validé pour exécution automatique.
- Sélection d’un seul fichier/dossier à la fois pour cette Alpha.
- Ne contient ni package MSIX compilé, ni DLL binaire, ni certificat signé, ni clé privée. Ils sont produits sur le PC pendant l’installation de développement.

## Organisation / historique de la version de test

- `bootstrap-v0600/` : sources initiales MSIX **0.6.0.0**, requises par `INSTALLER_MENU_WINDOWS_V060.ps1` pour une installation initiale (ce script contient la correction `user32.lib`).
- `FINALISER_MENU_WINDOWS_V060.bat` : à utiliser après la compilation initiale si le MSIX est rejeté pour certificat non approuvé ; demande une autorisation explicite pour faire confiance au **certificat public** de développement dans `LocalMachine/TrustedPeople` (tous les utilisateurs du PC). Ne touche pas aux autorités racines.
- `ACTUALISER_VISIBILITE_MENU_V060.bat` : depuis 0.6.0.0 installée, compile la DLL finale et met à jour le MSIX en **0.6.0.1**, sans générer de nouveau certificat.
- `DIAGNOSTIQUER_MENU_WINDOWS_V060.bat` et `REPARER_AFFICHAGE_MENU_V060.bat` : outils de diagnostic et réparation utilisés durant l’Alpha ; ne remplacent pas le déploiement initial.
- `DESINSTALLER_MENU_WINDOWS_V060.bat` : retire le package, et propose de retirer la confiance accordée au certificat.

Ces étapes documentent le parcours **expérimental déjà testé** sur Windows 11. Ce n’est **pas** un installateur de distribution final ni un parcours d’installation sur une nouvelle machine intégralement revalidé. Vérifier et simplifier l’ensemble avant toute diffusion. Les fichiers et les paramètres utilisateur ne sont pas inclus.

## Périmètre

Cette version ajoute uniquement le menu contextuel Windows 11 ; le cœur ZIP/7z/RAR et son pont de commandes restent inchangés. La personnalisation des entrées du menu reste à développer.

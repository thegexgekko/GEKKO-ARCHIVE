# GEKKO ARCHIVE

Utilitaire d'archives pour **Windows 11**, développé avec **React + Tauri 2 + Rust**. Projet indépendant de GEKKO ULTIMATE STUDIO.

## État — V0.4.3 Alpha

- Ouverture et exploration d'archives ZIP, 7z, RAR et TAR : testées sur Windows 11.
- Extraction réelle : extraction RAR d'un fichier EXE confirmée après le correctif V0.2.4.
- Sélection des fichiers, destination proposée automatiquement (dossier de l'archive), choix de dossier, gestion des conflits, mots de passe, progression et annulation : fonctionnalités implémentées, tests complémentaires nécessaires.
- Création ZIP et 7z validée sur Windows 11 : fichiers et dossiers complets, protection par mot de passe, niveaux rapide / normal / maximum et annulation de compression.
- Conversion testée sur Windows 11 : RAR → ZIP, RAR → 7z, ZIP → 7z et 7z → ZIP ; conservation du contenu confirmée. L'archive originale est conservée.
- Fonction « Tester » retirée de l'interface à la demande de l'utilisateur ; les vérifications internes de création et d'extraction demeurent.
- À confirmer : extraction sélective, cas de conflits, annulation d'extraction et conversion, conversion de sources chiffrées.
- Ajout de fichiers et dossiers à la racine d'une archive ZIP ou 7z existante : testé sur Windows 11, avec conservation des fichiers déjà présents.
- L'ajout refuse les collisions de noms, modifie une copie temporaire et vérifie le résultat avant remplacement de l'archive. La gestion des conflits et les archives protégées restent à tester séparément.
- V0.4.2 : glisser-déposer de fichiers/dossiers depuis l’Explorateur vers GEKKO ARCHIVE, et dépôt d’archives ou de dossiers sur les commandes de l’interface ; disponible, à confirmer séparément sur Windows.
- V0.4.3 : extraction par glisser-déposer sortant vers l'Explorateur Windows (après préparation temporaire sécurisée) : fonctionnement confirmé sur Windows 11.
- V0.4.3 : bouton « Tout sélectionner / Tout désélectionner » : testé et validé sur Windows 11 ; permet de préparer plusieurs éléments pour le glisser-déposer.
- Installateur et menu contextuel moderne Windows 11 : pas encore opérationnels.

## Démarrage en développement (Windows 11)

1. Installer Node.js, Rust/Cargo et les outils C++ nécessaires à Tauri 2.
2. Lancer `INSTALLER_MOTEUR_7ZIP.bat` pour préparer localement les composants officiels de 7-Zip (téléchargement et vérification SHA-256).
3. Lancer `LANCER_GEKKO_ARCHIVE.bat`. Lors du premier lancement de V0.4.3, le script installe si nécessaire la dépendance libre de glisser-déposer natif (connexion ponctuelle).

Le programme de développement utilise les fichiers `src-tauri/resources/7z.exe` et `7z.dll`, fournis **localement** après l'étape 2. Ils ne sont **pas** enregistrés dans ce dépôt. L'utilisation et la redistribution des composants 7-Zip doivent respecter leurs licences, notamment les restrictions spécifiques à unRAR. Lire https://www.7-zip.org/license.txt .

## Structure

- `src/` : interface React, illustrations GEKKO ARCHIVE.
- `src-tauri/src/` : backend Rust, exploration, extraction, compression, conversion et ajout de fichiers.
- `src-tauri/capabilities/` : autorisations Tauri.
- `INSTALLER_MOTEUR_7ZIP.*` : préparation locale du moteur 7-Zip.

L'extraction par glisser vers l'Explorateur prépare une copie temporaire des éléments, puis déclenche le glisser natif Windows. De gros fichiers peuvent nécessiter du stockage temporaire. L'archive source reste intacte.

Les dossiers `node_modules/`, `dist/` et `src-tauri/target/` ainsi que les archives de test ne sont pas versionnés. Les illustrations GEKKO fournies par l'auteur sont conservées.

## Avertissement

Version Alpha : tests Windows supplémentaires requis avant toute utilisation sur des données importantes. Ce dépôt ne publie pas de licence open source globale pour le code et les illustrations GEKKO.

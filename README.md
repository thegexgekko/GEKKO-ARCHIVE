# GEKKO ARCHIVE

Utilitaire d'archives pour **Windows 11**, développé avec **React + Tauri 2 + Rust**. Projet indépendant de GEKKO ULTIMATE STUDIO.

## État — V0.2.4 Alpha

- Ouverture et exploration d'archives ZIP, 7z, RAR et TAR : testées sur Windows 11.
- Extraction réelle : extraction RAR d'un fichier EXE confirmée après le correctif V0.2.4.
- Sélection des fichiers, destination proposée automatiquement (dossier de l'archive), choix de dossier, gestion des conflits, mots de passe, progression et annulation : fonctionnalités implémentées, tests complémentaires nécessaires.
- Compression / création, conversion, menu contextuel Windows 11 : non encore opérationnels.

## Démarrage en développement (Windows 11)

1. Installer Node.js, Rust/Cargo et les outils C++ nécessaires à Tauri 2.
2. Lancer `INSTALLER_MOTEUR_7ZIP.bat` pour préparer localement les composants officiels de 7-Zip (téléchargement et vérification SHA-256).
3. Lancer `LANCER_GEKKO_ARCHIVE.bat`.

Le programme de développement utilise les fichiers `src-tauri/resources/7z.exe` et `7z.dll`, fournis **localement** après l'étape 2. Ils ne sont **pas** enregistrés dans ce dépôt. L'utilisation et la redistribution des composants 7-Zip doivent respecter leurs licences, notamment les restrictions spécifiques à unRAR. Lire https://www.7-zip.org/license.txt .

## Structure

- `src/` : interface React, illustrations GEKKO ARCHIVE.
- `src-tauri/src/` : backend Rust, exploration et extraction.
- `src-tauri/capabilities/` : autorisations Tauri.
- `INSTALLER_MOTEUR_7ZIP.*` : préparation locale du moteur 7-Zip.

Les dossiers `node_modules/`, `dist/` et `src-tauri/target/` ainsi que les archives de test ne sont pas versionnés. Les illustrations GEKKO fournies par l'auteur sont conservées.

## Avertissement

Version Alpha : tests Windows supplémentaires requis avant toute utilisation sur des données importantes. Ce dépôt ne publie pas de licence open source globale pour le code et les illustrations GEKKO.

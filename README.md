# GEKKO ARCHIVE

Utilitaire d'archives pour **Windows 11**, développé avec **React + Tauri 2 + Rust**. Projet indépendant de GEKKO ULTIMATE STUDIO.

## État — V0.6.0 Alpha

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
- V0.5.0 : pont local Windows → GEKKO ARCHIVE validé en mode développement (ouverture directe, compression ZIP/7z, extraction ici/vers un dossier). Les quatre commandes de compression/extraction sont maintenant exécutées automatiquement avec les paramètres habituels, sans clic supplémentaire ; les conflits et mots de passe demeurent soumis aux protections existantes.
- La réception des commandes depuis le script de test et leur exécution automatique ont été confirmées sous Windows 11. Les cas particuliers (conflits de destination, mots de passe, annulation) n'ont pas tous été testés via le pont.
- V0.6.0 Alpha : menu contextuel **moderne Windows 11** via extension COM `IExplorerCommand` validé sur le PC de test. Les commandes du sous-menu fonctionnent. Le package MSIX de test est en version **0.6.0.1** et nécessite un certificat de développement autosigné ; la personnalisation et l’installateur de distribution restent à développer.

## Menu contextuel V0.6.0 Alpha (Windows 11)

Sources et procédure expérimentale : [`windows-context-menu-v060/README.md`](windows-context-menu-v060/README.md). La première version de l'extension (MSIX 0.6.0.0) a été mise à jour vers la **0.6.0.1** qui a été testée sous Windows 11. L'installation nécessite une signature et une autorisation explicite pour le certificat de développement ; `LocalMachine/TrustedPeople` s’applique à tous les utilisateurs du PC. Les scripts prévoient une désinstallation et le retrait facultatif de cette confiance. Aucun certificat, DLL ou MSIX de test n'est publié.

## Démarrage en développement (Windows 11)

1. Installer Node.js, Rust/Cargo et les outils C++ nécessaires à Tauri 2.
2. Lancer `INSTALLER_MOTEUR_7ZIP.bat` pour préparer localement les composants officiels de 7-Zip (téléchargement et vérification SHA-256).
3. Lancer `LANCER_GEKKO_ARCHIVE.bat`. Lors du premier lancement avec la fonction de glisser-déposer, le script installe si nécessaire la dépendance libre de glisser-déposer natif (connexion ponctuelle).

Le programme de développement utilise les fichiers `src-tauri/resources/7z.exe` et `7z.dll`, fournis **localement** après l'étape 2. Ils ne sont **pas** enregistrés dans ce dépôt. L'utilisation et la redistribution des composants 7-Zip doivent respecter leurs licences, notamment les restrictions spécifiques à unRAR. Lire https://www.7-zip.org/license.txt .

## Pont Windows V0.5.0 (test en développement)

Après lancement de GEKKO ARCHIVE, glisser un fichier ou dossier sur `TESTER_PONT_WINDOWS_V050.bat` permet de choisir l'une des cinq commandes. Le script appelle `ENVOYER_PONT_WINDOWS_V050.ps1` pour transmettre la demande à l'instance déjà ouverte au moyen d'une file locale. Aucun élément de menu contextuel Windows n'est installé par ces scripts. `RECOMPILER_PONT_WINDOWS_V050.bat` sert uniquement à reconstruire le paquet Rust en cas de backend obsolète.

## V0.6.1 Alpha — personnalisation du menu contextuel Windows 11

- Activation et désactivation individuelle des cinq commandes depuis **Paramètres > Menu contextuel Windows 11**, validées sur Windows 11.
- Enregistrement local dans `%LOCALAPPDATA%\GEKKO_ARCHIVE\context_menu.ini`; l'extension C++ lit ces préférences au moment d'afficher le menu. Aucun redémarrage ou compilation pour changer les cases.
- Package MSIX de l'extension : **0.6.0.2**, mis à jour avec `ACTUALISER_PREFERENCES_MENU_V061.bat`. Utilise le certificat de développement local déjà accepté (certificat et binaires non présents dans GitHub).
- Les moteurs d'archives, le pont Windows V0.5.0 et les autres fonctions validées restent inchangés.
- **À venir :** installateur complet et désinstallation propre ; le script de mise à jour actuel ne remplace pas un installateur utilisateur final.

## Structure

- `src/` : interface React, illustrations GEKKO ARCHIVE.
- `src-tauri/src/` : backend Rust, exploration, extraction, compression, conversion et ajout de fichiers.
- `src-tauri/capabilities/` : autorisations Tauri.
- `INSTALLER_MOTEUR_7ZIP.*` : préparation locale du moteur 7-Zip.

L'extraction par glisser vers l'Explorateur prépare une copie temporaire des éléments, puis déclenche le glisser natif Windows. De gros fichiers peuvent nécessiter du stockage temporaire. L'archive source reste intacte.

Les dossiers `node_modules/`, `dist/` et `src-tauri/target/` ainsi que les archives de test ne sont pas versionnés. Les illustrations GEKKO fournies par l'auteur sont conservées.

## Avertissement

Version Alpha : tests Windows supplémentaires requis avant toute utilisation sur des données importantes. Ce dépôt ne publie pas de licence open source globale pour le code et les illustrations GEKKO.

# Contributing / Contribuer

This guide explains how to build and check My App Launcher from source. / Ce guide explique comment compiler et vérifier My App Launcher.

## Requirements / Prérequis

- **Xcode 27**, the macOS 27 SDK and Swift 6. / **Xcode 27**, le SDK macOS 27 et Swift 6.
- Apple Development signing configured for all three app targets. Certificates and private keys are not included. / Une signature Apple Development configurée pour les trois cibles. Les certificats et clés privées ne sont pas fournis.

## Build / Compilation

Clone the repository, open `MyAppLauncher.xcodeproj`, select the **MyAppLauncher** scheme and **My Mac** destination, then build in Xcode. You can also run a Release build from the repository root: / Clonez le dépôt, ouvrez `MyAppLauncher.xcodeproj`, sélectionnez le schéma **MyAppLauncher** et la destination **My Mac**, puis compilez dans Xcode. Pour compiler en Release depuis la racine du dépôt :

```sh
xcodebuild -project MyAppLauncher.xcodeproj \
  -scheme MyAppLauncher -configuration Release \
  -derivedDataPath "$PWD/work/DerivedData" build
```

The app is written to `work/DerivedData/Build/Products/Release/MyAppLauncher.app`. / L’app est créée dans `work/DerivedData/Build/Products/Release/MyAppLauncher.app`.

### Signing and identifiers / Signature et identifiants

Configure signing for the companion, widget and maintenance service. For your own fork, change bundle identifiers and the App Group consistently in project settings, both entitlement files, `Shared/SharedConfiguration.swift`, `WidgetMaintenance/main.m` and `MyAppLauncher/LauncherUpdates.swift`. Routing identifiers are also used in source code and scripts. Changing them creates a separate app identity; it does not migrate another installation’s settings. / Configurez la signature du compagnon, du widget et du service de maintenance. Pour votre fork, modifiez ensemble les identifiants de bundle et le groupe d’apps dans les réglages du projet, les deux fichiers d’autorisations, `Shared/SharedConfiguration.swift`, `WidgetMaintenance/main.m` et `MyAppLauncher/LauncherUpdates.swift`. Les identifiants de routage sont également présents dans le code et les scripts. Les changer crée une identité distincte ; les réglages d’une autre installation ne sont pas migrés.

`script/build_and_run.sh` installs a development copy into `Install/` and can replace the Mac’s current widget registration. / `script/build_and_run.sh` installe une copie de développement dans `Install/` et peut remplacer l’enregistrement du widget actuellement utilisé sur le Mac.

## Checks / Vérifications

Run the isolated checks from the repository root: / Lancez les vérifications isolées depuis la racine du dépôt :

```sh
./script/test_application_resolution.sh
./script/test_security.sh
```

They use temporary data rather than the active app configuration. They check code behavior, not the live widget; real widget and update behavior still needs a manual check on a Mac. / Elles utilisent des données temporaires et ne touchent pas à la configuration active de l’app. Elles vérifient le code, pas le widget réel ; son fonctionnement et les mises à jour doivent aussi être vérifiés manuellement sur un Mac.

## Updates / Mises à jour

Release preparation, the signed Sparkle feed and publication steps are documented in [docs/UPDATES.md](docs/UPDATES.md). The signing key stays in the maintainer’s Keychain and must never be committed. / La préparation des versions, le fichier signé de Sparkle et les étapes de publication sont décrits dans [docs/UPDATES.md](docs/UPDATES.md). La clé de signature reste dans le trousseau du mainteneur et ne doit jamais être publiée dans le dépôt.

Bug reports and focused pull requests are welcome. Please describe the macOS version, Mac model, steps to reproduce and expected behavior. / Les rapports de bogue et les propositions de modification ciblées sont les bienvenus. Indiquez la version de macOS, le modèle de Mac, les étapes pour reproduire le problème et le résultat attendu.

[MIT License](LICENSE).

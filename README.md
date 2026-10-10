# My App Launcher

<img src="MyAppLauncher/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="80" alt="My App Launcher logo">

**Vos applications et liens web, directement sur le bureau de votre Mac.**  
**Your apps and web links, right on your Mac desktop.**

[Français](#français) · [English](#english) · [Télécharger / Download](https://github.com/CocoZillAaa/MyAppLauncher/releases/latest)

Version actuelle / Current version: **1.0.0 — build 18**.

## Français

### Ce que fait l’application

My App Launcher associe un compagnon de configuration à un widget natif macOS :

- Lancez vos applications et vos liens HTTP/HTTPS en un clic.
- Recherchez les applications, ajoutez-en plusieurs et réorganisez-les par glisser-déposer ou au clavier.
- Choisissez une grille automatique ou manuelle, trois densités et des noms facultatifs.
- Utilisez les icônes macOS, les favicons ou vos propres images.
- Passez d’une page à l’autre avec les points et les flèches quand la liste dépasse la capacité du widget.

Cinq formats : Petit, Moyen, Grand, Très grand et Très grand vertical. Le fond du widget utilise la transparence native de macOS. Aucun module externe n’est nécessaire. L’interface de l’application est actuellement en français.

### Installer

**Prérequis : Mac Apple Silicon et macOS 27 ou ultérieur.** Le fichier fourni est un build de développement signé Apple Development, non notarisé. Son installation sur un autre Mac n’a pas encore été validée et macOS peut bloquer son ouverture.

1. Dans [Releases](https://github.com/CocoZillAaa/MyAppLauncher/releases/latest), téléchargez `MyAppLauncher-1.0.0-build18.zip`.
2. Décompressez-le et glissez `MyAppLauncher.app` dans **Applications**.
3. Ouvrez l’application. Si la configuration ne s’affiche pas, choisissez **Configurer…** dans son menu en haut de l’écran.
4. Ajoutez les applications et liens souhaités.
5. Faites un clic droit sur le bureau, choisissez **Modifier les widgets…**, cherchez **MyAppLauncher** et ajoutez un format.

Si macOS bloque l’ouverture, consultez les [instructions Apple](https://support.apple.com/fr-fr/102445). Une autorisation dans **Réglages Système > Confidentialité et sécurité** peut être proposée ; elle ne garantit pas la compatibilité de ce build de développement avec tous les Mac.

### Utiliser et mettre à jour

Le compagnon règle le contenu et l’apparence. Son aperçu ne change pas le format du widget réel : choisissez celui-ci dans la galerie ou le menu du widget. Les points et les flèches changent de page ; le balayage souris/trackpad n’est pas disponible. Les widgets d’un même format partagent la page courante.

Les images personnalisées doivent être **carrées**, de **1024 × 1024 pixels maximum** et de **1 Mo maximum**. Fermer la configuration avec le bouton rouge quitte le compagnon ; un clic sur une application du widget peut le relancer sans fenêtre intermédiaire.

Pour mettre à jour, quittez le compagnon et remplacez uniquement l’app dans Applications. Gardez une seule copie installée. Ne supprimez pas les données. La configuration, l’ordre et les icônes sont stockés localement dans :

```text
~/Library/Group Containers/96H6RP27K3.myapplauncher
```

Sauvegardez ce dossier avant une réinstallation. Copier l’app sur un autre Mac ne transfère pas automatiquement ces réglages.

### Compiler le code

Il faut **Xcode 27**, le SDK macOS 27, Swift 6 et une signature Apple Development compatible avec l’App Group.

1. Clonez le dépôt et ouvrez `MyAppLauncher.xcodeproj`.
2. Sélectionnez le schéma **MyAppLauncher** et la destination **My Mac**.
3. Configurez la signature des deux cibles avec votre équipe Apple. Pour votre propre fork, adaptez les identifiants des bundles et l’App Group de façon cohérente dans les réglages, les deux fichiers d’entitlements et `Shared/SharedConfiguration.swift`. Les identifiants de routage sont également utilisés dans le code et le script de lancement. Les certificats et clés privées ne sont pas fournis.
4. Compilez avec Xcode ou la commande Release ci-dessous.

Changer ces identifiants crée une identité distincte et ne migre pas les données d’une installation existante. Le script `build_and_run.sh` installe une copie de développement dans `Install/` ; il peut remplacer l’enregistrement du widget existant. Pour l’usage courant, utilisez l’app dans Applications.

## English

### What the app does

My App Launcher combines a configuration companion with a native macOS desktop widget:

- Launch apps and HTTP/HTTPS links with one click.
- Search apps, add several at once and reorder them by drag and drop or keyboard.
- Choose an automatic or manual grid, three density settings and optional names.
- Use native macOS icons, favicons or your own images.
- Navigate with dots and arrows when your list needs more than one page.

Five sizes: Small, Medium, Large, Extra Large and Extra Large Portrait. The widget keeps native macOS transparency. No external dependencies are required. The app interface is currently in French.

### Install

**Requirements: Apple Silicon Mac and macOS 27 or later.** The download is an Apple Development signed build and is not notarized. Installation on another Mac has not yet been validated, and macOS may block it.

1. Download `MyAppLauncher-1.0.0-build18.zip` from [Releases](https://github.com/CocoZillAaa/MyAppLauncher/releases/latest).
2. Extract it and drag `MyAppLauncher.app` into **Applications**.
3. Open it. If configuration does not appear, choose **Configurer…** from its menu in the menu bar.
4. Add your apps and links.
5. Right-click the desktop, choose **Edit Widgets…**, search for **MyAppLauncher** and add a size.

If macOS blocks the app, follow [Apple’s instructions](https://support.apple.com/en-us/102445). **System Settings > Privacy & Security** may offer an approval option; this does not guarantee that this development build will work on every Mac.

### Use and update

The companion controls content and appearance. Its preview does not resize the actual widget: choose the size in the gallery or widget menu. Dots and arrows switch pages; mouse/trackpad swiping is unavailable. Widgets of the same size share the current page.

Custom images must be **square**, at most **1024 × 1024 pixels** and **1 MB**. Closing the configuration window with the red button quits the companion. An app click in the widget can launch it again without a configuration window.

To update, quit the companion and replace only the app in Applications. Keep a single installed copy and preserve its data. Configuration, order and icons are stored locally in:

```text
~/Library/Group Containers/96H6RP27K3.myapplauncher
```

Back up this folder before reinstalling. Copying the app to another Mac does not automatically transfer these settings.

### Build from source

You need **Xcode 27**, the macOS 27 SDK, Swift 6 and Apple Development signing compatible with the App Group.

1. Clone this repository and open `MyAppLauncher.xcodeproj`.
2. Select the **MyAppLauncher** scheme and **My Mac** destination.
3. Set up signing for both targets with your Apple team. For your own fork, update bundle identifiers and the App Group consistently in project settings, both entitlements files and `Shared/SharedConfiguration.swift`. Routing identifiers also appear in source code and the launch script. Certificates and private keys are not included.
4. Build in Xcode or use the Release command below.

Changing identifiers creates a separate app identity and does not migrate existing data. `build_and_run.sh` installs a development copy into `Install/` and can replace the existing widget registration. For everyday use, install the app in Applications.

## Structure / Layout

```text
MyAppLauncher.xcodeproj/  Xcode project: app + WidgetKit extension
MyAppLauncher/           SwiftUI configuration companion + app icon
MyAppLauncherWidget/     Native widget + page navigation intent
Shared/                  Configuration, app catalog, icons, routing, grid, pages
Tests/                   Existing application resolution checks
script/                  Build and test scripts
```

**Release build / Compilation Release** — from the repository root / depuis la racine :

```sh
xcodebuild -project MyAppLauncher.xcodeproj \
  -scheme MyAppLauncher -configuration Release \
  -derivedDataPath "$PWD/work/DerivedData" build
```

Output / Résultat : `work/DerivedData/Build/Products/Release/MyAppLauncher.app`.

**Existing checks / Contrôles existants :**

```sh
./script/test_application_resolution.sh
```

FR : ces contrôles utilisent un dossier temporaire séparé des données actives. Les cas Photoshop réels sont ignorés si les deux éditions ne sont pas installées. Ils ne remplacent pas les essais du widget sur le bureau.

EN: these checks use a temporary folder separate from live data. Real Photoshop checks are skipped if both editions are not installed. They do not replace desktop widget testing.

## Licence / License

[MIT](LICENSE) — Copyright © 2026 CocoZillAaa.

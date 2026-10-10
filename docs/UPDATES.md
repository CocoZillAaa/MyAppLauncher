# Publier une version / Publish a release

## Français

1. Augmenter `CFBundleVersion` dans les trois fichiers Info.plist (compagnon, widget, WidgetMaintenance). Le build doit être un entier strictement supérieur. Modifier aussi `CFBundleShortVersionString` pour une nouvelle version visible.
2. Compiler en Release avec le schéma MyAppLauncher. Les trois composants gardent la même équipe de signature. Les composants Sparkle sont signés par `Scripts/sign_sparkle.sh` avant la signature finale de l’app.
3. Télécharger la distribution officielle Sparkle **2.10.0** et vérifier son SHA-256 publié : `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`. Les outils sont dans son dossier `bin/`. Ne pas les ajouter au dépôt.
4. Préparer un fichier HTML de nouveautés FR/EN, puis lancer la commande ci-dessous avec un dossier de publication vide.
5. Publier le ZIP et `SHA256SUMS.txt` dans la GitHub Release dont le tag est indiqué par le script. La Release doit être publiée, sans statut brouillon ni préversion.
6. Copier le fichier `appcast.xml` généré vers `updates/appcast.xml`, puis pousser sur `main`. Ne pas modifier ce fichier signé à la main. Les anciens builds de l’app sans Sparkle ne reçoivent pas de mise à jour automatique.
7. Vérifier la mise à jour sur le second Mac : recherche manuelle, confirmation, remplacement, réapparition du widget, sélection et ordre conservés, pagination et lancement d’une application et d’un lien. La compilation seule ne valide pas ce parcours.

```sh
./script/prepare_update.sh \
  "$PWD/work/DerivedData/Build/Products/Release/MyAppLauncher.app" \
  "/chemin/vers/Sparkle-2.10.0/bin" \
  "$PWD/work/publication-nouveau-build" \
  "$PWD/notes-de-version.html"
```

Pour un fork distribué sous votre propre identité, configurer aussi votre propre URL de flux, votre clé publique Sparkle, le dépôt autorisé par le contrôleur et le compte de clé du script de publication. Ne pas réutiliser le flux ou la clé du projet original.

Le compte de clé Sparkle est `CocoZillAaa.MyAppLauncher` dans le trousseau de session. Il a été créé avec `generate_keys --account CocoZillAaa.MyAppLauncher`. Ne pas régénérer ni remplacer cette clé pour une mise à jour : les apps installées connaissent sa clé publique. Prévoir une sauvegarde privée sécurisée de cette clé avant de changer de Mac ; ne pas l’exporter vers le dépôt, les logs ou un ticket. Aucun jeton GitHub n’est intégré à l’app.

Le compagnon et le widget gardent leur sandbox. Deux communications Sparkle sont autorisées par nom précis. L’installateur Sparkle et le service WidgetMaintenance sont hors sandbox. WidgetMaintenance ne reçoit ni chemins, ni PID, ni commandes ; il valide les signatures et le même utilisateur, puis ne ferme que le binaire du widget inclus à cette installation. Aucun agent de lancement, service administrateur ou changement de Gatekeeper n’est installé.

La distribution reste signée Apple Development et non notarisée. Sparkle ne remplace pas la notarisation ; une autorisation macOS peut rester nécessaire. Le dépôt public est requis pour l’accès anonyme au fichier de versions et aux archives. La recherche automatique ne fonctionne que lorsque le compagnon est ouvert, sans téléchargement ni installation silencieuse et sans envoi du profil système. La fermeture au bouton rouge conserve son comportement actuel : quitter le compagnon.

## English

1. Increase `CFBundleVersion` in all three Info.plist files (companion, widget, WidgetMaintenance). Use a strictly increasing integer. Update `CFBundleShortVersionString` when changing the displayed version.
2. Build Release with the MyAppLauncher scheme and the same signing team for all components. `Scripts/sign_sparkle.sh` signs Sparkle components before the final app signature.
3. Download the official Sparkle **2.10.0** distribution and check the published SHA-256 above. Use its `bin/` tools without committing them.
4. Prepare FR/EN HTML release notes and run the command above with an empty output directory.
5. Publish the ZIP and `SHA256SUMS.txt` in the GitHub Release named by the script. Publish a normal release, not a draft or prerelease.
6. Copy the generated signed feed to `updates/appcast.xml` and push it to `main`. Never edit a signed feed manually. Older builds without Sparkle require a manual installation first.
7. Validate the full update on the second Mac: manual check, confirmation, replacement, widget recovery, retained selection/order, pagination, and launch of an app and link. Compilation does not validate this workflow.

For a separately distributed fork, configure your own feed URL, public Sparkle key, allowed release repository and publishing key account. Do not reuse the original project’s feed or key.

The private signing key is in the login Keychain under `CocoZillAaa.MyAppLauncher`. Do not regenerate it for new builds: installed apps trust the existing public key. Arrange a secure private backup before changing development machines. Never commit private keys or credentials. No GitHub token is included in the app.

The companion and widget remain sandboxed. Sparkle’s installer and the scoped on-demand WidgetMaintenance service run outside their sandbox. The maintenance service authenticates signatures and the user; it only operates on this installation’s bundled widget, accepts no arbitrary commands or paths, and installs no launch agent or administrator service.

This app remains Apple Development signed and not notarized. Sparkle does not replace notarization; macOS approval may still be needed. Public hosting is required for anonymous feed/archive access. Optional automatic checks run only while the companion is open. Silent downloads/installs and system profiling are disabled. Closing the configuration with the red button still quits the companion.

## Sources

- [Sparkle sandboxing](https://sparkle-project.org/documentation/sandboxing/)
- [Sparkle publishing](https://sparkle-project.org/documentation/publishing/)
- [Sparkle 2.10.0 distribution](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)

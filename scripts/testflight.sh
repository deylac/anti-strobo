#!/usr/bin/env bash
# Archive Anti-Strobo en Release et l'envoie à App Store Connect : TestFlight interne, ou App Store avec --app-store.
# Compatible avec le bash 3.2 de macOS : pas de tableaux associatifs, de nameref ni de mapfile.
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FICHIER_PROJET="project.yml"
OPTIONS_EXPORT="Config/ExportOptions-TestFlight-Internal.plist"
# Où le build pourra aller une fois envoyé (affiché à l'étape 5).
DESTINATION="TestFlight interne"
DOSSIER_ICONE="App/Assets.xcassets/AppIcon.appiconset"
VARIABLES_REQUISES="ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_PATH"

DRY_RUN=0
BUILD_ECRIT=""
# Passe à 1 juste avant l'export : à partir de là, un envoi a peut-être eu lieu et le numéro ne doit plus être restauré.
ENVOI_COMMENCE=0

usage() {
  cat <<'EOF'
Usage : scripts/testflight.sh [--dry-run] [--app-store] [-h|--help]

Archive Anti-Strobo en Release puis l'envoie à App Store Connect. Par défaut le build est réservé
aux testeurs internes de TestFlight ; avec --app-store, il peut aussi être soumis à l'App Store.

Étapes :
  1. swift test dans Packages/StrobeCore (le script s'arrête au premier échec)
  2. incrémente CURRENT_PROJECT_VERSION dans project.yml (rien n'est commité ; si une étape échoue
     avant l'envoi, le numéro précédent est restauré)
  3. xcodegen generate
  4. xcodebuild archive (Release) -> build/AntiStrobo-<version>-<build>.xcarchive
  5. xcodebuild -exportArchive avec Config/ExportOptions-TestFlight-Internal.plist
     (Config/ExportOptions-AppStore.plist avec --app-store)
     (l'export envoie directement le build à App Store Connect)

Options :
  --dry-run   Affiche chaque commande (valeurs de la clé masquées) sans rien exécuter
              ni modifier : ni swift test, ni xcodegen, ni changement de numéro de build,
              ni archive, ni envoi. Les prérequis (.env.local, outils, icône) sont tout de même vérifiés.
  --app-store Envoie un build qui pourra être soumis à l'App Store (et testé dans TestFlight).
  -h, --help  Affiche cette aide.

Prérequis :
  - un fichier .env.local à la racine du dépôt (modèle : .env.local.example) qui définit
    ASC_KEY_ID, ASC_ISSUER_ID et ASC_PRIVATE_KEY_PATH (chemin ABSOLU d'un fichier .p8 existant) ;
  - une icône PNG 1024×1024 sans transparence dans App/Assets.xcassets/AppIcon.appiconset ;
  - l'app app.camantistrobo.ios doit déjà exister dans App Store Connect.
EOF
}

erreur() {
  echo "Erreur : $*" >&2
  exit 1
}

etape() {
  printf '\n==> %s\n' "$*"
}

# Affiche une commande sur plusieurs lignes (une par option). La valeur qui suit
# une option -authenticationKey* est toujours remplacée par *** : la clé ne fuit jamais.
afficher_commande() {
  local arg masquer_suivante=0
  printf '  $'
  for arg in "$@"; do
    if [ "$masquer_suivante" = 1 ]; then
      printf ' ***'
      masquer_suivante=0
      continue
    fi
    case "$arg" in
      -authenticationKey*) masquer_suivante=1 ;;
    esac
    case "$arg" in
      -*) printf ' \\\n     ' ;;
    esac
    case "$arg" in
      *[!A-Za-z0-9_./=:@%+,-]*) printf " '%s'" "$arg" ;;
      *) printf ' %s' "$arg" ;;
    esac
  done
  printf '\n'
}

# Filtre de sortie : remplace par *** les valeurs de la clé, telles quelles (remplacement littéral,
# pas d'expression régulière). xcodebuild réécrit sa ligne de commande complète (« Command line
# invocation »), clé comprise : sans ce filtre elle apparaîtrait dans le terminal ou un journal.
# Le chemin est traité en premier (il contient souvent l'identifiant de la clé), y compris sous la
# forme échappée pour le shell (« Extreme\ SSD »).
masquer_sortie() {
  local ligne chemin_echappe
  printf -v chemin_echappe '%q' "$ASC_PRIVATE_KEY_PATH"
  while IFS= read -r ligne || [ -n "$ligne" ]; do
    ligne="${ligne//"$ASC_PRIVATE_KEY_PATH"/***}"
    ligne="${ligne//"$chemin_echappe"/***}"
    ligne="${ligne//"$ASC_KEY_ID"/***}"
    ligne="${ligne//"$ASC_ISSUER_ID"/***}"
    printf '%s\n' "$ligne"
  done
}

# Affiche la commande puis, hors simulation, l'exécute en filtrant sa sortie (stdout et stderr).
# Avec « set -o pipefail », le code de retour est celui de la commande, pas celui du filtre.
executer() {
  afficher_commande "$@"
  if [ "$DRY_RUN" = 1 ]; then
    return 0
  fi
  "$@" 2>&1 | masquer_sortie
}

# Valeur d'une clé « NOM: valeur » de project.yml (une seule occurrence attendue).
lire_cle_projet() {
  local cle="$1" valeurs nombre
  valeurs="$(sed -n -E "s/^[[:space:]]*${cle}:[[:space:]]*\"?([^\"#[:space:]]+)\"?[[:space:]]*(#.*)?\$/\\1/p" "$FICHIER_PROJET")"
  if [ -z "$valeurs" ]; then
    erreur "$cle introuvable dans $FICHIER_PROJET."
  fi
  nombre="$(printf '%s\n' "$valeurs" | wc -l | tr -d ' ')"
  if [ "$nombre" != 1 ]; then
    erreur "$cle apparaît $nombre fois dans $FICHIER_PROJET (une seule occurrence attendue)."
  fi
  printf '%s\n' "$valeurs"
}

verifier_outils() {
  local outil
  for outil in swift xcodegen xcodebuild sips; do
    command -v "$outil" >/dev/null 2>&1 || erreur "« $outil » est introuvable dans le PATH."
  done
}

# Sans icône 1024×1024 opaque, App Store Connect refuse l'envoi : on s'arrête avant de rien construire.
verifier_icone() {
  local image infos largeur hauteur alpha
  for image in "$DOSSIER_ICONE"/*.png; do
    [ -f "$image" ] || continue
    infos="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$image" 2>/dev/null || true)"
    largeur="$(printf '%s\n' "$infos" | awk '$1 == "pixelWidth:" { print $2 }')"
    hauteur="$(printf '%s\n' "$infos" | awk '$1 == "pixelHeight:" { print $2 }')"
    alpha="$(printf '%s\n' "$infos" | awk '$1 == "hasAlpha:" { print $2 }')"
    if [ "$largeur" = 1024 ] && [ "$hauteur" = 1024 ] && [ "$alpha" = no ]; then
      return 0
    fi
  done
  erreur "aucune icône PNG 1024×1024 sans transparence dans $DOSSIER_ICONE : App Store Connect refuserait l'envoi. Ajoute-la (une seule image, fond opaque) puis relance."
}

charger_env() {
  local nom manquantes=""
  if [ ! -f "$RACINE/.env.local" ]; then
    erreur "fichier .env.local introuvable à la racine du dépôt. Copie .env.local.example en .env.local puis renseigne ASC_KEY_ID, ASC_ISSUER_ID et ASC_PRIVATE_KEY_PATH."
  fi
  # Un fichier à la syntaxe invalide fait quitter bash en cours de « source », en affichant la ligne
  # fautive (donc potentiellement une valeur de clé). On le teste d'abord dans un sous-shell muet.
  # shellcheck disable=SC1091
  if ! ( . "$RACINE/.env.local" ) >/dev/null 2>&1; then
    erreur "syntaxe invalide dans .env.local (attendu : une ligne NOM=valeur par variable, valeur entre guillemets si elle contient des espaces)."
  fi
  # Chargé sans « set -a » : les variables restent dans ce script, elles ne sont pas exportées aux outils lancés.
  # shellcheck disable=SC1091
  . "$RACINE/.env.local" >/dev/null 2>&1 || erreur "impossible de charger .env.local."
  for nom in $VARIABLES_REQUISES; do
    if [ -z "${!nom:-}" ]; then
      manquantes="$manquantes $nom"
    fi
  done
  if [ -n "$manquantes" ]; then
    erreur "variable(s) vide(s) ou absente(s) dans .env.local :$manquantes."
  fi
  case "$ASC_PRIVATE_KEY_PATH" in
    /*) ;;
    *) erreur "ASC_PRIVATE_KEY_PATH (dans .env.local) doit être un chemin absolu (commençant par /) : xcodebuild refuse les chemins relatifs." ;;
  esac
  if [ ! -f "$ASC_PRIVATE_KEY_PATH" ]; then
    erreur "ASC_PRIVATE_KEY_PATH (dans .env.local) ne pointe pas vers un fichier existant."
  fi
}

# Remplace CURRENT_PROJECT_VERSION par le numéro donné, sans « sed -i »
# (l'option diffère entre BSD sed et GNU sed) : sortie temporaire puis recopie.
# Ne quitte jamais le script (appelée aussi depuis le trap de sortie) : elle renvoie un code.
remplacer_numero_build() {
  local numero="$1" temporaire
  temporaire="$(mktemp)" || return 1
  if sed -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)\"?[0-9]+\"?/\\1${numero}/" "$FICHIER_PROJET" >"$temporaire" \
    && cat "$temporaire" >"$FICHIER_PROJET"; then
    rm -f "$temporaire"
    return 0
  fi
  rm -f "$temporaire"
  return 1
}

ecrire_numero_build() {
  local nouveau="$1"
  remplacer_numero_build "$nouveau" || erreur "impossible d'écrire CURRENT_PROJECT_VERSION dans $FICHIER_PROJET."
  if [ "$(lire_cle_projet CURRENT_PROJECT_VERSION)" != "$nouveau" ]; then
    erreur "l'écriture de CURRENT_PROJECT_VERSION=$nouveau dans $FICHIER_PROJET a échoué."
  fi
  BUILD_ECRIT="$nouveau"
}

# Après un échec, remet project.yml en ordre :
#  - avant l'export, rien n'a pu partir vers App Store Connect : le numéro précédent est restauré ;
#  - dès que l'export a commencé, un envoi a peut-être abouti : le numéro n'est PAS rendu
#    (réutiliser un numéro déjà envoyé serait refusé par App Store Connect).
# Le code de sortie du script reste celui de l'échec d'origine (ce trap ne fait pas « exit »).
rapport_de_sortie() {
  local code=$?
  if [ "$code" -ne 0 ] && [ -n "$BUILD_ECRIT" ]; then
    echo >&2
    if [ "$ENVOI_COMMENCE" = 0 ]; then
      if remplacer_numero_build "$BUILD_ACTUEL" && [ "$(lire_cle_projet CURRENT_PROJECT_VERSION)" = "$BUILD_ACTUEL" ]; then
        echo "Le script a échoué avant l'envoi : numéro restauré ($FICHIER_PROJET est revenu au build $BUILD_ACTUEL)." >&2
      else
        echo "Le script a échoué avant l'envoi, mais le numéro n'a pas pu être restauré : remets CURRENT_PROJECT_VERSION à $BUILD_ACTUEL dans $FICHIER_PROJET." >&2
      fi
    else
      echo "Le script a échoué. $FICHIER_PROJET contient maintenant le build $BUILD_ECRIT (non commité)." >&2
      echo "Si rien n'a été envoyé à App Store Connect, tu peux relancer : un numéro sauté ne pose pas de problème." >&2
    fi
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --app-store)
      OPTIONS_EXPORT="Config/ExportOptions-AppStore.plist"
      DESTINATION="App Store"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Option inconnue : $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

cd "$RACINE"
trap rapport_de_sortie EXIT

verifier_outils
verifier_icone
charger_env

VERSION="$(lire_cle_projet MARKETING_VERSION)"
BUILD_ACTUEL="$(lire_cle_projet CURRENT_PROJECT_VERSION)"
case "$BUILD_ACTUEL" in
  *[!0-9]*) erreur "CURRENT_PROJECT_VERSION doit être un entier (valeur lue dans $FICHIER_PROJET non numérique)." ;;
esac
BUILD_NOUVEAU=$((10#$BUILD_ACTUEL + 1))
ARCHIVE="build/AntiStrobo-${VERSION}-${BUILD_NOUVEAU}.xcarchive"

# Les valeurs de la clé ne sont jamais affichées : afficher_commande les masque.
ARGS_CLE=(
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

if [ "$DRY_RUN" = 1 ]; then
  echo "MODE SIMULATION (--dry-run) : rien n'est exécuté, rien n'est modifié."
fi
echo "Anti-Strobo $VERSION : build $BUILD_ACTUEL -> $BUILD_NOUVEAU"

etape "1/5 Tests de StrobeCore"
printf '  $ %s\n' '(cd Packages/StrobeCore && swift test)'
if [ "$DRY_RUN" = 0 ]; then
  (cd Packages/StrobeCore && swift test)
fi

# Le numéro de build est écrit AVANT « xcodegen generate » : le .xcodeproj le fige à la génération.
etape "2/5 Numéro de build : $BUILD_ACTUEL -> $BUILD_NOUVEAU dans $FICHIER_PROJET"
if [ "$DRY_RUN" = 1 ]; then
  echo "  (simulation : $FICHIER_PROJET n'est pas modifié)"
else
  ecrire_numero_build "$BUILD_NOUVEAU"
fi

etape "3/5 Génération du projet Xcode"
executer xcodegen generate

etape "4/5 Archive Release -> $ARCHIVE"
executer xcodebuild archive \
  -project AntiStrobo.xcodeproj \
  -scheme AntiStrobo \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/dd-archive \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  "${ARGS_CLE[@]}"

etape "5/5 Export et envoi à App Store Connect ($DESTINATION)"
# À partir d'ici, un envoi a peut-être abouti : le numéro de build ne sera plus restauré en cas d'échec.
ENVOI_COMMENCE=1
executer xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS_EXPORT" \
  -exportPath build/export \
  -allowProvisioningUpdates \
  "${ARGS_CLE[@]}"

echo
if [ "$DRY_RUN" = 1 ]; then
  echo "Simulation terminée : aucune commande n'a été exécutée."
else
  echo "Build $BUILD_NOUVEAU envoyé. Rien n'est commité : pense à valider le nouveau numéro de build :"
  echo "  git add $FICHIER_PROJET && git commit -m \"chore: TestFlight build $BUILD_NOUVEAU\" && git tag build-$BUILD_NOUVEAU"
fi

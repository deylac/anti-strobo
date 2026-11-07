# Fiche App Store — Anti-Strobo 1.0

Langue principale : français. App gratuite, tous les pays.

## Identité

| Champ | Valeur |
|---|---|
| Nom (30 max) | Anti-Strobo |
| Sous-titre (30 max) | Filme tes concerts sans strobe |
| Identifiant de lot | `app.camantistrobo.ios` |
| SKU | `anti-strobo-ios` |
| Catégorie principale | Photo et vidéo |
| Catégorie secondaire | Musique |
| Copyright | 2026 deylac |
| Classification par âge | 4+ (aucun contenu sensible) |

## Texte promotionnel (170 max)

Les stroboscopes blanchissent tes vidéos de concert. Anti-Strobo retire chaque image éclairée par un éclair et te rend
une vidéo fluide, avec le son d'origine.

## Description (4000 max)

En concert, les stroboscopes gâchent les vidéos : à chaque éclair, l'image devient blanche et l'iPhone se dérègle d'un
flash à l'autre. Anti-Strobo filme le concert et te rend une vidéo où les éclairs ont disparu.

UN SEUL BOUTON
Ouvre l'app face à la scène : elle mesure la lumière entre les éclairs et affiche « Exposition prête ». Tu n'as plus
qu'à filmer. Aucun réglage.

LES ÉCLAIRS RETIRÉS, LA VIDÉO FLUIDE
L'app filme à haute cadence et repère chaque image éclairée par un stroboscope, même une petite lampe dans un coin.
Elle la retire, puis recrée les images manquantes pour que la vidéo reste fluide à 30 images par seconde. Le son est
gardé tel quel, synchronisé.

LES SCÈNES SOMBRES ÉCLAIRCIES
Dans une salle sombre, la vidéo nettoyée est débruitée et éclaircie.

TON ORIGINAL TOUJOURS GARDÉ
Les deux vidéos vont dans ta pellicule : l'original et la version nettoyée. Le nettoyage continue si tu verrouilles
ton iPhone.

RIEN NE QUITTE TON IPHONE
Tout le traitement se fait sur l'appareil. Pas de compte, pas de publicité, aucune donnée collectée.

OPEN SOURCE
Le code est public et ouvert aux contributions : github.com/deylac/anti-strobo

Bon à savoir : dans une salle presque noire avec un stroboscope très rapide, la vidéo nettoyée reste plus sombre que
la vidéo habituelle de l'iPhone, qui garde les éclairs.

## Mots-clés (100 max)

stroboscope,vidéo,flash,caméra,festival,live,scène,lumière,éclair,clignotement,musique,salle,DJ

## Adresses

| Champ | Adresse |
|---|---|
| Assistance | https://github.com/deylac/anti-strobo/issues |
| Marketing | https://github.com/deylac/anti-strobo |
| Confidentialité | https://github.com/deylac/anti-strobo/blob/main/PRIVACY.md |

## Confidentialité de l'app

Collecte de données : **aucune** (« Non, nous ne collectons pas de données à partir de cette app »).

## Captures d'écran

iPhone 6,9 pouces (1320 × 2868, celles d'un iPhone 17 Pro Max), 3 à 5 captures :

1. L'écran caméra face à la scène avec « Exposition prête ».
2. Pendant l'enregistrement.
3. Le nettoyage en cours, ou « Les deux vidéos sont dans ta pellicule ».

## Notes pour l'équipe de vérification d'Apple (en anglais)

Anti-Strobo films concerts lit by strobe lights and removes the frames lit by a flash.

How to test without a strobe light: in a dim room, point the camera at a light that flashes several times per second
(for example a strobe or flashlight app on another phone, or a strobe video on a screen).

1. Open the app and, when asked, allow the camera, the microphone and adding videos to Photos. The app measures the
   light for a few seconds, then shows "Exposition prête" (exposure ready).
2. Tap the red button to record 10 to 20 seconds, then tap it again to stop.
3. The app cleans the video ("Nettoyage de la vidéo… %") and saves two videos to Photos: the original and the cleaned
   version, without the flash-lit frames.

Without any flashing light, the app records normally and the cleaned video keeps every frame.

No account, no network connection. The app is in French. The Background GPU entitlement lets the cleaning continue on
the GPU when the screen is locked (BGContinuedProcessingTaskRequest); without it, the cleaning continues on the CPU.

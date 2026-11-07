# Cam Anti-Stroboscope — Document de conception

Date : 2026-11-06
Décisions : l'auteur du projet (sauf mention « choix de Claude »)

## 1. Intention

En concert, les stroboscopes ruinent les vidéos filmées au téléphone : à chaque flash, l'image devient blanche, on ne voit plus que la lumière, la scène et les artistes disparaissent. L'auto-exposition de l'iPhone aggrave le problème en « pompant » à chaque éclair.

L'app fait **une seule chose** : filmer un concert et produire une vidéo où les images brûlées par les flashs ont été retirées, sans intervention de l'utilisateur.

Règle de l'auteur : *une image surexposée par un flash est mauvaise, toutes les autres sont bonnes.*

## 2. Objectifs

- Filmer en un geste (un gros bouton enregistrer). Aucun réglage manuel exigé.
- Mesurer automatiquement la lumière de la scène et adapter la prise de vue (vitesse d'obturation, exposition) pour que les images entre les flashs soient bien exposées.
- Après l'enregistrement, produire automatiquement une **version nettoyée** sans les images surexposées.
- Conserver **la vidéo originale** en plus de la version nettoyée. Les deux vont dans la pellicule Photos.
- Le son reste complet et synchronisé.

## 3. Non-objectifs (V1)

- Pas d'aperçu nettoyé en temps réel pendant le tournage : l'auteur accepte un traitement après coup (« peu importe, si le résultat est bon »).
- Pas d'app photo, pas de mode pro, pas de montage, pas de filtres.
- Pas de garder « l'ambiance strobe adoucie » : les images flashées sont retirées, point.
- Pas d'Android pour l'instant.
- Pas de traitement de vidéos déjà existantes importées depuis la pellicule (piste possible plus tard, voir §9).

## 4. Anti-objectifs (ce qui serait un échec même si ça « marche »)

- Une vidéo nettoyée qui saccade ou se fige visiblement de façon gênante.
- Un son désynchronisé ou coupé.
- Perdre l'original, ou une vidéo nettoyée de moins bonne qualité que l'original sur les images gardées.
- Une app qui demande de comprendre la photo (ISO, obturation) pour obtenir un bon résultat.

## 5. Contraintes

- **Plateforme : iPhone uniquement**, app native (Swift / SwiftUI, AVFoundation). *(Choix de Claude, non contesté par l'auteur.)*
- **Distribution : TestFlight** pour les tests sur l'iPhone de l'auteur, qui a un compte Apple Developer, Xcode et une clé d'API App Store Connect d'équipe (envoi via `xcodebuild -exportArchive` avec `-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`).
- **Réglage de la détection** : comme l'original haute cadence est conservé, les seuils de détection peuvent être réglés et rejoués sur Mac à partir de vraies vidéos filmées avec l'app, sans attendre un nouveau concert. Le builder prévoit cet outil de réglage. *(Choix de Claude.)*
- App Store visé plus tard, pas une exigence V1 — mais rien dans la V1 ne doit l'empêcher (pas d'API privée, permissions caméra/micro/photos correctement déclarées).
- Contexte d'usage : salle sombre, lumières de scène changeantes, strobe à fréquence variable (souvent quelques Hz à ~15 Hz), téléphone tenu à la main.

## 6. Le fonctionnement (ce qui a été décidé)

### 6.1 Le cœur du problème (formulé par l'auteur)
Le strobe éblouit le téléphone : l'auto-exposition de l'iPhone se cale sur les flashs, et du coup **les images sans flash sont sous-exposées**. C'est le problème principal, avant même le tri des images.

### 6.2 Mesure de référence, avant d'enregistrer (décision de l'auteur)
- Avant l'enregistrement, l'app **mesure l'exposition correcte de la scène sans flash** : elle observe le flux caméra, écarte les images flashées, et calcule obturation + ISO adaptés aux images sans flash.
- Cette **exposition de référence est verrouillée** et utilisée telle quelle pendant tout l'enregistrement. La mesure de lumière des flashs n'est jamais prise en compte. L'auto-exposition native de l'iPhone est désactivée.
- Conséquence voulue : pendant l'enregistrement, les images sans flash sont bien exposées ; les images flashées sont franchement brûlées, donc faciles à détecter et retirer ensuite.
- La mesure se fait automatiquement quand l'écran caméra est ouvert, sans action de l'utilisateur. Toucher l'écran relance une mesure (par ex. si l'éclairage de scène a changé entre deux morceaux). *(Déroulé : choix de Claude.)*
- **L'app indique avant d'enregistrer combien de temps la mesure va prendre, puis confirme clairement qu'elle a réussi** (demande de l'auteur) : une fois l'enregistrement lancé on filme « à l'aveugle », il faut donc être sûr *avant* que l'exposition est bonne. Concrètement *(choix de Claude)* :
  - pendant la mesure : un compte à rebours / une progression (« Mesure de la lumière… 3 s ») ;
  - succès : état « Exposition prête » bien visible, et le bouton enregistrer devient pleinement actif ;
  - échec ou doute (pas assez d'images sans flash vues, scène trop sombre même sans flash) : message explicite, la mesure continue ou propose de réessayer. Enregistrer reste possible mais l'app signale que la référence n'est pas fiable.
- Durée de la mesure : variable selon le rythme du strobe, assez pour voir plusieurs flashs et plusieurs images sans flash (ordre de grandeur : quelques secondes). L'app l'adapte et l'affiche. *(Valeur exacte laissée au builder.)*

### 6.3 Pendant le tournage
- Capture à **cadence élevée** : 120 i/s si l'appareil le permet (240 i/s envisageable, voir §8), avec l'exposition de référence. *(Cadence : choix de Claude.)*
- Pas de réajustement d'exposition pendant l'enregistrement.
- Son enregistré normalement.
- Le format est choisi automatiquement selon ce que l'iPhone supporte (meilleure combinaison cadence haute / résolution disponible). *(Choix de Claude : le modèle exact de l'iPhone de test n'est pas connu, l'app s'adapte.)*

### 6.3 bis Durée d'enregistrement (décision de l'auteur : sans limite si possible)
- **Aucune limite imposée par l'app.** Les seules limites sont physiques, et l'app les affiche :
  - **Stockage** : c'est la vraie limite. Ordre de grandeur en 1080p 120 i/s HEVC : environ 10 Go par heure pour l'original (à confirmer sur appareil). L'app affiche avant et pendant l'enregistrement le temps restant estimé d'après l'espace libre, en gardant de la place pour la version nettoyée.
  - **Chauffe** : en filmant longtemps à cadence élevée, l'iPhone chauffe ; iOS peut forcer l'arrêt de la caméra si la température devient critique. L'app surveille l'état thermique, prévient l'utilisateur, et en cas d'arrêt forcé l'original déjà filmé est conservé et traité normalement.
  - **Batterie** : affichée, pas de limite.
- Le nettoyage d'une longue vidéo prend du temps (ordre de grandeur : une fraction de la durée filmée). Il doit pouvoir **continuer si l'app passe en arrière-plan ou l'écran se verrouille**, avec une progression visible (iOS 26 propose une tâche de traitement continu prévue pour ça). S'il est interrompu, il reprend au prochain lancement ; l'original n'est jamais perdu. *(Mécanique : choix de Claude.)*

### 6.4 Après le tournage
- Détection des images surexposées (« brûlées ») dans la vidéo haute cadence.
- Production d'une vidéo à cadence normale (**30 i/s**) n'utilisant que des bonnes images. *(Choix de Claude.)*
- Quand un créneau de sortie n'a pas de bonne image disponible, on **répète la dernière bonne image**. *(Choix de Claude.)*
- **Cas dégradé** : si le strobe est si rapide qu'il ne reste presque aucune bonne image sur une période, on prend **l'image la moins brûlée** plutôt que de figer l'écran longtemps. *(Choix de Claude, présenté à l'auteur sans objection.)*
- Piste audio d'origine recopiée intacte dans la version nettoyée.
- Les deux fichiers (original haute cadence + version nettoyée) sont enregistrés dans la pellicule Photos.
- L'original est enregistré tel quel, en haute cadence. Photos risque de l'afficher comme un ralenti : c'est accepté, puisque c'est la version nettoyée qui sert à regarder et à partager. *(Choix de Claude.)*

### 6.5 Écrans (minimal)
- Écran caméra plein écran avec bouton enregistrer et indicateur « exposition de référence prête ».
- Pendant le traitement : indicateur de progression.
- Fin : confirmation que les deux vidéos sont dans la pellicule.

## 7. Invariants

- Le son de la version nettoyée a exactement la durée de l'original et reste synchronisé à ±1 image.
- La version nettoyée a la même durée que l'original.
- Aucune image retenue comme « bonne » n'est un flash évident à l'œil.
- L'original n'est jamais modifié ni supprimé.

## 8. Laissé au builder

- L'algorithme exact de détection d'une image brûlée (luminosité moyenne vs médiane glissante, proportion de pixels saturés, combinaison des deux…) et ses seuils. Doit être réglé sur de vraies vidéos de concert.
- Le choix 120 vs 240 i/s selon les modèles et la qualité en basse lumière (plus de cadence = plus de bonnes images candidates, mais image plus bruitée).
- Les valeurs d'obturation et la stratégie de mesure d'exposition.
- L'optimisation éventuelle « caler l'obturation sur le rythme du strobe » quand il est régulier : bonus, pas requis.
- Résolution de sortie, codec (HEVC/H.264), structure du code, tests.
- L'interface au-delà du strict minimum décrit en §6.5.

## 9. Pistes plus tard (hors V1)

- Nettoyer une vidéo déjà présente dans la pellicule.
- Aperçu nettoyé en direct.
- Publication App Store.

## 10. Version 2 (2026-11-07) — après le premier essai sur iPhone

### Constat du premier essai
- Lampe qui clignote ~5 fois/s, allumée la moitié du temps, seule source dans une pièce sombre.
- L'app n'a retiré presque aucune image : la détection supposait des flashs courts et rares ; avec une lumière allumée 50 % du temps, la médiane glissante prenait la lumière pour l'éclairage normal. La mesure s'est donc réglée sur les images éclairées et les images sans lumière sont sorties presque noires.
- À 120 i/s, chaque image n'a droit qu'à 1/120 s de lumière (4 fois moins que la vidéo normale de l'iPhone à 30 i/s) ; l'app était déjà au maximum (1/120 s, ISO 3456).
- La version nettoyée était bien à vitesse normale ; c'est l'original 120 i/s que Photos affiche au ralenti (accepté).

### Ce que veut l'auteur (ses mots)
- « On devrait idéalement ne voir que les images sans lumière. »
- « Il faut que la vidéo soit reconstituée pour apparaître normalement à 30 ou 24 i/s sans que l'on voie les images manquantes, c'est tout l'intérêt de l'app de faire disparaître la lumière stroboscopique, en respectant l'exposition de la scène comme si ce n'était pas surexposé. »
- « La caméra de l'iPhone est censée pouvoir filmer et dans cette pièce on voyait quand même. L'exposition de l'iPhone s'adapte. »
- « Fais l'app du mieux que tu peux et on teste. » → les choix ci-dessous sont des choix de Claude.

### Changements (choix de Claude)
1. **Détection à deux niveaux de lumière.** Sur une fenêtre glissante (~0,5 s), si la luminosité se sépare en deux groupes nettement distincts, tout le groupe haut est « avec lumière » (retiré), quelle que soit sa proportion (de 1 image sur 120 à plus de la moitié). Un seul groupe = pas de strobe, tout est gardé. Une période « avec lumière » plus longue que ~0,3 s est un changement d'éclairage, pas un strobe. Remplace la médiane glissante, en ligne (mesure) et hors ligne (nettoyage).
2. **Mesure d'exposition sur les images sans lumière**, avec cette nouvelle détection. Conséquence voulue : les images éclairées sortent brûlées, donc faciles à retirer.
3. **Cadence de prise de vue adaptative.** Pendant la mesure, l'app mesure aussi le rythme du strobe (durée des moments sans lumière). Si la scène est trop sombre à 120 i/s (exposition au maximum sans atteindre la cible), l'app passe à 60 i/s (pose jusqu'à 1/60 s), puis à 30 i/s (pose jusqu'à 1/30 s), seulement si chaque moment sans lumière contient encore au moins 4 images à la nouvelle cadence ; sans strobe détecté, elle ne descend pas sous 60 i/s (pour pouvoir retirer un strobe qui démarrerait pendant l'enregistrement). Après un changement de cadence, l'exposition est remesurée ; le compte à rebours repart pour la nouvelle mesure.
4. **Reconstitution fluide à 30 i/s.** Un créneau sans image « sans lumière » n'est plus comblé en répétant la dernière bonne image : l'app recrée des images intermédiaires entre la dernière bonne image avant le trou et la première après (interpolation d'Apple, `VTFrameRateConversion`, iOS 26 / macOS 15.4+). Si l'appareil ne la prend pas en charge, ou si le trou dépasse ~0,35 s, retour au comportement V1 (répéter, puis image la moins brûlée). Le son est inchangé.
5. **Débruitage** des images de la version nettoyée quand la prise de vue a été faite à haute sensibilité (`VTTemporalNoiseFilter`, iOS 26 / macOS 26), si pris en charge.

### Limite assumée
Pour retirer le strobe, chaque image gardée doit être prise pendant un moment sans lumière : la pose ne peut pas dépasser la durée de ces moments. Dans une pièce presque noire avec un strobe rapide, la version nettoyée restera plus sombre que la vidéo normale de l'iPhone (qui, elle, garde les flashs).

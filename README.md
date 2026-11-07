# Anti-Strobo

**Film concerts on your iPhone without the strobe lights.**

At a concert, strobes ruin phone videos: every flash turns the frame white and the auto-exposure pumps from one flash
to the next. Anti-Strobo films at a high frame rate, throws away every frame lit by a flash, and rebuilds a smooth
30 fps video from the frames in between, with the original sound.

*[Version française plus bas.](#en-français)*

## How it works

1. **Before recording, the app measures the light between the flashes** and locks the exposure on it. The iPhone's
   auto-exposure is turned off: frames between flashes are well exposed, lit frames come out clearly burnt, so they are
   easy to find later.
2. **It films at 120 fps**, and drops to 60 or 30 fps in a dark room when the dark moments between flashes are long
   enough, to let more light in.
3. **After recording, it finds every lit frame.** It looks at the whole image, at an 8 × 8 grid of zones (a small lamp
   in a corner barely changes the whole image), at sharp rises and falls in each zone, and at the light of the room as
   a whole, so that camera motion is not taken for a light.
4. **It rebuilds a 30 fps video from the unlit frames.** Missing frames are recreated with Apple's frame interpolation,
   the image is denoised and dark scenes are brightened. The sound is copied unchanged.
5. **Both videos go to your Photos library:** the original and the cleaned version. Everything runs on the device.

## Status

Version 1.0. Tested on an iPhone 17 Pro Max with a strobe lamp flashing about 5 times per second, in a dark room and in
a lit room, filming by hand while walking. Real concert footage is the next big test.

Known limits:

- The frame right next to a flash is sometimes removed even when it is dark.
- During very fast camera moves, a recreated frame can be torn.
- In a nearly black room with a fast strobe, the cleaned video stays darker than the iPhone's own video (which keeps
  the flashes): each kept frame can only be exposed during a dark moment.

## Requirements

- iPhone with iOS 26 or later (the camera is needed: the app does not run usefully in the simulator).
- Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- macOS 26 or later for the command-line tool and the tests.

## Build and run

```bash
xcodegen generate
open AntiStrobo.xcodeproj
```

In `project.yml`, set `DEVELOPMENT_TEAM` to your own team and change `bundleIdPrefix` and `PRODUCT_BUNDLE_IDENTIFIER`,
then run `xcodegen generate` again and run the app on your iPhone.

The app asks iOS for the GPU while it cleans a video in the background (`Config/AntiStrobo.entitlements`, *Background
GPU Access* on the App ID). If your team cannot enable it, remove that entitlement: cleaning still works, more slowly
when the app is in the background.

## Tests and the `strobe-tune` tool

All the logic lives in the Swift package `Packages/StrobeCore`, tested with Swift Testing:

```bash
cd Packages/StrobeCore
swift test
```

`strobe-tune` replays the detection and the cleaning on a recording, on your Mac. It is the tool to tune the
thresholds on real footage:

```bash
cd Packages/StrobeCore
swift run -c release strobe-tune original.mov --out cleaned.mov --csv frames.csv
```

`--help` lists every threshold. The CSV gives one line per frame with its brightness and its verdict.

## Project layout

| Path | Contents |
|---|---|
| `App/Camera` | Capture session, exposure lock, adaptive frame rate, recording |
| `App/Processing` | Cleaning queue, background task, saving to Photos |
| `App/UI` | The single camera screen |
| `Packages/StrobeCore` | Detection (`FlashDetector`, `StepPairDetector`, `RoomLight`), frame selection, video rebuild, tests |
| `docs/superpowers` | Design document and implementation plans (in French), with the numbered rules quoted in the code |
| `scripts/testflight.sh` | Archive and upload to App Store Connect |

The code, its comments and the app are in French.

## Contributing

Issues and pull requests are welcome. The most useful thing you can share is **a real recording where the cleaning
fails**: the original video, the cleaned one, and what you expected.

To send the original as it was filmed, share it from Photos with *Options → All Photos Data*. Otherwise Photos sends a
120 fps video as a slowed-down 30 fps copy, and the timing of the frames is lost.

Before opening a pull request, run `swift test` and say which recordings you checked the change on.

## Privacy

Anti-Strobo collects no data and makes no network connection. See [PRIVACY.md](PRIVACY.md).

## License

[MIT](LICENSE).

---

## En français

**Filmer un concert à l'iPhone sans les stroboscopes.**

En concert, les stroboscopes gâchent les vidéos au téléphone : chaque éclair blanchit l'image, et l'exposition
automatique se dérègle d'un éclair à l'autre. Anti-Strobo filme à haute cadence, retire chaque image éclairée par un
éclair, et reconstruit une vidéo fluide à 30 i/s avec les images d'entre les éclairs, et le son d'origine.

**Comment ça marche**

1. Avant d'enregistrer, l'app mesure la lumière entre les éclairs et y verrouille l'exposition.
2. Elle filme à 120 i/s, et descend à 60 ou 30 i/s dans une salle sombre quand les moments sans éclair sont assez
   longs.
3. Après l'enregistrement, elle repère chaque image éclairée : sur l'image entière, sur une grille de 8 × 8 zones, sur
   les montées et descentes brusques de chaque zone, et sur la lumière de la pièce entière, pour ne pas prendre un
   mouvement de caméra pour une lumière.
4. Elle reconstruit une vidéo à 30 i/s avec les images sans éclair : les images manquantes sont recréées par
   l'interpolation d'Apple, l'image est débruitée et les scènes sombres sont éclaircies. Le son est recopié tel quel.
5. Les deux vidéos, l'original et la version nettoyée, sont rangées dans la pellicule. Tout se passe sur l'iPhone.

**Compiler** : `xcodegen generate`, puis ouvrir `AntiStrobo.xcodeproj`. Dans `project.yml`, mets ton équipe
(`DEVELOPMENT_TEAM`) et ton propre identifiant d'app. **Tests** : `swift test` dans `Packages/StrobeCore`. **Rejouer
un nettoyage sur Mac** : `swift run -c release strobe-tune original.mov --out nettoyee.mov --csv images.csv`.

**Contribuer** : les tickets et les pull requests sont les bienvenus, surtout avec une vraie vidéo où le nettoyage
échoue. Pour envoyer l'original tel qu'il a été filmé, partage-le depuis Photos avec *Options → Toutes les données de
la photo* : sinon Photos envoie une copie ralentie à 30 i/s.

**Confidentialité** : aucune donnée collectée, aucune connexion à Internet ([PRIVACY.md](PRIVACY.md)).
**Licence** : [MIT](LICENSE).

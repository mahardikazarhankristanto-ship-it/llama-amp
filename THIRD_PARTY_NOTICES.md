# Third-party notices

Llama Amp's own code, artwork, startup jingle and example loop are original work under the MIT license
(see `LICENSE`). It includes or builds on the following.

## Butterchurn (MilkDrop visualizer)

`Resources/milkdrop/butterchurn.min.js` — https://github.com/jberg/butterchurn, version 2.6.7.
Copyright (c) 2013-2018 Jordan Berg. MIT License (full text in `Resources/milkdrop/LICENSE-butterchurn`,
also shipped inside the app).

## Butterchurn presets

`Resources/milkdrop/butterchurnPresets*.min.js` — https://github.com/jberg/butterchurn-presets, version 2.4.7.
Copyright (c) 2013-2018 Jordan Berg. MIT License (full text in `Resources/milkdrop/LICENSE-presets`).
The presets themselves were created by members of the MilkDrop community; each preset's title names its authors.
MilkDrop was created by Ryan Geiss.

## GiantSteps Key data set (research data, not included)

The key detector's 24 key profiles (`Sources/KeyDetect.swift`) are averages computed from the GiantSteps Key
data set. No audio or annotations from it are included in this repository. Please cite:

> P. Knees, Á. Faraldo, P. Herrera, R. Vogl, S. Böck, F. Hörschläger, M. Le Goff: "Two data sets for tempo
> estimation and key detection in electronic dance music annotated from user corrections." Proc. of the 16th
> International Society for Music Information Retrieval Conference (ISMIR), 2015.

The data set's audio files are previews owned by Beatport and must not be redistributed; get them with the
download scripts at https://github.com/GiantSteps/giantsteps-key-dataset to run `Tools/KeyBench`.

## Online services the app can use

- **LRCLIB** (https://lrclib.net) for synced lyrics. Lyrics are fetched on the listener's own Mac, cached only
  there, and remain the property of their rights holders.
- **Winamp Skin Museum** (https://skins.webamp.org) for browsing and downloading classic skins. Skins are made by
  their respective authors and are downloaded by the user; none are included with the app.

## Trademarks

Llama Amp is an independent project and is not affiliated with, endorsed by or connected to Winamp or
Llama Group SA. Winamp is a trademark of Llama Group SA. "Winamp" is used here only to describe compatibility
with classic Winamp skins (.wsz) and equalizer preset files (.eqf).

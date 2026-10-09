Munibin native font vendoring — v193

The native builds vendor the selectable Arabic typefaces at build time so the app does not request Google Fonts at runtime.

Families: Amiri, Scheherazade New, Noto Naskh Arabic, Lateef, Cairo, Tajawal.
Source snapshot: fontsource/font-files commit 9c49284c1234358495d88cd7e67fada8a0e10af2 (Google Fonts mirrors).
These families are distributed under the SIL Open Font License (OFL) in their upstream Google Fonts packages.
The actual font binaries are fetched by the native build and copied into the app bundle; they are intentionally not stored as standalone font files in this source delivery.

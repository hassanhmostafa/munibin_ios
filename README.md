# Munibin iOS

Native iOS project, snapshot v440, including the earlier v439 changes.

## Open and build

Open `Munibin.xcworkspace` in Xcode. The project includes its bundled web assets, widget extension, Live Activity, and CocoaPods dependencies. Configure signing for your Apple developer account locally.

## v440 changes

- Display the countdown target's prayer day across the app, widgets and Live Activity, including the transition after Isha iqama and iqama crossing midnight.
- Retain the Live Activity setting across app updates and restore a missing activity on the next authorized foreground launch.
- Improve widget spacing, sunrise placement, Hijri date space, and active prayer underlines.
- Show iqama minute offsets in a lighter version of their prayer clock's color; retain red iqama countdowns.

Source and behavior checks passed. Native build and device validation remain required.

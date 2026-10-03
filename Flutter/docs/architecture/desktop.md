# Desktop application boundary

`Flutter/desktop` owns macOS and Windows lifecycle, navigation, local storage,
editor workspace UI and desktop native adapters. It never imports `Flutter/src`.

Desktop and mobile may share remote contracts and pure domain values through an
existing package only when there are at least two real consumers. Platform
credentials, cache locations, routes, task trackers and native state remain
platform-owned.

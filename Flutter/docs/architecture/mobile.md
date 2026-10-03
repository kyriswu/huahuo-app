# Mobile application boundary

`Flutter/src` owns iOS and Android lifecycle, routes, Riverpod composition,
SQLite/database workers, secure storage, local recording files, Bluetooth/Wi-Fi
bridges, notifications and mobile presentation.

Feature presentation consumes application/domain ports. Feature presentation
must not import another feature's presentation layer. Durable facts belong to
repositories or application state; ephemeral animation, frame and progress
values stay in the smallest owning subtree.

Native calls cross explicit ports. A platform callback must validate account,
entity identity and operation generation before publishing a result.

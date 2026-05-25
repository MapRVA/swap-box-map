# Swap Box Map

A mapping app for Android and iOS, for mapping the following nodes in OpenStreetMap:

- `amenity=public_bookcase`
- `amenity=food_sharing`
- `amenity=give_box`

## Development

Two compile-time flags control which OpenStreetMap servers the app talks to. Pass them with `--dart-define=NAME=true` on `flutter run` or `flutter build`.

| Flag | Default | Effect when `true` |
|---|---|---|
| `USE_DEV_OSM_API` | `true` in debug builds, `false` in release builds | OAuth, sign-in, user details, and changeset uploads target the OSM sandbox at `master.apis.dev.openstreetmap.org` instead of production OSM. |
| `USE_OSM_API_FOR_READS` | `false` | Bbox reads go to `GET /api/0.6/map` on the OSM API instead of Overpass. Required for end-to-end testing against the dev sandbox, which has no Overpass mirror. Raises the minimum fetch zoom (the OSM API caps bbox area at 0.25 sq-deg and doesn't pre-filter by tag, so the app holds off on fetches until you're zoomed in further). |

### Typical configurations

```sh
# Debug run — automatically targets the dev sandbox for writes.
# Reads still hit prod Overpass, so modify/delete flows won't have real
# nodes to act on, but creates work end-to-end and you can verify the
# changeset on the dev web UI.
flutter run

# Dev round-trip: writes and reads both hit the dev sandbox.
flutter run --dart-define=USE_OSM_API_FOR_READS=true

# Production release. Defaults are prod OSM, Overpass reads.
flutter build apk --release
```

### Before shipping a production build

1. Register an OAuth 2.0 application at `https://www.openstreetmap.org/oauth2/applications` with:
   - **Redirect URI:** `swapboxmap://oauth2/redirect`
   - **Confidential application:** No (native/public client)
   - **Permissions:** "Read user preferences" + "Modify the map"
2. Paste the issued client ID into `AppConfig._prodOsmClientId` in `lib/config.dart`, replacing `REGISTER_AT_PROD_AND_PASTE_HERE`.

The dev client ID is already wired in for `USE_DEV_OSM_API=true` builds.

## License

Swap Box Map is released under GPLv3 or any later version.
Please see [LICENSE.md](LICENSE.md) for more information.

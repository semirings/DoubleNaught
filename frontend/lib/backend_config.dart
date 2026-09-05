/// Where the double_touch backend lives.
///
/// DoubleNaught is developed alongside SegForge, which runs its own FastAPI
/// backend, so the two are given fixed non-overlapping ports: DN on 8400,
/// SegForge on 8401. The backend side of this is `DOUBLE_TOUCH_PORT`
/// (see `backend/src/double_touch/__main__.py`); keep the two in step.
///
/// Override at launch when pointing the app at a different host or port:
///
///   ./run.sh DV --dart-define=DN_BACKEND_URL=http://127.0.0.1:9000
///
/// Every `*_api.dart` service defaults its `baseUrl` to [baseUrl], so this is
/// the only place the address is written down. Note the literal `127.0.0.1`
/// rather than `localhost`: on macOS `localhost` can resolve to the IPv6 `::1`
/// while uvicorn is bound to IPv4, which shows up as a connection refusal.
class BackendConfig {
  const BackendConfig._();

  static const String baseUrl = String.fromEnvironment(
    'DN_BACKEND_URL',
    defaultValue: 'http://127.0.0.1:8400',
  );
}

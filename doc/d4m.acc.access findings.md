
18 findings across the codebase. Here's a summary by severity:

**Critical / data-correctness bugs (will silently produce wrong results)**

- [RCVs.java:47](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/RCVs.java#L47) — `String.join` on a `String` argument is a no-op; `toString()` emits no delimiters
- [RCVs.java:56](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/RCVs.java#L56) — `size()` returns character count, not triple count
- [InsertService.java:80](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/InsertService.java#L80) — degree counts are overwritten not accumulated without a `SummingCombiner`
- [QueryService.java:75](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/QueryService.java#L75) — chunk-range logic applied to all single-range queries, returning empty results for literal/regex expressions
- [ScanCriteriaBuilder.java:35](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/ScanCriteriaBuilder.java#L35) — range bounds include grammar quote characters, scanning a key space that contains no data

**NPE / crash bugs**

- [D4MRequest.java:7](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/D4MRequest.java#L7) — `payload` can never be deserialized (no setter, no `@JsonProperty`) — NPE on every request
- [QueryService.java:62](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/QueryService.java#L62) — `parseQuery()` null result used without a null check

**Resource leaks**

- [QueryService.java:91](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/QueryService.java#L91) — `BatchScanner` not in try-with-resources; leaks on any exception (same pattern at line 230)

**Security**

- [AdminService.java:48](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/AdminService.java#L48) — `auth.token` written to TRACE log

**Performance**

- [QueryService.java:110](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/QueryService.java#L110) — Xtext/EMF DI container bootstrapped on every parse call (hundreds of ms)
- [QueryService.java:89](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/QueryService.java#L89) — `getUserAuthorizations` is a network call on every scan
- [BundleToMutationsConverter.java:14](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/main/java/d4m/acc/access/BundleToMutationsConverter.java#L14) — `ObjectMapper` constructed per call (same in `BundleToRCVsConverter`)

**Broken tests**

- [AccumuloAccessTest.java:33](vscode-webview://008ig9uvmvnpt0p8vpspo4lk5a18h8celfam644ivpk1d0rtpbee/fhir-genalytics.platform/d4m.acc.access/src/test/java/d4m/acc/access/AccumuloAccessTest.java#L33) — `new BaseService()` on an abstract class with no no-arg constructor; does not compile
- 
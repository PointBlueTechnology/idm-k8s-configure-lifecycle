# idm-lifecycle-lib

Small Java helpers used inside the OpenText `identityapplication` image (JRE only — no `javac`, no `ldapsearch`/`psql`).

| Class | Purpose |
|-------|---------|
| `LdapCheck` | StartTLS LDAP bind check |
| `PgCheck` | JDBC reachability + list UA/WFE DBs |
| `PgCount` | Count public tables |
| `PgAssert` | Assert a table exists |
| `SeedAuth` | Seed ldap admin into authprops (lab plaintext path) |
| `Wipe` | `DROP SCHEMA public CASCADE` on UA+WFE DBs |

## Build note

Only the compiled `.class` files and fat-ish jar were retained from the lab. Source `.java` was not checked into the original package.

To rebuild from classes (if you have matching sources):

```bash
# with JDK matching the container JRE (11+)
javac -d out src/*.java
jar cf idm-lifecycle-lib.jar -C out .
```

The jar is mounted into Jobs via ConfigMap `${LIFECYCLE_NAME}-lib` as `/lifecycle/lib/idm-lifecycle-lib.jar`.

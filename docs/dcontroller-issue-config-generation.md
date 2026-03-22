# dcontroller Feature Request: @toJson / @toYaml operators for config generation

## Problem

Generating ConfigMaps and Secrets with structured content (JSON configs, YAML configs) currently requires building the entire file as a single `@concat` string with manually escaped quotes and `\n` characters:

```yaml
# Current: homeserver.yaml generation (31 lines of concat)
stringData:
  homeserver.yaml:
    "@concat":
      - "server_name: \""
      - "$.MatrixServerView.spec.synapse.serverName"
      - "\"\n"
      - "public_baseurl: \"https://"
      - "$.MatrixNetworkingView.spec.host"
      - "\"\n"
      - "signing_key_path: \"/data/keys/"
      - "$.MatrixServerView.spec.synapse.signingKey.signingKeyKey"
      - "\"\n\n"
      - "listeners:\n"
      - "  - port: 8008\n"
      - "    type: http\n"
      # ... 20 more lines of escaped strings

# Current: Element config.json (unreadable single line)
data:
  config.json:
    "@concat":
      - "{\"default_server_config\":{\"m.homeserver\":{\"base_url\":\"https://"
      - "$.MatrixNetworkingView.spec.host"
      - "\",\"server_name\":\""
      - "$.MatrixServerView.spec.synapse.serverName"
      - "\"}},\"brand\":\"Element\",\"disable_custom_urls\":true,\"disable_guests\":true}"
```

This is:
- **Error-prone**: one missing `\"` or `\n` breaks the entire config
- **Unreadable**: the structure is invisible — you can't see what the output looks like
- **Unmaintainable**: adding a field means inserting escaped strings in the right position
- **No validation**: typos in key names are silent — the pipeline produces valid YAML/JSON that's wrong

## Proposed Solution: @toJson and @toYaml operators

New operators that take a structured YAML/JSON object (with embedded pipeline expressions) and serialize it to a string:

```yaml
# Proposed: homeserver.yaml generation (readable, structured)
stringData:
  homeserver.yaml:
    "@toYaml":
      server_name: "$.MatrixServerView.spec.synapse.serverName"
      public_baseurl:
        "@concat": ["https://", "$.MatrixNetworkingView.spec.host"]
      signing_key_path:
        "@concat": ["/data/keys/", "$.MatrixServerView.spec.synapse.signingKey.signingKeyKey"]
      listeners:
        - port: 8008
          type: http
          tls: false
          x_forwarded: true
          resources:
            - names: [client, federation]
              compress: false
      database:
        name: psycopg2
        args:
          user: "$.Secret.data['username']"
          password: "$.Secret.data['password']"
          database: "$.MatrixServerView.spec.database.effectiveName"
          host: "$.MatrixServerView.spec.database.effectiveHost"
          port: "$.MatrixServerView.spec.database.effectivePort"
          cp_min: 5
          cp_max: 10

# Proposed: Element config.json (readable, structured)
data:
  config.json:
    "@toJson":
      default_server_config:
        m.homeserver:
          base_url:
            "@concat": ["https://", "$.MatrixNetworkingView.spec.host"]
          server_name: "$.MatrixServerView.spec.synapse.serverName"
      brand: "Element"
      disable_custom_urls: true
      disable_guests: true
      features:
        feature_group_calls: true
        feature_video_rooms: true
```

## Benefits

| Aspect | @concat (current) | @toJson/@toYaml (proposed) |
|--------|-------------------|---------------------------|
| Readability | Single escaped string | Structured YAML matching output shape |
| Error detection | Silent wrong output | Structure validates at parse time |
| Maintainability | Insert escaped fragments | Add/remove keys naturally |
| Lines of code | ~31 lines for homeserver.yaml | ~20 lines, zero escaped characters |
| Learning curve | Must understand escaping | Write what you mean |

## Implementation Notes

- `@toJson` recursively evaluates all pipeline expressions in the object, then serializes to JSON string
- `@toYaml` same but serializes to YAML string
- Nested operators (`@concat`, `@cond`, `@definedOr`) work naturally inside the structured object
- The output is always a string (suitable for ConfigMap `data` or Secret `stringData` values)
- Go's `encoding/json` and `gopkg.in/yaml.v3` handle serialization

## Real-world Impact

The matrix-rtc-operator has 5 config generators using @concat:
- homeserver.yaml (Synapse) — 31 lines of @concat
- livekit.yaml (LiveKit) — 20 lines of @concat
- config.json (Element Web) — 1 unreadable line of @concat
- client well-known — 5 lines of @concat
- server well-known — 3 lines of @concat
- nginx.conf (well-known) — 1 long escaped string

With @toJson/@toYaml, all of these become readable structured YAML.

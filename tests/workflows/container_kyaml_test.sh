#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression tests for the container configs converted in PR #245.
# Usage: bash tests/workflows/container_kyaml_test.sh
# Requires Mike Farah yq with KYAML output support (CI pins v4.53.3).
# No containers, network access, or git history are needed.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# These assertions pin the template's own configs, placeholders included. A
# minted repository has substituted them (container-init) or removed them
# (container narrowing). archetypes/ marks the template, as in
# scripts/check-template-conformance.sh; the mint deletes it.
if [[ ! -d "$repo/archetypes" ]]; then
    echo "SKIP: $repo is not the template (no archetypes/); its container configs belong to the mint"
    exit 0
fi

assert_value() {
    local file=$1 expression=$2 expected=$3 description=$4 actual
    actual=$(yq -p yaml -o json -I 0 "$expression" "$file")
    [[ "$actual" = "$expected" ]] || fail "$description: expected $expected, got $actual"
}
canonical_data() { yq -p yaml -o json -I 0 'sort_keys(..)' "$1"; }

template="$repo/build/container/compose.yaml"
example="$repo/build/container/compose.example.yaml"
policy="$repo/build/container/stapeln/.gatekeeper.yaml"
files=("$template" "$example" "$policy")

for file in "${files[@]}"; do
    # Compare the actual file, including comments and final newline, with the
    # exact yq rendering used by the pinned upstream formatter.
    yq -p yaml -o kyaml '.' "$file" > "$scratch/rendered"
    cmp -s "$file" "$scratch/rendered" || fail "$file is not canonical KYAML"

    # A block-style regression must be detectable even when data is equal.
    yq -p yaml -o yaml -P '.' "$file" > "$scratch/block.yaml"
    [[ "$(canonical_data "$file")" = "$(canonical_data "$scratch/block.yaml")" ]] \
        || fail "$file changed data in a block-style round trip"
    ! cmp -s "$file" "$scratch/block.yaml" || fail "block-style negative control did not change $file"
    yq -p yaml -o kyaml '.' "$scratch/block.yaml" > "$scratch/roundtrip"
    cmp -s "$file" "$scratch/roundtrip" || fail "$file lost formatting or comments in a round trip"
done
echo 'PASS: all three configs are canonical KYAML; block-style drift is distinguishable without data loss'

assert_value "$template" '.services | keys | sort' '["rokur","svalinn","{{SERVICE_NAME}}"]' 'template service names'
assert_value "$template" '.services."{{SERVICE_NAME}}".image' '"{{REGISTRY}}/{{SERVICE_NAME}}:latest"' 'quoted image placeholders'
assert_value "$template" '.services."{{SERVICE_NAME}}".ports' '["{{PORT}}:{{PORT}}"]' 'quoted port placeholders'
assert_value "$template" '.services."{{SERVICE_NAME}}".build' '{"context":"..","dockerfile":"build/container/Containerfile"}' 'template application build paths'
assert_value "$template" '.services."{{SERVICE_NAME}}".environment' '{"APP_HOST":"[::]","APP_PORT":"{{PORT}}","APP_LOG_FORMAT":"json","APP_DATA_DIR":"/data"}' 'template application environment and IPv6 listener'
assert_value "$template" '.services."{{SERVICE_NAME}}".volumes' '["{{SERVICE_NAME}}-data:/data"]' 'template application data mount'
assert_value "$template" '.services."{{SERVICE_NAME}}".healthcheck.test' '["CMD","curl","-sf","http://localhost:{{PORT}}/health"]' 'template health command placeholders'
assert_value "$template" '.services."{{SERVICE_NAME}}".healthcheck.start_period' '"10s"' 'application startup grace period'
assert_value "$template" '.services.rokur.environment.ROKUR_REQUIRED_SECRETS' '""' 'empty secret list remains an empty string'
assert_value "$template" '.services.rokur.depends_on."{{SERVICE_NAME}}".condition' '"service_healthy"' 'health-gated template backend'
assert_value "$template" '.services.svalinn.depends_on' '["rokur"]' 'template gateway waits for the secrets proxy'
assert_value "$template" '.volumes | keys | sort' '["rokur-audit","{{SERVICE_NAME}}-data"]' 'template volume names'

for file in "$template" "$example"; do
    assert_value "$file" '.services.svalinn.ports' '["443:443","80:80"]' 'gateway port mappings remain strings'
    assert_value "$file" '.services.svalinn.environment.SVALINN_TLS_AUTO' '"true"' 'Compose TLS environment value remains a string'
    assert_value "$file" '.services.svalinn.environment.SVALINN_BACKEND' '"http://rokur:8081"' 'gateway routes through the secrets proxy'
    assert_value "$file" '.services.svalinn.environment.SVALINN_POLICY_FILE' '"/etc/svalinn/gatekeeper.yaml"' 'gateway reads the mounted policy path'
    assert_value "$file" '.services.svalinn.volumes' '["./stapeln/.gatekeeper.yaml:/etc/svalinn/gatekeeper.yaml:ro"]' 'policy filename and read-only mount'
    assert_value "$file" '.services.rokur.environment.ROKUR_LISTEN' '"[::]:8081"' 'IPv6 proxy listener'
    assert_value "$file" '.services.rokur.ports' '["8081:8081"]' 'proxy port mapping'
    assert_value "$file" '.services.rokur.volumes' '["rokur-audit:/var/log/rokur"]' 'persistent proxy audit log'
    assert_value "$file" '.services.rokur.environment.ROKUR_AUDIT_LOG' '"/var/log/rokur/audit.jsonl"' 'proxy writes its audit log inside the persistent mount'
    assert_value "$file" '.services.rokur.environment.ROKUR_LOG_FORMAT' '"json"' 'proxy audit log format'
    assert_value "$file" '.services.rokur.image' '"ghcr.io/hyperpolymath/rokur:latest"' 'secrets proxy image'
    assert_value "$file" '.services.svalinn.image' '"ghcr.io/hyperpolymath/svalinn:latest"' 'gateway image'
    assert_value "$file" '.services.rokur.healthcheck.test' '["CMD","curl","-sf","http://localhost:8081/health"]' 'proxy health command'
    assert_value "$file" '.services.svalinn.healthcheck.test' '["CMD","curl","-sf","http://localhost:80/health"]' 'gateway health command'
    assert_value "$file" '[.services[].restart] | unique' '["unless-stopped"]' 'restart policy for every service'
    assert_value "$file" '[.services[].healthcheck.retries] | unique' '[3]' 'health retry counts remain numeric'
    assert_value "$file" '[.services[].healthcheck.interval] | unique' '["30s"]' 'health intervals'
    assert_value "$file" '[.services[].healthcheck.timeout] | unique' '["5s"]' 'health timeouts'
    assert_value "$file" '[.volumes[]] | unique' '[null]' 'empty named-volume declarations remain null'
done

assert_value "$example" '.services | keys | sort' '["elixir-worker","rokur","rust-api","svalinn"]' 'example service names'
assert_value "$example" '.services."rust-api".build' '{"context":"..","dockerfile":"build/container/Containerfile"}' 'application build paths'
assert_value "$example" '.services."rust-api".image' '"ghcr.io/hyperpolymath/myproject-api:latest"' 'example API image'
assert_value "$example" '.services."rust-api".ports' '["8080:8080"]' 'example API port mapping'
assert_value "$example" '.services."rust-api".environment' '{"RUST_LOG":"info","APP_HOST":"[::]","APP_PORT":"8080","APP_LOG_FORMAT":"json","APP_DATA_DIR":"/data"}' 'example API logging, listener, port, and data directory'
assert_value "$example" '.services."rust-api".environment.APP_PORT' '"8080"' 'application port remains a string'
assert_value "$example" '.services."rust-api".volumes' '["api-data:/data"]' 'application data volume'
assert_value "$example" '.services."elixir-worker".image' '"ghcr.io/hyperpolymath/myproject-worker:latest"' 'example worker image'
assert_value "$example" '.services."elixir-worker".ports' '["4000:4000"]' 'worker port mapping'
assert_value "$example" '.services."elixir-worker".environment' '{"API_URL":"http://rust-api:8080/api/v1","MIX_ENV":"prod","APP_LOG_FORMAT":"json","POOL_SIZE":"10"}' 'worker URL and string environment values'
assert_value "$example" '.services."elixir-worker".depends_on."rust-api".condition' '"service_healthy"' 'worker waits for a healthy API'
assert_value "$example" '.services.rokur.depends_on."rust-api".condition' '"service_healthy"' 'proxy waits for a healthy API'
assert_value "$example" '.services.rokur.environment.ROKUR_REQUIRED_SECRETS' '"DATABASE_URL,JWT_SIGNING_KEY"' 'comma-separated required secrets'
assert_value "$example" '.services.rokur.environment.ROKUR_BACKEND' '"http://rust-api:8080"' 'example proxy routes to the API'
assert_value "$example" '.services.svalinn.environment.SVALINN_WORKER_BACKEND' '"http://elixir-worker:4000"' 'gateway worker route'
assert_value "$example" '.services.svalinn.depends_on' '["rokur","elixir-worker"]' 'gateway dependency list'
assert_value "$example" '.services."rust-api".healthcheck.test' '["CMD","curl","-sf","http://localhost:8080/health"]' 'API health command'
assert_value "$example" '.services."elixir-worker".healthcheck.test' '["CMD","curl","-sf","http://localhost:4000/health"]' 'worker health command'
assert_value "$example" '.volumes | keys | sort' '["api-data","rokur-audit"]' 'example data and audit volume declarations'
echo 'PASS: Compose topology, mount paths, health dependencies, and YAML scalar types survive conversion'

# Simulate the literal substitutions used by container-init without prompting.
# Low/high port boundaries and a registry with a port catch quoting regressions.
for port in 1 65535; do
    for file in "$template" "$policy"; do
        sed -e 's|{{SERVICE_NAME}}|demo-api|g' -e "s|{{PORT}}|$port|g" \
            -e 's|{{REGISTRY}}|registry.example.test:5000/team|g' "$file" > "$scratch/$(basename "$file")"
    done
    minted="$scratch/compose.yaml"
    assert_value "$minted" '.services | keys | sort' '["demo-api","rokur","svalinn"]' 'minted service key'
    assert_value "$minted" '.services."demo-api".image' '"registry.example.test:5000/team/demo-api:latest"' 'registry and image substitution'
    assert_value "$minted" '.services."demo-api".ports' "[\"$port:$port\"]" 'boundary port mapping'
    assert_value "$minted" '.services."demo-api".environment.APP_PORT' "\"$port\"" 'minted port remains a string'
    assert_value "$minted" '.services."demo-api".healthcheck.test' "[\"CMD\",\"curl\",\"-sf\",\"http://localhost:$port/health\"]" 'minted health URL'
    assert_value "$minted" '.services.rokur.environment.ROKUR_BACKEND' "\"http://demo-api:$port\"" 'minted proxy backend' # NOSONAR shell:S5332: asserts an in-network compose backend URL fixture
    assert_value "$minted" '.services.rokur.depends_on."demo-api".condition' '"service_healthy"' 'minted dependency key'
    # A lookup alone also returns null for a missing key. Check membership
    # before its null value so a deleted volume declaration cannot pass.
    assert_value "$minted" '.volumes | keys | sort' '["demo-api-data","rokur-audit"]' 'minted volume declaration names'
    assert_value "$minted" '.volumes."demo-api-data" | tag' '"!!null"' 'minted empty volume declaration'
    assert_value "$minted" '.services."demo-api".volumes' '["demo-api-data:/data"]' 'minted application mounts its declared volume'
    assert_value "$scratch/.gatekeeper.yaml" '.trust.trusted_signers' '[{"key_id":"demo-api-release","algorithm":"Ed25519","public_key_file":"/etc/svalinn/keys/demo-api-release.pub"}]' 'minted signer identity and key path without extra trusted signers'
done
echo 'PASS: container-init substitutions preserve service references and string ports at 1 and 65535'

# Both recipes refuse a value before writing anything when it would make an
# image reference container tooling rejects. Each refused value is a mutant
# of an accepted one, so a check that accepts everything fails here.
check_values() { bash "$repo/scripts/format-container-kyaml.sh" --check-values "$@" 2>/dev/null; }
for registry in ghcr.io/acme localhost:5000/team host:65535/team registry.example.com '[2001:db8::1]:5000/team' '[::1]/x' '[::]' '[1:2:3:4:5:6:7:8]' '[1:2:3:4:5:6::8]'; do
    check_values demo-api 8080 "$registry" || fail "registry '$registry' was refused"
done
for registry in / ghcr.io/Acme host:bad-port ghcr.io//acme ghcr.io/ '[]' '[2001:db8::1' '2001:db8::1:5000/team' '[g::1]' '[::1]:' 'ghcr.io/a|b' host:0/team host:65536/team '[::1]:70000/team' \
    '[::::]:5000/team' '[1::2::3]/team' '[:1::2]' '[1::2:]' '[1:2:3]' '[1:2:3:4:5:6:7:8:9]' '[1::2:3:4:5:6:7:8]' '[12345::1]'; do
    ! check_values demo-api 8080 "$registry" || fail "registry '$registry' was accepted"
done
# The service name is also a bare TOML key and a hostname, so it is a DNS
# label: a dot would nest stapeln/compose.toml's table, an underscore is no
# hostname, and a label is at most 63 characters.
long63=$(printf 'a%.0s' {1..63})
for name in demo-api a a1 "$long63"; do check_values "$name" 8080 ghcr.io/acme || fail "service name '$name' was refused"; done
for name in Demo-Api -api api- a.b a_b a__b 'a b' 'a"b' '' "${long63}a"; do ! check_values "$name" 8080 ghcr.io/acme || fail "service name '$name' was accepted"; done
for port in 0 65536 08x ''; do ! check_values demo-api "$port" ghcr.io/acme || fail "port '$port' was accepted"; done
sed -e 's|{{SERVICE_NAME}}|demo-api|g' -e 's|{{PORT}}|8080|g' \
    -e 's|{{REGISTRY}}|[2001:db8::1]:5000/team|g' "$template" > "$scratch/compose-v6.yaml"
assert_value "$scratch/compose-v6.yaml" '.services."demo-api".image' '"[2001:db8::1]:5000/team/demo-api:latest"' 'bracketed IPv6 registry substitution'
echo 'PASS: --check-values accepts DNS-label service names and image-prefix registries (IPv6 included) and refuses malformed values'

assert_value "$policy" '.version' '"1.0"' 'policy version remains a string'
assert_value "$policy" '.auth.public' '[{"path":"/health","methods":["GET"]},{"path":"/ready","methods":["GET"]},{"path":"/metrics","methods":["GET"]}]' 'public probes require GET'
assert_value "$policy" '.auth.authenticated' '[{"path":"/api/v1/*","methods":["GET","POST","PUT","DELETE"]}]' 'application routes require authentication'
assert_value "$policy" '.rate_limits.global' '{"requests_per_second":500,"burst":1000}' 'numeric global rate limits'
assert_value "$policy" '.rate_limits.writes' '{"paths":["/api/v1/*"],"methods":["POST","PUT","DELETE"],"requests_per_second":100,"burst":200}' 'stricter write limits and path glob'
assert_value "$policy" '.trust.required_attestations' '["source-signature","sbom-complete"]' 'required container attestations'
assert_value "$policy" '.trust.trusted_signers' '[{"key_id":"{{SERVICE_NAME}}-release","algorithm":"Ed25519","public_key_file":"/etc/svalinn/keys/{{SERVICE_NAME}}-release.pub"}]' 'only the project release signer is trusted'
assert_value "$policy" '.trust.reject_unsigned' 'true' 'unsigned containers are rejected with a boolean'
assert_value "$policy" '.validation' '{"max_body_size":"8MB","reject_nan_inf":true,"max_result_limit":500}' 'request validation limits and boolean'
assert_value "$policy" '.cors' '{"allow_origins":["*"],"allow_methods":["GET","POST","PUT","DELETE","OPTIONS"],"allow_headers":["Content-Type","Authorization"],"max_age":3600}' 'CORS wildcard is a string, with numeric max age'
assert_value "$policy" '.logging' '{"format":"json","level":"info","audit_paths":["/api/v1/*"]}' 'structured audit logging and literal glob'
echo 'PASS: gatekeeper authentication, trust, rate limits, validation, CORS, and auditing survive conversion'

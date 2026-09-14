#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
validation_dir="$(mktemp -d /tmp/codexwatch-relay-validation.XXXXXX)"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$validation_dir"
}
trap cleanup EXIT INT TERM

cd "$root_dir"

xcrun swiftc Shared/CodexModels.swift Shared/CloudRelayProtocol.swift \
  Tests/CloudRelayProtocolValidation.swift -o "$validation_dir/protocol"
"$validation_dir/protocol"

xcrun swiftc Shared/CodexModels.swift Tests/PendingTextCommandOutboxValidation.swift \
  -o "$validation_dir/pending-command-outbox"
"$validation_dir/pending-command-outbox"

xcrun swiftc Shared/CodexModels.swift Shared/CloudRelayProtocol.swift \
  Shared/BlindMailboxState.swift Tests/BlindMailboxConcurrencyValidation.swift \
  -o "$validation_dir/concurrency"
"$validation_dir/concurrency"

xcrun swiftc Shared/CodexModels.swift Bridge/CloudRelayOutbox.swift \
  Tests/CloudRelayOutboxValidation.swift -o "$validation_dir/outbox"
"$validation_dir/outbox"

xcrun swiftc Shared/CodexModels.swift Shared/CloudRelayProtocol.swift \
  Shared/BlindMailboxHTTPClient.swift Bridge/CloudRelayOutbox.swift \
  Bridge/CloudVoiceInbox.swift Bridge/BridgeCloudMailboxConsumer.swift \
  Tests/BridgeCloudMailboxConsumerValidation.swift -o "$validation_dir/consumer"
"$validation_dir/consumer"

test_secret_url="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
test_secret_base64="${test_secret_url}="
python3 Tests/mock_mailbox_server.py --port 0 --secret "$test_secret_url" \
  > "$validation_dir/server.log" 2>&1 &
server_pid="$!"
for _ in {1..50}; do
  [[ -s "$validation_dir/server.log" ]] && break
  sleep 0.1
done
server_port="$(head -1 "$validation_dir/server.log")"
[[ "$server_port" == <-> ]] || { print -u2 "Mock mailbox did not start"; exit 1; }

xcrun swiftc Shared/CodexModels.swift Shared/CloudRelayProtocol.swift \
  Shared/BlindMailboxHTTPClient.swift Tests/BlindMailboxHTTPClientValidation.swift \
  -o "$validation_dir/http"
"$validation_dir/http" "http://127.0.0.1:$server_port" "$test_secret_base64"

print "All independent Watch transport validations passed"

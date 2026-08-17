#!/bin/sh
set -eu

BASE_CONFIG=/etc/dogeos/dogecoin.conf
RUNTIME_CONFIG=/run/dogeos/dogecoin.conf
RPC_USER_FILE=/run/secrets/dogecoin_rpc_user
RPC_PASSWORD_FILE=/run/secrets/dogecoin_rpc_password

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

read_secret() {
  secret_path=$1
  secret_name=$2

  [ -r "$secret_path" ] || fail "$secret_name secret is missing or unreadable: $secret_path"
  exec 3< "$secret_path"
  secret_value=
  IFS= read -r secret_value <&3 || [ -n "$secret_value" ] || fail "$secret_name secret must not be empty"
  extra_line=
  if IFS= read -r extra_line <&3 || [ -n "$extra_line" ]; then
    fail "$secret_name secret must contain exactly one line"
  fi
  exec 3<&-

  case "$secret_value" in
    *[!A-Za-z0-9._~:@%+=,-]*)
      fail "$secret_name secret contains unsupported characters"
      ;;
  esac

  printf '%s' "$secret_value"
}

[ -r "$BASE_CONFIG" ] || fail "Dogecoin base configuration is missing: $BASE_CONFIG"

rpc_user=$(read_secret "$RPC_USER_FILE" dogecoin_rpc_user)
rpc_password=$(read_secret "$RPC_PASSWORD_FILE" dogecoin_rpc_password)

umask 077
mkdir -p "$(dirname "$RUNTIME_CONFIG")"
cp "$BASE_CONFIG" "$RUNTIME_CONFIG"
{
  printf '\n# Injected from Docker secrets.\n'
  printf 'rpcuser=%s\n' "$rpc_user"
  printf 'rpcpassword=%s\n' "$rpc_password"
} >> "$RUNTIME_CONFIG"
chmod 600 "$RUNTIME_CONFIG"

exec "$@"

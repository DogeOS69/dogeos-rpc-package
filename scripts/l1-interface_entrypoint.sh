#!/bin/sh
set -eu

RPC_USER_FILE=/run/secrets/dogecoin_rpc_user
RPC_PASSWORD_FILE=/run/secrets/dogecoin_rpc_password
DATA_DIR=/data

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

mkdir -p "$DATA_DIR"
[ -w "$DATA_DIR" ] || fail "L1 Interface data directory is not writable: $DATA_DIR (check DATA_ROOT and host ownership)"

dogecoin_rpc_url=${DOGEOS_L1_INTERFACE_DOGECOIN_RPC__URL:-}
if [ -z "$dogecoin_rpc_url" ]; then
  dogecoin_rpc_url=${DOGEOS_RPC_PACKAGE_DOGECOIN_RPC_URL:-}
  [ -n "$dogecoin_rpc_url" ] || fail "RPC package Dogecoin URL is not configured"
  DOGEOS_L1_INTERFACE_DOGECOIN_RPC__URL=$dogecoin_rpc_url
  export DOGEOS_L1_INTERFACE_DOGECOIN_RPC__URL
fi

case "$dogecoin_rpc_url" in
  http://dogecoin-node|http://dogecoin-node:*|https://dogecoin-node|https://dogecoin-node:*)
    if [ -z "${DOGEOS_L1_INTERFACE_DOGECOIN_RPC__USER:-}" ]; then
      DOGEOS_L1_INTERFACE_DOGECOIN_RPC__USER=$(read_secret "$RPC_USER_FILE" dogecoin_rpc_user)
      export DOGEOS_L1_INTERFACE_DOGECOIN_RPC__USER
    fi

    if [ -z "${DOGEOS_L1_INTERFACE_DOGECOIN_RPC__PASS:-}" ]; then
      DOGEOS_L1_INTERFACE_DOGECOIN_RPC__PASS=$(read_secret "$RPC_PASSWORD_FILE" dogecoin_rpc_password)
      export DOGEOS_L1_INTERFACE_DOGECOIN_RPC__PASS
    fi
    ;;
  *)
    # External RPC: its provider-specific authentication comes only from the
    # explicit l1-interface.local.env override, never from bundled-node secrets.
    ;;
esac

exec /usr/local/bin/l1_interface "$@"

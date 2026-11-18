# shellcheck shell=bash
CA_DIR="$STATE_DIR/ca"
CA_CRT="$CA_DIR/sandbox-root-ca.crt"
CA_KEY="$CA_DIR/sandbox-root-ca.key"
export CA_DIR CA_CRT CA_KEY

ca_exists() {
  [[ -s "$CA_CRT" && -s "$CA_KEY" ]] &&
    openssl x509 -noout -checkend 2592000 -in "$CA_CRT" >/dev/null
}

ca_create() {
  install -d -m 0700 "$CA_DIR"
  local subject="/O=kubeconsandbox/CN=kubeconsandbox sandbox root CA ($(hostname -s))"
  run openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -days 3650 -subj "$subject" -out "$CA_CRT" -keyout "$CA_KEY" \
    -addext basicConstraints=critical,CA:TRUE,pathlen:1 \
    -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
  if [[ "$DRY_RUN" != 1 ]]; then chmod 0600 "$CA_KEY"; fi
}

ca_issue() {
  local name=$1 days=$2 hosts=$3 issued="$CA_DIR/issued"
  local certificate="$issued/$name.crt" key="$issued/$name.key" request="$issued/$name.csr"
  local first_host=${hosts%%,*} current_hosts
  if [[ -s "$certificate" ]] && openssl x509 -noout -checkend 604800 -in "$certificate" >/dev/null; then
    current_hosts=$(openssl x509 -noout -ext subjectAltName -in "$certificate" |
      sed '1d; s/ //g; s/IPAddress:/IP:/g')
    if [[ "$current_hosts" == "$hosts" ]]; then return 0; fi
  fi
  mkdir -p "$issued"
  if [[ "$DRY_RUN" == 1 ]]; then
    run openssl "(issue $name for $hosts)"
    return 0
  fi

  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj "/O=kubeconsandbox/CN=${first_host#*:}" -keyout "$key" -out "$request" 2>/dev/null
  openssl x509 -req -in "$request" -days "$days" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial -out "$certificate" \
    -extfile <(printf '%s\n' "subjectAltName=$hosts" 'basicConstraints=critical,CA:FALSE' \
      'keyUsage=critical,digitalSignature' 'extendedKeyUsage=serverAuth') 2>/dev/null
  cat "$CA_CRT" >> "$certificate"
  chmod 0600 "$key"
  rm -f "$request"
  ok "Issued $name for $hosts"
}

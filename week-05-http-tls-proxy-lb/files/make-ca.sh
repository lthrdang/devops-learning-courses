#!/usr/bin/env bash
#
# make-ca.sh - create a local Certificate Authority and issue a server cert.
#
# This is exactly what a public CA does, minus the business of verifying that
# you own the domain. Doing it by hand once removes all the mystery from TLS.
#
#   ./make-ca.sh app.lab.local 10.0.0.11
#
# It builds a THREE-level chain - root -> intermediate -> leaf - because that
# is what every public CA does and what every real chain problem is about. A
# root that signs leaves directly cannot teach you the single most common TLS
# bug in production: a server that forgets to send the intermediate.
#
set -euo pipefail

CN=${1:?usage: make-ca.sh <common-name> [extra-san-ip ...]}
shift || true
OUT=${OUT:-./tls}
DAYS=${DAYS:-825}          # browsers reject leaf certs valid for much longer

mkdir -p "$OUT"
cd "$OUT"

# --- 1. the root CA --------------------------------------------------------
# The root CA private key is the crown jewel. Anyone holding it can mint a
# certificate for ANY name that your machines will then trust completely.
# Real CAs keep it offline in a safe and use it perhaps once a year - only to
# sign intermediates, never to sign a server certificate. That is exactly the
# shape we build here.
if [[ ! -f ca.key ]]; then
  echo "==> creating ROOT CA"
  openssl genrsa -out ca.key 4096
  chmod 600 ca.key
  # keyUsage is explicit and critical. A CA certificate that does not assert
  # keyCertSign is not usable as a CA by a strict verifier, and "it works in
  # openssl but not in Go/Java" is usually a missing or wrong keyUsage.
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -subj "/C=VN/O=Lab CA/CN=Lab Root CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out ca.crt
fi

# --- 2. the intermediate CA ------------------------------------------------
# The intermediate is the key that is actually online and signing things all
# day. If it is compromised you revoke it and issue a new one; the root - and
# therefore the trust store on every client in the world - never has to change.
# That is the entire reason intermediates exist.
#
# pathlen:0 means "this CA may sign leaves, but may NOT sign another CA". It
# is the cheapest possible limit on the blast radius, and costs nothing.
if [[ ! -f int.key ]]; then
  echo "==> creating INTERMEDIATE CA"
  openssl genrsa -out int.key 4096
  chmod 600 int.key
  openssl req -new -key int.key \
    -subj "/C=VN/O=Lab CA/CN=Lab Intermediate CA" -out int.csr
  cat > int.ext <<'EXT'
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage         = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
EXT
  openssl x509 -req -in int.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out int.crt -days 1825 -sha256 -extfile int.ext
fi

# --- 3. the server key and CSR --------------------------------------------
echo "==> creating key and CSR for ${CN}"
openssl genrsa -out "${CN}.key" 2048
chmod 600 "${CN}.key"
openssl req -new -key "${CN}.key" -subj "/C=VN/O=Lab/CN=${CN}" -out "${CN}.csr"

# --- 4. the SAN extension --------------------------------------------------
# MODERN CLIENTS IGNORE THE CN ENTIRELY. Only subjectAltName is consulted.
# A certificate without a SAN is rejected by every current browser and by curl,
# no matter how correct the CN looks. This is the #1 cause of "I made a cert and
# it still says hostname mismatch".
#
# DNS and IP entries are numbered in SEPARATE sequences - DNS.1, DNS.2, ... and
# IP.1, IP.2, ... - because they are two independent lists. Sharing one counter
# across both leaves gaps like `IP.1` then `IP.12`, which openssl silently
# tolerates but which makes the file impossible to read back.
{
  echo "subjectAltName = @alt"
  echo "basicConstraints = CA:FALSE"
  echo "keyUsage = digitalSignature, keyEncipherment"
  echo "extendedKeyUsage = serverAuth"
  echo "authorityKeyIdentifier = keyid:always"
  echo "[alt]"
  echo "DNS.1 = ${CN}"
  echo "DNS.2 = localhost"
  dns=3
  ip=1
  for extra in "$@"; do
    if [[ $extra =~ ^[0-9.]+$ ]]; then
      echo "IP.${ip} = ${extra}"; ip=$(( ip + 1 ))
    else
      echo "DNS.${dns} = ${extra}"; dns=$(( dns + 1 ))
    fi
  done
  echo "IP.${ip} = 127.0.0.1"
} > "${CN}.ext"

# --- 5. sign, with the INTERMEDIATE ---------------------------------------
# Note the -CA/-CAkey: the root is not involved here at all. If you sign the
# leaf with the root instead, the chain collapses to two levels and every
# "missing intermediate" experiment in the lab becomes impossible to stage.
echo "==> signing with the lab INTERMEDIATE CA"
openssl x509 -req -in "${CN}.csr" -CA int.crt -CAkey int.key -CAcreateserial \
  -out "${CN}.crt" -days "$DAYS" -sha256 -extfile "${CN}.ext"

# --- 6. the chain file -----------------------------------------------------
# Nginx wants leaf FIRST, then intermediates, in one file. Order matters.
#
# THE ROOT IS DELIBERATELY NOT IN HERE. Clients already have the root, or they
# do not trust you at all - sending it wastes bytes on every single handshake
# and proves nothing. What the server MUST send is every intermediate between
# its leaf and that root, because the client has no way to fetch them.
cat "${CN}.crt" int.crt > "${CN}.fullchain.crt"

echo
echo "==> done, in $(pwd):"
echo "    ca.crt                  ROOT - install this on CLIENTS to trust the lab"
echo "    int.crt                 INTERMEDIATE - served by nginx, never installed"
echo "    ${CN}.key               server private key (mode 600)"
echo "    ${CN}.fullchain.crt     give this to nginx as ssl_certificate"
echo
openssl x509 -in "${CN}.crt" -noout -subject -issuer -dates -ext subjectAltName

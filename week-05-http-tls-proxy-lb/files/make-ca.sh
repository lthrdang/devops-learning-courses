#!/usr/bin/env bash
#
# make-ca.sh - create a local Certificate Authority and issue a server cert.
#
# This is exactly what a public CA does, minus the business of verifying that
# you own the domain. Doing it by hand once removes all the mystery from TLS.
#
#   ./make-ca.sh app.lab.local 10.0.0.11
#
set -euo pipefail

CN=${1:?usage: make-ca.sh <common-name> [extra-san-ip ...]}
shift || true
OUT=${OUT:-./tls}
DAYS=${DAYS:-825}          # browsers reject leaf certs valid for much longer

mkdir -p "$OUT"
cd "$OUT"

# --- 1. the CA -------------------------------------------------------------
# The CA private key is the crown jewel. Anyone holding it can mint a
# certificate for ANY name that your machines will then trust completely.
if [[ ! -f ca.key ]]; then
  echo "==> creating CA"
  openssl genrsa -out ca.key 4096
  chmod 600 ca.key
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -subj "/C=VN/O=Lab CA/CN=Lab Root CA" \
    -out ca.crt
fi

# --- 2. the server key and CSR --------------------------------------------
echo "==> creating key and CSR for ${CN}"
openssl genrsa -out "${CN}.key" 2048
chmod 600 "${CN}.key"
openssl req -new -key "${CN}.key" -subj "/C=VN/O=Lab/CN=${CN}" -out "${CN}.csr"

# --- 3. the SAN extension --------------------------------------------------
# MODERN CLIENTS IGNORE THE CN ENTIRELY. Only subjectAltName is consulted.
# A certificate without a SAN is rejected by every current browser and by curl,
# no matter how correct the CN looks. This is the #1 cause of "I made a cert and
# it still says hostname mismatch".
{
  echo "subjectAltName = @alt"
  echo "basicConstraints = CA:FALSE"
  echo "keyUsage = digitalSignature, keyEncipherment"
  echo "extendedKeyUsage = serverAuth"
  echo "[alt]"
  echo "DNS.1 = ${CN}"
  echo "DNS.2 = localhost"
  i=1
  for extra in "$@"; do
    if [[ $extra =~ ^[0-9.]+$ ]]; then
      echo "IP.${i} = ${extra}"; i=$(( i + 1 ))
    else
      echo "DNS.$(( i + 2 )) = ${extra}"; i=$(( i + 1 ))
    fi
  done
  echo "IP.$(( i + 10 )) = 127.0.0.1"
} > "${CN}.ext"

# --- 4. sign ---------------------------------------------------------------
echo "==> signing with the lab CA"
openssl x509 -req -in "${CN}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out "${CN}.crt" -days "$DAYS" -sha256 -extfile "${CN}.ext"

# --- 5. the chain file -----------------------------------------------------
# Nginx wants leaf FIRST, then intermediates, in one file. Order matters.
cat "${CN}.crt" ca.crt > "${CN}.fullchain.crt"

echo
echo "==> done, in $(pwd):"
echo "    ca.crt                  install this on CLIENTS to trust the lab"
echo "    ${CN}.key               server private key (mode 600)"
echo "    ${CN}.fullchain.crt     give this to nginx as ssl_certificate"
echo
openssl x509 -in "${CN}.crt" -noout -subject -issuer -dates -ext subjectAltName

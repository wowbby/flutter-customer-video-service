#!/usr/bin/env bash
set -euo pipefail
rtc_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rtc_sdk_dir="$rtc_root/libs"
rtc_sdk="$rtc_sdk_dir/agora_rtc_sdk-4.4.2.har"
rtc_sha=99128bde4499bd080f66f00d8767c39726ac00335b0afecff682c02cf903729b
mkdir -p "$rtc_sdk_dir"
if [[ ! -f "$rtc_sdk" ]]; then
  curl --fail --location --retry 3 --output "$rtc_sdk.download" https://download.agora.io/sdk/release/Agora_Native_SDK_for_HarmonyOS_v4.4.2_FULL.har
  printf '%s  %s\n' "$rtc_sha" "$rtc_sdk.download" | shasum -a 256 -c -
  mv "$rtc_sdk.download" "$rtc_sdk"
fi
printf '%s  %s\n' "$rtc_sha" "$rtc_sdk" | shasum -a 256 -c -

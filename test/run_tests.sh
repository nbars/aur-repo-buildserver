#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "$DIR"

export AUR_REPO_BUILDSERVER_TEST=true
. ./../buildserver.sh --pkg-configs $DIR/configs --repo-dir $DIR/repo --action clean,build

function arrayEQ() {
  local arr0=( $1 )
  local arr1=( $2 )

  arr0=( $(printf "%s\n" "${arr0[@]}" | sort -u) )
  arr1=( $(printf "%s\n" "${arr1[@]}" | sort -u) )

  assertEQ "${arr0[*]}" "${arr1[*]}" "$3"
}

function assertEQ() {
  if [[ "$1" != "$2" ]]; then
    echo "$(txt_red)$3:Assertion failed (Expected=$2 / Value=$1) $(txt_reset)"
  fi
}

function test_config_parse() {
  ParsePackageConfig "$PWD/configs/cutecom.conf"
  assertEQ "${__result[name]}" "cutecom" "$LINENO"
  assertEQ "${__result[disabled]}" "false" "$LINENO"
  assertEQ "${__result[val_01]}" "123ABC" "$LINENO"
  unset __result
}

function test_cower() {
  CowerGetDeps "cutecom"
  assertEQ "$__result" "qt5-serialport" "$LINENO"

  local expected=( "ccnet"  "seafile"  "qt5-tools"  "qt5-webkit"  "qt5-base"  "gtk-update-icon-cache"  "qt5-webengine" )
  CowerGetDeps "seafile-client"
  assertEQ "${__result[*]}" "${expected[*]}" "$LINENO"

}

test_config_parse
test_cower


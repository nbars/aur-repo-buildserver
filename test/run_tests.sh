#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "$DIR"
exit_code=0

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
    echo "$(txt_red)$(txt_bold)"
    echo "------------------------------------"
    echo "=> Assertion failed"
    echo "=> Line: $3"
    echo "=> Value: \"$1\""
    echo "=> Expected: \"$2\""
    echo "------------------------------------"
    echo "$txt_reset"
    exit_code=1
  fi
}

function test_config_parse() {
  ParsePackageConfig "$PWD/configs/cutecom.conf"
  assertEQ "${__result[name]}" "cutecom" "$LINENO"
  assertEQ "${__result[disabled]}" "false" "$LINENO"
  assertEQ "${__result[val_01]}" "\$123ABC" "$LINENO"
  unset __result

  ParsePackageConfig "$PWD/configs/malformed.noconf"
  assertEQ "$?" "$ERROR" "$LINENO"

}

function test_cower() {
  CowerGetDeps "cutecom"
  assertEQ "$__result" "qt5-serialport" "$LINENO"

  local expected=( "ccnet"  "seafile"  "qt5-tools"  "qt5-webkit"  "qt5-base"  "gtk-update-icon-cache"  "qt5-webengine" )
  CowerGetDeps "seafile-client"
  arrayEQ "${__result[*]}" "${expected[*]}" "$LINENO"
}

function test_PkgX() {
  local pkg_path="$PWD/packages/xorg-server-common-1.19.1-5-x86_64.pkg.tar.xz"

  PkgGetName "$pkg_path"
  assertEQ "$__result" "xorg-server-common"

  PkgGetVersion "$pkg_path"
  assertEQ "$__result" "1.19.1-5"
}

#Run tests
test_config_parse
test_cower
test_PkgX

CleanUp

#Returns 1 if any test failed
exit $exit_code
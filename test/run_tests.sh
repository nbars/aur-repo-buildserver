#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "$DIR"

#Is set to 1 if any assert fails
exit_code=0

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

function SetUp() {
  mkdir -p "$DIR/repo"
  mkdir -p "$DIR/packages"
  cp $DIR/packages_template/* "$DIR/packages/"
}

function TearDown() {
  rm -rf "$DIR/repo"
  rm -rf "$DIR/packages"
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
  assertEQ "$__result" "xorg-server-common" "$LINENO"

  PkgGetVersion "$pkg_path"
  assertEQ "$__result" "1.19.1-5" "$LINENO"
}

function test_RepoX() {
  local err=0

  local pkg_path="$DIR/packages/xorg-server-common-1.19.1-5-x86_64.pkg.tar.xz"

  RepoMovePackage "$pkg_path"
  #Restore content of package folder
  SetUp

  PkgGetName "$pkg_path"
  local name="$__result"
  assertEQ "$name" "xorg-server-common" "$LINENO"

  RepoGetPackageVersion "$name"
  assertEQ "$?" "$SUCCESS" "$LINENO"
  assertEQ "$__result" "1.19.1-5" "$LINENO"

  RepoRemovePackage "$name"

  RepoGetPackageVersion "$name"
  assertEQ "$?" "$ERROR" "$LINENO"
}

function test_AurDepsResolver() {
  PackageGetAurDepsRec "seafile-client"
  echo "xyxy${__result[*]}"
  arrayEQ "${__result[*]}" "ccnet seafile ccnet-server ccnet libsearpc ccnet-server libsearpc" "$LINENO"
}

rm -rf "$DIR/repo"
rm -rf "$DIR/packages"

#Create directory structure
SetUp

export AUR_REPO_BUILDSERVER_TEST=true
. ./../buildserver.sh --pkg-configs $DIR/configs --repo-dir $DIR/repo --action clean,build --debug


#Run tests
test_config_parse
test_cower
test_PkgX
test_RepoX
test_AurDepsResolver

#Delete all used dirs
TearDown

#Cleanup from buildserver.sh
CleanUp

#Returns 1 if any test failed
exit $exit_code
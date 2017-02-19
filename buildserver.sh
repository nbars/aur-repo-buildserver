#!/bin/bash

set -o pipefail

function txt_bold {
  tput bold 2> /dev/null
}

function txt_reset {
  tput sgr0 2> /dev/null
}

function txt_red {
  tput setaf 1 2> /dev/null
}

function txt_green {
  tput setaf 2 2> /dev/null
}

function txt_yellow {
  tput setaf 3 2> /dev/null
}

function PrintUsage() {

if [[ ! -z "$1" ]]; then
  echo -e $(txt_red; txt_bold)"$1\n"$(txt_reset)
fi

cat <<EOF
Package building, updating and so forth:
  $0 [--pkg-configs packages config dir] [--repo-dir path] [--action action] [OPTION]...

$(txt_bold)Required argument$(txt_reset)
  $(txt_red)--action $(txt_green) action $(txt_reset)
  The action that should be performed by the buildserver.
  Possible values are the following:
    $(txt_green)build $(txt_reset)
      This action will build/update all targets defined by a config file in the
      --pkg-configs directory.
    $(txt_green)clean $(txt_reset)
      This action will delete all packages from the repository that have no
      associated config files in the --pkg-configs directory.

  $(txt_red)--repo-dir $(txt_green) path $(txt_reset)
    Path must point to an directory where the repo database should be created.
    If in the given directory a database already exists, it will be update.

  $(txt_red)--pkg-configs $(txt_green) path $(txt_reset)
    Path to a directory that contains multiple package configuration files.


$(txt_bold)OPTIONS$(txt_reset)
  $(txt_red)--work-dir $(txt_green) path $(txt_reset)
    Directory where packages are build.
    Default value is \$HOME/.cache/aur-repo-buildserver

  $(txt_red)--repo-name $(txt_green) name $(txt_reset)
    The name of the repository to create/update.
    This name must be later used as the "repository tag"
    in you're pacman conf e.g.
      [aur-repo] <<< TAG
      SigLevel = ...
      Server = https://...

  $(txt_red)--debug $(txt_reset)
    Enable output of debugging messages.

  $(txt_red)--admin-mail $(txt_green) mail address $(txt_reset)
    The mail address of the admin. To this email address a mail
    is send, every time an error accours.
EOF

exit 1
}


########## Logging ##########

function IndentInc() {
  indent=$(( indent + 3 ))
}

function IndentDec() {
  if [[ $(( indent - 3)) < 0 ]]; then
    indent=0
  else
    indent=$(( indent - 3 ))
  fi
}

function IndentRst() {
  indent=0
}

function ArgumentParsingError() {
  echo "$(txt_red)$(txt_bold)$1$(txt_reset)"
  exit 1
}

function LogStdout() {
  local curr_date="$(date +'%d.%m.%y-%H:%M:%S')"
  local indent_str="$(head -c "$indent" < /dev/zero | tr '\0' ' ')"
  local msg="[$curr_date]$indent_str $1 $(txt_reset)"
  echo "$msg"
  echo "$msg" >> "$global_log_path"
  echo "$msg" >> "$package_log_path"
}

function Dbg() {
  [[ "$verbose" == "true" ]] || return
  LogStdout "$(txt_yellow) => $1"
}

#Logs a info message passed as $1
function Info() {
  LogStdout "$(txt_green) => $1"
}

#Logs an error message
function Err() {
  LogStdout "$(txt_red) => $1"
}

#Logs an fatal error and kills the buildsever.
#If mail reporting is configured, an mail is send
#to the server admin.
#A fatal error is thrown, if an error occurs that is very likely
#caused by a bug in the script e.g. a file was copied beforehand to location x
#and is not there when the script is trying to access it.
function ErrFatal() {
  LogStdout "$(txt_red) => $1"
  HandleFatalError "$1"
}

####################

########## Shutdown and error handling ##########

#Deletes all temporary files
function CleanUp() {
  Info "Cleaning up"
  rm -rf "$rpc_cache_dir"
  rm -rf "$work_dir"
}

#Handles an fatal error from that we aren't able to recover.
#The reason for the error is passed in $1
function HandleFatalError() {
  if [[ ! -z "$admin_mail" ]]; then
    echo "Send email here"
  fi

  CleanUp
  exit 1
}
####################

function CowerGetVersion() {
  unset __result

  CowerInfoWarpper "$1" || return $ERROR
  local info="$__result"

  __result="$(echo "$__result" | grep "Version" | cut -d ':' -f 2- | xargs)"

  Dbg "CowerGetVersion($1) __result=$__result"

  return $SUCCESS
}

#Get the direct dependencies (non recursive) of the given package.
#$1 - the package name
#Returns an array of dependencies in $__result and $SUCCESS or $ERROR
function CowerGetDeps() {
  unset __result

  CowerInfoWarpper "$1" || return $ERROR
  local info="$__result"

  __result="$(echo "$__result" | grep "Depends On" | cut -d ':' -f 2- | xargs)"

  Dbg "CowerGetDeps($1) __result=$__result"

  return $SUCCESS
}

#$1 - package name to quarry
#Returns the output from cower and $SUCCESS or $ERROR
function CowerInfoWarpper() {
  local package_name="$1"
  local cache_entry="${cower_cache}/${package_name}"

  unset __result

  if [[ -f "$cache_entry" ]]; then
    __result="$(cat "$cache_entry")"
  else
    __result="$(cower -i "$package_name")" || return $ERROR
    echo "$__result" > "$cache_entry"
  fi

  return $SUCCESS
}


########## Mail stuff ##########

#Send a mail
#$1 - receiver mail address
#$2 - subject
#$3 - body
#$4... - paths to files that will be send as attachment
#Returns: $SUCCESS or $ERROR
SendMail() {
  local receiver=( $1 )
  local subject="$2"
  local body="$3"
  local attachments_arg=""

  if [[ "${#receiver[@]}" == "0" ]]; then
    Info "No receiver passed, skipping sending mail"
    return $SUCCESS
  fi

  shift 3

  for path in $@; do
    attachments_arg="${attachments_arg}-a $path "
  done
  echo "$body" > "$work_dir/email.body"

  for r in ${receiver[@]}; do
    Info "Sending mail to $r"
    mutt -s "$subject" $attachments_arg -- "$r" < "$work_dir/email.body" \
      || { Err "Failed to send email to $r"; return $ERROR; }
  done
  return $SUCCESS
}


####################

#Parses a package config file and returns its key
#value pairs as associative array.
#$1 - Path to the config file
#On error ERROR is returned, else SUCCESS.
#Returns: __result
function ParsePackageConfig() {
  Dbg "ParsePackageConfig($1)"
  local path="$1"

  unset __result #prevent "can not convert" error
  declare -g -A __result

  local OLD_IFS="$IFS"
  IFS=$'\n'
  for l in $(cat "$path"); do
    local key="$(echo "$l" | cut -d '=' -f 1 | tr -d ' ')"
    local val="$(echo "$l" | cut -d '=' -f 2- | xargs)"
    [[ ! -z "$key" && ! -z "$val" ]] \
      || { Err "ParsePackageConfig($1): Malformed config"; IFS="$OLD_IFS"; return $ERROR; }
    __result["$key"]="$val"
  done
  IFS="$OLD_IFS"
  return $SUCCESS
}

#Get the version of an package archive.
#$1 - The path to the archive
#On error a fatal error is raised.
#Returns: Version string in __result
function PkgGetVersion() {
  Dbg "PkgGetVersion($1)"
  __result="$(pacman -Qp "$1" | cut -d ' ' -f 2)"
  [[ $? == 0 ]] \
    || ErrFatal "PkgGetVersion($1) Error while getting version"
  Dbg "PkgGetVersion() -> $__result"
}

#Get the name of a package archive
#$1 - The path to the archive
#On error is fatal error is raised
#Returns: Package name in __result
function PkgGetName() {
  Dbg "PkgGetName($1)"
  __result="$(pacman -Qp "$1" | cut -d ' ' -f 1)"
  [[ $? == 0 ]] \
    || ErrFatal "PkgGetName($1) Error while getting package name"
  Dbg "PkgGetName() -> $__result"
}

########## Repo management ##########

#Returns the package version of a given package name.
#$1 - The name of the package
#Returns the version of package in __result
#If there is no such package __result is set to ""
#This function doesn't returns a status code.
RepoGetPackageVersion() {
  Dbg "RepoGetPackageVersion($1)"
  local package_name="$1"
  __result=""
  for p in $(ls $repo_dir/*.pkg* 2> /dev/null); do
    PkgGetName "$p"
    if [[ "$__result" == "$package_name" ]]; then
      PkgGetVersion "$p"
      #Just for clear semantic (retval is retval from PkgGetVersion)
      __result="$__result"
      Dbg "RepoGetPackageVersion($1) -> $__result"
      return
    fi
  done
  __result=""
  Dbg "RepoGetPackageVersion($1) -> ()"
}

#This function checks if all AUR dependencies and the package
#itself is up-to-date.
#$1 - name of the package to check
#Returns true or false in __result and $SUCCESS.
#On error $ERROR is returned
function RepoPackageAndDepsAreUpToDate() {
  local package_name="$1"

  __result="false"

  PackageGetAurDepsRec "$package_name" || return $ERROR
  local deps=( ${__result[@]} "$package_name" )

  declare -A name_ver_map

  for pkg in $(ls $repo_dir/*.pkg*); do
    PkgGetVersion "$pkg"
    local ver="$__result"

    PkgGetName "$pkg"
    local name="$__result"

    name_ver_map["$name"]="$ver"
  done

  for dep in ${deps[@]}; do
    CowerGetVersion "$dep"
    local remote_ver="$__result"
    Info "Checking if dependency $dep($remote_ver/${name_ver_map["$dep"]}) is outdated or not build"
    if [[ "${name_ver_map["$dep"]}" == "" || "${name_ver_map["$dep"]}" != "$remote_ver" ]]; then
      __result="false"
      return $SUCCESS
    fi
  done

  __result="true"
  return $SUCCESS
}

#Moves a package to the given repository.
#$1 - Path to the package to add. This file will be moved into
#the repository directory. Thus it isn't available at its old location
#after this function returns. The function expects that the given package
#(with same version) wasn't already added to the repo.
#On error a fatal error is raised.
#Returns nothing
RepoMovePackage() {
  Dbg "RepoMovePackage($1)"
  mv "$1" "$repo_dir" \
    || ErrFatal "Error while moving package into repository folder"
  repo-add --new --remove "$repo_db" "$repo_dir/$(basename "$1")" || \
    ErrFatal "Error while adding package $1 to repository"
}

#Remove the given package form the repository
#$1 - the name of the package
#On error a fatal error is raised.
#Returns nothing
RepoRemovePackage() {
  repo-remove "$repo_db" "$1" \
    || ErrFatal "Error while removing package $1 from repository"
  rm -f "$p" \
    || ErrFatal "Error while removing package $1 from repository"
}

####################

#Returns an array of all AUR dependencies (recursive) of the given package.
#The package for that this function was called is not included in the
#array (except there is a cyclic dependency)
#$1 - package name
#Returns an array of all AUR dependencies of package $1.
#On error $ERROR is returned, else $SUCCESS
function PackageGetAurDepsRec() {
  local package_name="$1"
  local work_queue=( "$package_name" )
  local processed_packages=()

  while [[ "${#work_queue[@]}" > 0 ]]; do
    #TODO: Check for dependency cycles
    local current_proccessed_package="${work_queue[0]}"
    Dbg "PackageGetAurDeps() work_queue = ${work_queue[*]}"

    CowerGetDeps "$current_proccessed_package" || return $ERROR
    local package_deps=( "$__result" )

    for dep in ${package_deps[@]}; do
      #Filter version string
      dep="$(echo "$dep" | egrep -o "^([a-z]|[A-Z]|-|\.|[0-9])*")"

      #Quarry pacman first, because local db access is faster
      pacman -Si "$dep" &> /dev/null
      if [[ $? -ne 0  ]]; then
        #Some packages are also not provided by pacman (virtual packages?)
        #TODO: Optimize
        cower -i "$dep" &> /dev/null
        if [[ $? -eq 0 ]]; then
          Dbg "$dep is a AUR dependency"
          work_queue+=("$dep")
        fi
      fi
    done

    processed_packages=( ${processed_packages[@]} "$current_proccessed_package" )
    unset work_queue[0]
    #Shift empty elements (remove)
    work_queue=( ${work_queue[@]} )
  done

  unset __result
  #Delete the package for that this function was called
  #a package is not a dependency of itself
  for p in ${processed_packages[@]}; do
    if [[ "$p" != "$package_name" ]]; then
      __result=( ${__result[@]} "$p" )
    fi
  done

  #Remove duplicates
  __result=( $(printf "%s\n" "${__result[@]}" | sort -u) )
  Dbg "PackageGetAurDeps() $package_name has following dependecies(${#__result[@]}) = ${__result[*]}"
  return $SUCCESS
}


function PackageGetAllAurDepsRec() {
  local deps=()

  for p in $(ls $pkg_configs_dir/*.config 2> /dev/null ); do
    ParsePackageConfig "$p" || return $ERROR
    local package_name="${__result[name]}"
    PackageGetAurDepsRec "$package_name" || return $ERROR
    deps=( ${deps[@]} ${__result[@]} "$package_name" )
  done

  deps=( $(printf "%s\n" "${deps[@]}" | sort -u) )

  Dbg "Configured packages have the following dependencies ${deps[*]}"

  unset __result
  __result=( ${deps[@]} )
}


function BuildOrUpdatePackage() {
  local package_name="$1"
  local package_work_dir="$work_dir/$package_name"
  Info "Building or updating $package_name"
  Info "Creating working directory $package_work_dir"
  mkdir -p "$package_work_dir"
  if [[ $? != 0 ]]; then
    Err "Error while creating $package_work_dir"
    return $ERROR
  fi

  #Create links from packages in repo into workdir
  ln -s $(ls $repo_dir/*.pkg* 2> /dev/null ) "$package_work_dir" 2> /dev/null

  #Place where pacaur will look for already build packages
  #and stores build results
  export PKGDEST="$package_work_dir"

  #Fixes EDITOR not set error on docker host
  export EDITOR=nano

  Info "Running pacaur"

  pacaur -m --needed --noconfirm --noedit "$package_name" 2>&1 | tee -a "$global_log_path" "$package_log_path"
  if [[ $? != 0 ]]; then
    Err "BuildOrUpdatePackage($1) Error while executing pacaur"
    Info "Deleting working directory $package_work_dir"
    rm -rf "$package_work_dir"
    return $ERROR
  fi

  #New build packages aren't symlinks
  local new_files=$(find "$package_work_dir" -mindepth 1 ! -type l)

  if [[ -z "$new_files" ]]; then
    #Nothing changed
    Err "This function should never be called if there is nothing to update"
    return $ERROR
  else
    #Packages where updated/build
    for f in $new_files; do
      Info "New package $(basename "$f") was build"

      PkgGetName "$f"
      local new_package_name="$__result"

      PkgGetVersion "$f"
      local new_package_version="$__result"

      RepoGetPackageVersion "$new_package_name"
      local old_version="$__result"

      if [[ -z "$old_version" ]]; then
        Info "Package $new_package_name was build the first time ($new_package_version)"
        if [[ "$new_package_name" != "$package_name" ]]; then
          SendMail "$admin_mail" "[AUR-BUILDSERVER][$package_name] Dependency ($new_package_name) successfully build" \
            "Package $new_package_name ($new_package_version) was build the first time" "$package_log_path"
        else
          SendMail "$admin_mail" "[AUR-BUILDSERVER][$package_name] Successfully build" \
            "Package $new_package_name ($new_package_version) was build the first time" "$package_log_path"
        fi
      else
        Info "Package $new_package_name was updated ($old_version -> $new_package_version)"
        if [[ "$new_package_name" != "$package_name" ]]; then
          SendMail "$admin_mail" "[AUR-BUILDSERVER][$package_name] Dependency ($new_package_name) successfully updated" \
            "Package $new_package_name ($old_version -> $new_package_version) was updated" "$package_log_path"
        else
          SendMail "$admin_mail" "[AUR-BUILDSERVER][$package_name] Successfully updated" \
            "Package $new_package_name ($old_version -> $new_package_version) was updated" "$package_log_path"
        fi
      fi
      RepoMovePackage "$f"
    done
  fi
  Info "Deleting working directory $package_work_dir"
  rm -rf "$package_work_dir"
  return $SUCCESS
}

#This function processes all package configs and executes
#for each of the configs the BuildOrUpdatePackage function.
function ProcessPackageConfigs() {
  Info "Processing all configurations in $pkg_configs_dir..."
  IndentInc

  if [[ "$(ls -l $pkg_configs_dir/*.config 2> /dev/null | wc -l)" < 1 ]]; then
    Info "Package configs dir $pkg_configs_dir is empty, please add some config files"
    return;
  fi

  for cfg in $(ls $pkg_configs_dir/*.config 2> /dev/null); do
    ParsePackageConfig "$cfg"
    if [[ $? != $SUCCESS ]]; then
      Err "ProcessPackageConfig() Malformed config $cfg, skipping..."
      SendMail "$admin_mail" "[AUR-BUILDSERVER][ERROR] Malformed config" \
            "Error while parsing config $cfg" "$package_log_path"
      IndentDec
      continue;
    fi

    #Start new log
    echo > "$package_log_path"

    #Copy package config array from __result to pkg_cfg
    #TODO: Make this less ugly
    eval $(typeset -A -p __result|sed 's/ __result=/ pkg_cfg=/')

    Info "Processing package $(txt_bold)${pkg_cfg[name]}$($txt_reset)"
    IndentInc

    if [[ ! -z "${pkg_cfg[disabled]}" && "${pkg_cfg[disabled]}" == "true" ]]; then
      Info "Config $cfg is disabled, skipping..."
      IndentDec
      continue;
    fi

    #Check if packages and deps are up-to-date
    RepoPackageAndDepsAreUpToDate "${pkg_cfg[name]}"
    if [[ "$__result" == "true" ]]; then
      Info "Package ${pkg_cfg[name]} and its dependencies are $(txt_bold)up-to-date$(txt_reset)"
      IndentDec
      continue;
    else
      Info "Package ${pkg_cfg[name]} is $(txt_bold)not installed or outdated$(txt_reset)"
    fi

    #Import needed PGP keys
    if [[ ! -z "${pkg_cfg[pgp_keys]}" ]]; then
      local import_failed=false
      for key in ${pkg_cfg[pgp_keys]} ; do
        Info "Importing PGP-Key $key..."
        gpg --keyserver "$gpg_keyserver" --recv-keys  "$key"
        if [[ $? != 0 ]]; then
          Err "Faild to import PGP key $key for package ${pkg_cfg[name]}, skipping package..."
          SendMail "$admin_mail" "[AUR-BUILDSERVER][${pkg_cfg[name]}] Faild import PGP key" \
            "See attachment" "$package_log_path"
          import_failed=true
          break;
        fi
      done
      [[ "$import_failed" == "false" ]] || { IndentDec; continue; }
    fi

    BuildOrUpdatePackage "${pkg_cfg[name]}"
    if [[ $? != $SUCCESS ]]; then
      Err "Faild to update/build package ${pkg_cfg[name]}"
      SendMail "$admin_mail" "[AUR-BUILDSERVER][${pkg_cfg[name]}] Faild to update/build package" \
        "See attachment" "$package_log_path"
      IndentDec
      continue;
    fi

  IndentDec
  done

  IndentRst
}

function RemovePackgesWoConfig() {
    Info "Starting removing of packages without config..."
    IndentInc

    Info "Resolving dependencies, this could take a while"
    PackageGetAllAurDepsRec
    [[ $? -eq $SUCCESS ]] \
      || ErrFatal "Error while resolving dependencies" 

    local packages_aur_deps=( ${__result[@]} )

    for p in $(ls $repo_dir/*.pkg* 2> /dev/null); do
      PkgGetName "$p"
      local package_name="$__result"

      local has_config=false
      Info "Checking package $(txt_bold)${package_name}$(txt_reset)"
      IndentInc

      for dep in ${packages_aur_deps[@]}; do
        if [[ "$dep" == "$package_name" ]]; then
          has_config=true
          break;
        fi
      done

      if [[ "$has_config" == "true" ]]; then
        Info "Package $package_name has config, skipping..."
      else
        Info "Package $package_name has no config, deleting..."
        RepoRemovePackage "$package_name"
      fi
      IndentDec
    done

    IndentRst
}


#Parse args
while [[ $# > 0 ]]; do
  case $1 in
    "--pkg-configs")
      [[ $# > 1 ]] || ArgumentParsingError "Missing path for --pkg-configs"
      shift
      pkg_configs_dir="$1"
      [[ ! -f "$1" ]] || ArgumentParsingError "$1 is no directory"
      [[ -d "$1" ]] || ArgumentParsingError "Configuration directory $pkg_configs_dir doesn't exists"
      ;;
    "--repo-dir")
      [[ $# > 1 ]] || ArgumentParsingError "Missing path for --repo-dir"
      shift
      repo_dir="$1"
      [[ ! -f "$1" ]] || ArgumentParsingError "$1 is no directory"
      [[ -d "$1" ]] || ArgumentParsingError "Configuration directory $repo_dir doesn't exists"
      ;;
    "--work-dir")
      [[ $# > 1 ]] || ArgumentParsingError "Missing path for --work-dir"
      shift
      work_dir="$1"
      [[ ! -f "$1" && ! -d "$1" ]] || ArgumentParsingError "work directory should not already exists"
      ;;
    "--action")
      [[ $# > 1 ]] || ArgumentParsingError "Missing argument for --action"
      shift
      action="$1"
      ;;
    "--repo-name")
      [[ $# > 1 ]] || ArgumentParsingError "Missing argument for --repo-name"
      shift
      repo_name="$1"
      ;;
    "--admin-mail")
      [[ $# > 1 ]] || ArgumentParsingError "Missing argument for --admin-mail"
      shift
      admin_mail="$1"
      ;;
    "--debug")
      verbose=true
      ;;
    "--help")
      PrintUsage
      ;;
    *)
      ArgumentParsingError "Unknown option $1" 
      ;;
  esac
  shift
done

[[ ! -z "$pkg_configs_dir" ]] \
  || ArgumentParsingError "Missing required argument --pkg-configs"

[[ ! -z "$repo_dir" ]] \
  || ArgumentParsingError "Missing required argument --repo-dir"

[[ ! -z "$action" ]] \
  || ArgumentParsingError "Missing required argument --action"

#Return variable
__result=""

#constants
#Server from which missing gpg keys will be downloaded
readonly gpg_keyserver="hkp://pgp.mit.edu"
readonly ERROR=1
readonly SUCCESS=0

#Vars that depend on parsed args
repo_name="${repo_name:-aur-prebuilds}"
repo_db="$repo_dir/${repo_name}.db.tar.xz"
work_dir="${work_dir:-"$HOME/.cache/aur-repo-buildserver/work_dir"}"
cower_cache="${work_dir}/cower_cache"
log_file="/tmp/test.txt"
action="$action"
verbose="${verbose:-false}"

#Mail report stuff
admin_mail="${admin_mail:-}"
global_log_path="$work_dir/global.log"
package_log_path="$work_dir/package.log"

#Other global vars
indent=0



########## Setup ##########

#Check for empty required arguments
if [[ -z "$repo_dir" || -z "$pkg_configs_dir" || -z "$action" ]]; then
  PrintUsage "Missing at least one required argument"
fi

mkdir -p "$work_dir" \
  || ErrFatal "Failed to create working directory $work_dir"

mkdir -p "$cower_cache" \
  || ErrFatal "Error while creating cower cache directory"

#Setup global logging
echo -n > "$global_log_path" \
  || ErrFatal "Error while creating $global_log_path"

if [[ "$AUR_REPO_BUILDSERVER_TEST" == "true" ]]; then
  Dbg "Build server is in testing mode. Argument --action will be ignored"
  Dbg "If you sourced this script, you can now start testing by calling arbitrary functions."
  return 0
fi

#Check action

action=( "$(echo "$action" | tr ',' ' ')" )

for cmd in ${action[@]}; do
  case $cmd in
    "build")
      #Process all configs and update/build the packages
      ProcessPackageConfigs
      ;;
    "clean")
      RemovePackgesWoConfig
      ;;
    *)
      PrintUsage "Invalid argument ($action) for --action"
      ;;
  esac
done



#Check if any package changed and send mail
#Check if there are unhandled error that must be forwarded to the server admin

CleanUp
exit 0
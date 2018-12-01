# Arch user repository build server

```
This software can be used for running a server that periodically builds packages
from the AUR. The resulting artifacts are automatically added to a repository
which in turn can be used by pacman. This allows you to source out
the complete building process and by that reducing maintenance time for updating
the local system.

Packages that should be built by the server are configured by
config files. The directory that contains these files is passed by the
--pkg-configs flag. Config files must end with a .config suffix, and the
content must look like this:

name = i3blocks
disabled = false

Another argument that is always needed is --repo-dir. This flag is used to
configure the directory where the repository should be created. The third required argument
is --action, this argument determines what the build server should do.

Command line format
  ./buildserver.sh [--pkg-configs packages config dir] [--repo-dir path] [--action action] [OPTION]...

Required argument
  --action  action0,action1... 
  The actions that should be performed by the build server (comma separated).
  Please mind that chaining several actions improves performance due to caching.
  For example, the dependency resolve results from the clean action can be reused
  by the build action.
  Possible values are the following:
    build 
      This action will build/update all targets defined by a config file in the
      --pkg-configs directory.
    clean 
      This action will delete all packages from the repository that have no
      associated config files in the --pkg-configs directory.

  --repo-dir  path 
    The path must point to a directory where the repo database should be created.
    If in the given directory a database already exists, it will be updated.

  --pkg-configs  path 
    The path to a directory that contains multiple package configuration files.


OPTIONS
  --work-dir  path 
    The directory where packages are built.
    Default value is $HOME/.cache/aur-repo-buildserver

  --repo-name  name 
    The name of the repository to create/update.
    This name must be later used as the "repository tag"
    in you're pacman conf e.g.
      [aur-repo] <<< TAG
      SigLevel = ...
      Server = https://...

  --debug 
    Enable output of debugging messages.

  --admin-mail  mail address 
    The mail address of the admin. To this email address a mail
    is send, every time an error accours.

  --mail-reporting  mail address 
    This flag enables sending of mails on several events.
    Mails will be send on successfully building or updating a package.
    Also mails will be send, if a error occurs while running this script.
    The mutt application is used to send email, thus it must be configured
    for this feature to work.

  --db-sign-key  KEY-ID 
    Set the GPG key ID that will be used to sign the repository database file.

  --package-sign-key  KEY-ID 
    Set the GPG key ID that will be used to sign the build packages.
    For package signing to work, you need to add the "sign" flag to
    the BUILDENV array inside you're local makepkg.conf.
```

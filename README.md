# Arch user repository build server

This software can be used for running a server that periodically build packages
from the AUR. The resulting artifacts are automatically added into a repository
that can be added to a local pacman.conf. This allow to source out the complete
build process and reducing maintenance time for updating the local system.

For further information see `buildserver.sh --help`

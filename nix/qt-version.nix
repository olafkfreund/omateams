# QtWebEngine must be 6.140.0 final or newer. compareVersions ranks
# "6.140.0-rc" above "6.140.0", so compare the part before "-".
lib: v:
let base = lib.head (lib.splitString "-" v); in
lib.versionOlder "6.140.0" base || v == "6.140.0"

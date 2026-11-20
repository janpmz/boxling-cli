# Boxling CLI

Boxling runs isolated Linux workspaces on Apple silicon Macs. The `boxling`
command talks to a background service that owns the workspaces. macOS asks
for access approval when you open a shell, run a command, or transfer files.

## Build and test

Use macOS 26 or later, Swift and `make`. The tests also use Python 3.

```sh
make -j 2 build
make test
./boxling --version
```

## Install the runtime and set up the service

Boxling needs version 1.6.1-mybox.6 of the [container runtime fork](https://github.com/janpmz/my-container-box)
or a later revision in that series. The runtime has its own installation
directory and can coexist with Apple's `container`.

If you are building the runtime before the fork publishes that version, build
from the checked-in revision below and apply the included patch. The patch
makes the runtime check firewall approval before booting a box under either
service account name.

```sh
git clone https://github.com/janpmz/my-container-box.git ../my-container-box
git -C ../my-container-box checkout --detach 0d452c46c6248ca5ae1da55ef92e848bab9b6c3b
git -C ../my-container-box apply "$PWD/runtime/boxling-account.patch"
make -C ../my-container-box BUILD_CONFIGURATION=release build installer-pkg
```

On a fresh installation, open the resulting
`../my-container-box/bin/release/my-container-box-installer.pkg` in macOS
Installer. Then run `./boxling setup-service` from this checkout. Setup uses
administrator authorization to configure the private `_boxling` account and
its services. For a Mac with an existing MyBox desktop installation, use the
combined Boxling upgrade installer. The upgrade reuses the numeric account and
group IDs and the existing directory that holds the boxes.

## Run Boxling

```sh
./boxling help
./boxling create demo
./boxling list --json
./boxling enter demo
./boxling stop demo
```

Run `./boxling completion zsh` to print the zsh completion script. For an
installation on your shell's `PATH`, link the `boxling` launcher from this
checkout into a directory on `PATH`.

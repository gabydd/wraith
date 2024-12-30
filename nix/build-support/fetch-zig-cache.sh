#!/bin/sh

set -e

# Because Zig does not fetch recursive dependencies when you run `zig build
# --fetch` (see https://github.com/ziglang/zig/issues/20976) we need to do some
# extra work to fetch everything that we actually need to build without Internet
# access (such as when building a Nix package).
#
# An example of this happening:
#
# error: builder for '/nix/store/cx8qcwrhjmjxik2547fw99v5j6np5san-ghostty-0.1.0.drv' failed with exit code 1;
#        la/build/tmp.xgHOheUF7V/p/12208cfdda4d5fdbc81b0c44b82e4d6dba2d4a86bff644a153e026fdfc80f8469133/build.zig.zon:7:20: error: unable to discover remote git server capabilities: TemporaryNameServerFailure
#        >             .url = "git+https://github.com/zigimg/zigimg#3a667bdb3d7f0955a5a51c8468eac83210c1439e",
#        >                    ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#        > /build/tmp.xgHOheUF7V/p/12208cfdda4d5fdbc81b0c44b82e4d6dba2d4a86bff644a153e026fdfc80f8469133/build.zig.zon:16:20: error: unable to discover remote git server capabilities: TemporaryNameServerFailure
#        >             .url = "git+https://github.com/mitchellh/libxev#f6a672a78436d8efee1aa847a43a900ad773618b",
#        >                    ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#        >
#        For full logs, run 'nix log /nix/store/cx8qcwrhjmjxik2547fw99v5j6np5san-ghostty-0.1.0.drv'.
#
# To update this script, add any failing URLs with a line like this:
#
#    zig fetch <url>
#
# Periodically old URLs may need to be cleaned out.
#
# Hopefully when the Zig issue is fixed this script can be eliminated in favor
# of a plain `zig build --fetch`.

if [ -z ${ZIG_GLOBAL_CACHE_DIR+x} ]
then
  echo "must set ZIG_GLOBAL_CACHE_DIR!"
  exit 1
fi

zig build --fetch
zig fetch git+https://github.com/zigimg/zigimg#3a667bdb3d7f0955a5a51c8468eac83210c1439e
zig fetch git+https://github.com/mitchellh/libxev#f6a672a78436d8efee1aa847a43a900ad773618b

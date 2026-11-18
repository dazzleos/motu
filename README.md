# Motu

A game for [Dazzle](https://github.com/dazzleos/dazzle): build on a
tropical atoll of blocks. Shape the islands, build huts, paddle a canoe
across the lagoon, and look out to sea with a telescope. Islands are kept
between games, and friends on the same network can play on yours.

Install it on Dazzle from Settings, Software.

## Building

Motu is built with Dazzle's modules (kete_vc4 and the rest) and tools,
through Dazzle's `addApp` (see its `build.zig`): a commit of Dazzle's, as
`build.zig.zon` pins it. Zig is the version Dazzle's `scripts/zig` fetches:

    git clone https://github.com/dazzleos/dazzle ../dazzle
    ../dazzle/scripts/zig build test    # the tests, on this computer
    ../dazzle/scripts/zig build         # the program, and zig-out/apps

With changes of your own to Dazzle, build with that checkout instead:
`--fork=../dazzle`. To move Motu on to a newer Dazzle, pin its commit:

    git -C ../dazzle archive --format=tar.gz -o /tmp/dazzle.tar.gz <commit>
    zig fetch /tmp/dazzle.tar.gz        # prints the hash for build.zig.zon

(the archive has only the commit's files, so this is quick, and its hash
is the one fetching the commit from GitHub gives).

`zig-out/apps` has Motu's archive, icon, screenshot and catalogue
(`apps.json`), signed with `-Dsigning-key` or `DAZZLE_SIGNING_KEY`. Each
push to the default branch publishes them as the "latest" release, one of
the sources Dazzle's catalogue lists.

To try a build on a Pi before publishing it, serve it with Dazzle's
(Settings, Software, Software server):

    cd ../dazzle && zig build serve -- --source=motu=../motu/zig-out

## On Linux

Motu also builds for Linux (Wayland, drawn with Vulkan), from the same
code: Dazzle's is what it is made for, and the Linux build adds nothing
to it (the GPU is chosen when it is built: see `src/gpu.zig`).

    ../dazzle/scripts/zig build -Dplatform=linux --prefix zig-out/linux
    ./zig-out/linux/bin/motu

Islands are kept in `$XDG_DATA_HOME/motu` (in a snap, `$SNAP_USER_COMMON`).
With kete changes of your own, add `--fork=` and its checkout.

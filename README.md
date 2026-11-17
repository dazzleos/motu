# Motu

A game for [Dazzle](https://github.com/dazzleos/dazzle): build on a
tropical atoll of blocks. Shape the islands, build huts, paddle a canoe
across the lagoon, and look out to sea with a telescope. Islands are kept
between games, and friends on the same network can play on yours.

Install it on Dazzle from Settings, Software.

## Building

Motu is built with Dazzle's modules (kete_vc4 and the rest) and tools,
through Dazzle's `addApp` (see its `build.zig`). Dazzle's repository is
beside this one:

    git clone https://github.com/dazzleos/dazzle ../dazzle
    ../dazzle/scripts/zig build test    # the tests, on this computer
    ../dazzle/scripts/zig build         # the program, and zig-out/apps

`zig-out/apps` has Motu's archive, icon, screenshot and catalogue
(`apps.json`), signed with `-Dsigning-key` or `DAZZLE_SIGNING_KEY`. Each
push to the default branch publishes them as the "latest" release, one of
the sources Dazzle's catalogue lists.

To try a build on a Pi before publishing it, serve it with Dazzle's
(Settings, Software, Software server):

    cd ../dazzle && zig build serve -- --source=motu=../motu/zig-out

<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) -->

# sholes-cli

The `sholes` binary has no command-line/runtime dependencies beyond
`sholes-core`.

```text
sholes clean  < file > canonical-file
sholes smudge --target windows < canonical-file > working-tree-file
sholes audit .
sholes init --global
sholes filter-process --target windows
```

Configure Git's long-running process filter with:

```sh
git config filter.sholes.process 'sholes filter-process'
git config filter.sholes.required true
git config filter.sholes.clean 'sholes clean'
git config filter.sholes.smudge 'sholes smudge'
```

The process entry point speaks Git filter protocol v2: it performs the
`git-filter-client` / `git-filter-server` capability handshake and frames every
blob with pkt-lines. `SHOLES_TARGET=windows` or `--target windows` selects CRLF
smudging; the default is the host environment.

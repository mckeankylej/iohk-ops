#!/usr/bin/env bash

io="/nix/store/604hqdwlw82pn19s5aszmxjkrjfadgqn-ghc-8.0.2-with-packages/bin/runhaskell -i/home/staging/iohk/iohk ~/iohk/iohk/iohk-ops.hs"

journaltgz=`$io --no-component-check -c csl-1583.yaml get-journals | grep 'Packing journals into' | sed 's/Packing journals into //g'`

journal=${journaltgz:0:-4}

mkdir -p logs/$journal

cd logs/$journal

tar -xzf ../../$journaltgz

bash

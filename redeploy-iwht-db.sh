#! /usr/bin/env nix-shell
#!nix-shell -i bash

dump=$1
delay=$2
cluster=$3

if [[ ! -f $dump.tgz ]]; then
   echo "No $dump.tgz"
   exit 1
fi

if [[ $delay == "" ]]; then
   echo "Provide delay"
   exit 1
fi

if [[ $cluster == "" ]]; then
   echo "Provide cluster"
   exit 1
fi

io="/nix/store/604hqdwlw82pn19s5aszmxjkrjfadgqn-ghc-8.0.2-with-packages/bin/runhaskell -i/home/staging/iohk/iohk ~/iohk/iohk/iohk-ops.hs"

$io --no-component-check -c $cluster.yaml stop wipe-journals wipe-node-dbs --confirm
$io --no-component-check -c $cluster.yaml ssh "mkdir -p /var/lib/cardano-node"
for i in a b c d; do nixops scp -d $cluster "$i"1 --to $dump.tgz /var/lib/cardano-node/$dump.tgz; done
$io --no-component-check -c $cluster.yaml ssh "cd /var/lib/cardano-node; ls; rm -Rf node-db; tar -xzf $dump.tgz; mv $dump node-db; chmod 777 -R node-db"
$io --no-component-check -c $cluster.yaml deploy --bump-system-start-held-by $delay

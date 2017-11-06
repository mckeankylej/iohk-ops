{-# OPTIONS_GHC -Wall -Wextra -Wno-orphans -Wno-missing-signatures -Wno-unticked-promoted-constructors -Wno-type-defaults #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ViewPatterns #-}

module NixOps (
    nixops
  , create
  , modify
  , deploy
  , destroy
  , delete

  , build
  , buildAMI
  , stop
  , start
  , fromscratch
  , dumpLogs
  , getJournals
  , wipeJournals
  , wipeNodeDBs
  , startForeground

  , runSetRev
  , reallocateCoreIPs
  , deployedCommit
  , checkstatus
  , parallelSSH
  , NixOps.date

  , awsPublicIPURL
  , defaultEnvironment
  , defaultNixpkgs
  , defaultNode
  , defaultNodePort
  , defaultTarget
  , nixpkgsNixosURL

  , cmd, cmd', incmd
  , errorT
  , every
  , jsonLowerStrip
  , lowerShowT
  , parallelIO

  -- * Types
  , Arg(..)
  , Branch(..)
  , Commit(..)
  , ConfigurationKey(..)
  , Confirmation(..)
  , Deployment(..)
  , EnvVar(..)
  , Environment(..)
  , envDefaultConfig
  , envSettings
  , Exec(..)
  , NixopsCmd(..)
  , NixopsConfig(..)
  , clusterConfigurationKey
  , NixopsDepl(..)
  , NixSource(..)
  , githubSource, gitSource, readSource
  , NodeName(..)
  , fromNodeName
  , Options(..)
  , Org(..)
  , PortNo(..)
  , Project(..)
  , projectURL
  , Region(..)
  , Target(..)
  , URL(..)
  , Username(..)
  , Zone(..)
  
  -- * Flags
  , BuildOnly(..)
  , DoCommit(..)
  , DryRun(..)
  , PassCheck(..)
  , RebuildExplorer(..)
  , enabled
  , disabled
  , opposite
  , flag
  , toBool

  -- 
  , parserBranch
  , parserCommit
  , parserNodeLimit
  , parserOptions

  , mkNewConfig
  , readConfig
  , writeConfig

  -- * Legacy
  , DeploymentInfo(..)
  , getNodePublicIP
  , getIP
  , defLogs, profLogs
  , info
  , scpFromNode
  , toNodesInfo
  )
where

import           Control.Arrow                   ((***))
import           Control.Exception                (throwIO)
import           Control.Lens                     ((<&>))
import           Control.Monad                    (forM_, mapM_)
import qualified Data.Aeson                    as AE
import           Data.Aeson                       ((.:), (.:?), (.=), (.!=))
import           Data.Aeson.Encode.Pretty         (encodePretty)
import qualified Data.ByteString.UTF8          as BU
import qualified Data.ByteString.Lazy.UTF8     as LBU
import           Data.Char                        (ord)
import           Data.Csv                         (decodeWith, FromRecord(..), FromField(..), HasHeader(..), defaultDecodeOptions, decDelimiter)
import           Data.Either
import           Data.Hourglass                   (timeAdd, timeFromElapsed, timePrint, Duration(..), ISO8601_DateAndTime(..))
import           Data.List                        (nub, sort)
import           Data.Maybe
import qualified Data.Map.Strict               as Map
import           Data.Monoid                      ((<>))
import           Data.Optional                    (Optional)
import qualified Data.Set                      as Set
import qualified Data.Text                     as T
import qualified Data.Text.IO                  as TIO
import           Data.Text.Lazy                   (fromStrict)
import           Data.Text.Lazy.Encoding          (encodeUtf8)
import qualified Data.Vector                   as V
import qualified Data.Yaml                     as YAML
import           Data.Yaml                        (FromJSON(..), ToJSON(..))
import           Debug.Trace                      (trace)
import qualified Filesystem.Path.CurrentOS     as Path
import           GHC.Generics              hiding (from, to)
import           GHC.Stack
import           Prelude                   hiding (FilePath)
import           Safe                             (headMay)
import qualified System.IO                     as Sys
import qualified System.IO.Unsafe              as Sys
import           Time.System
import           Time.Types
import           Turtle                    hiding (env, err, fold, inproc, prefix, procs, e, f, o, x)
import qualified Turtle                        as Turtle

import           Constants
import           Nix
import           Topology
import           Types
import           Utils


-- * Some orphan instances..
--
deriving instance Generic Seconds; instance FromJSON Seconds; instance ToJSON Seconds
deriving instance Generic Elapsed; instance FromJSON Elapsed; instance ToJSON Elapsed


-- * Environment-specificity
--
data EnvSettings =
  EnvSettings
  { envDeployerUser      :: Username
  , envDefaultConfigurationKey :: ConfigurationKey
  , envDefaultConfig     :: FilePath
  , envDefaultTopology   :: FilePath
  , envDeploymentFiles   :: [FileSpec]
  }

type FileSpec = (Deployment, Target, Text)

envSettings :: HasCallStack => Environment -> EnvSettings
envSettings env =
  let deplAgnosticFiles      = [ (Every,          All, "deployments/keypairs.nix")
                               , (Explorer,       All, "deployments/cardano-explorer.nix")
                               , (ReportServer,   All, "deployments/report-server.nix")
                               , (Nodes,          All, "deployments/cardano-nodes.nix")
                               , (Infra,          All, "deployments/infrastructure.nix")
                               , (Infra,          AWS, "deployments/infrastructure-target-aws.nix") ]
  in case env of
    Staging      -> EnvSettings
      { envDeployerUser      = "staging"
      , envDefaultConfigurationKey = "testnet_staging_full"
      , envDefaultConfig     = "staging-testnet.yaml"
      , envDefaultTopology   = "topology-staging.yaml"
      , envDeploymentFiles   = [ (Every,          All, "deployments/security-groups.nix")
                               , (Nodes,          All, "deployments/cardano-nodes-env-staging.nix")
                               , (Explorer,       All, "deployments/cardano-explorer-env-staging.nix")
                               , (ReportServer,   All, "deployments/report-server-env-staging.nix")
                               ] <> deplAgnosticFiles}
    Production  -> EnvSettings
      { envDeployerUser      = "live-production"
      , envDefaultConfigurationKey = "testnet_public_full"
      , envDefaultConfig     = "production-testnet.yaml"
      , envDefaultTopology   = "topology-production.yaml"
      , envDeploymentFiles   = [ (Nodes,          All, "deployments/security-groups.nix")
                               , (Explorer,       All, "deployments/security-groups.nix")
                               , (ReportServer,   All, "deployments/security-groups.nix")
                               , (Nodes,          All, "deployments/cardano-nodes-env-production.nix")
                               , (Explorer,       All, "deployments/cardano-explorer-env-production.nix")
                               , (ReportServer,   All, "deployments/report-server-env-production.nix")
                               , (Infra,          All, "deployments/infrastructure-env-production.nix")
                               ] <> deplAgnosticFiles}
    Development -> EnvSettings
      { envDeployerUser      = "staging"
      , envDefaultConfigurationKey = "devnet_shortep_full"
      , envDefaultConfig     = "config.yaml"
      , envDefaultTopology   = "topology-development.yaml"
      , envDeploymentFiles   = [ (Nodes,          All, "deployments/cardano-nodes-env-development.nix")
                               , (Explorer,       All, "deployments/cardano-explorer-env-development.nix")
                               , (ReportServer,   All, "deployments/report-server-env-development.nix")
                               ] <> deplAgnosticFiles}
    Any -> error "envSettings called with 'Any'"

selectDeployer :: Environment -> [Deployment] -> NodeName
selectDeployer Staging   delts | elem Nodes delts = "iohk"
                               | otherwise        = "cardano-deployer"
selectDeployer _ _                                = "cardano-deployer"

establishDeployerIP :: Options -> Maybe IP -> IO IP
establishDeployerIP o Nothing   = IP <$> incmd o "curl" ["--silent", fromURL awsPublicIPURL]
establishDeployerIP _ (Just ip) = pure ip


-- * Deployment file set computation
--
filespecDeplSpecific :: Deployment -> FileSpec -> Bool
filespecDeplSpecific x (x', _, _) = x == x'
filespecTgtSpecific  :: Target     -> FileSpec -> Bool
filespecTgtSpecific  x (_, x', _) = x == x'

filespecNeededDepl   :: Deployment -> FileSpec -> Bool
filespecNeededTgt    :: Target     -> FileSpec -> Bool
filespecNeededDepl x fs = filespecDeplSpecific Every fs || filespecDeplSpecific x fs
filespecNeededTgt  x fs = filespecTgtSpecific  All   fs || filespecTgtSpecific  x fs

filespecFile :: FileSpec -> Text
filespecFile (_, _, x) = x

elementDeploymentFiles :: Environment -> Target -> Deployment -> [Text]
elementDeploymentFiles env tgt depl = filespecFile <$> (filter (\x -> filespecNeededDepl depl x && filespecNeededTgt tgt x) $ envDeploymentFiles $ envSettings env)


-- * Topology
--
-- Design:
--  1. we have the full Topology, and its SimpleTopo subset, which is converted to JSON for Nix's consumption.
--  2. the SimpleTopo is only really needed when we have Nodes to deploy
--  3. 'getSimpleTopo' is what executes the decision in #2
--
readTopology :: FilePath -> IO Topology
readTopology file = do
  eTopo <- liftIO $ YAML.decodeFileEither $ Path.encodeString file
  case eTopo of
    Right (topology :: Topology) -> pure topology
    Left err -> errorT $ format ("Failed to parse topology file: "%fp%": "%w) file err

newtype SimpleTopo
  =  SimpleTopo { fromSimpleTopo :: (Map.Map NodeName SimpleNode) }
  deriving (Generic, Show)
instance ToJSON SimpleTopo

data SimpleNode
  =  SimpleNode
     { snType     :: NodeType
     , snRegion   :: NodeRegion
     , snZone     :: NodeZone
     , snOrg      :: NodeOrg
     , snFQDN     :: FQDN
     , snPort     :: PortNo
     , snInPeers  :: [NodeName]                  -- ^ Incoming connection edges
     , snKademlia :: RunKademlia
     , snPublic   :: Bool
     } deriving (Generic, Show)
instance ToJSON SimpleNode where
  toJSON SimpleNode{..} = AE.object
   [ "type"        .= (lowerShowT snType & T.stripPrefix "node"
                        & fromMaybe (error "A NodeType constructor gone mad: doesn't start with 'Node'."))
   , "region"      .= snRegion
   , "zone"        .= snZone
   , "org"         .= snOrg
   , "address"     .= fromFQDN snFQDN
   , "port"        .= fromPortNo snPort
   , "peers"       .= snInPeers
   , "kademlia"    .= snKademlia
   , "public"      .= snPublic ]

instance ToJSON NodeRegion
instance ToJSON NodeName
deriving instance Generic NodeName
deriving instance Generic NodeRegion
deriving instance Generic NodeType
instance ToJSON NodeType

topoNodes :: SimpleTopo -> [NodeName]
topoNodes (SimpleTopo cmap) = Map.keys cmap

topoCores :: SimpleTopo -> [NodeName]
topoCores = (fst <$>) . filter ((== NodeCore) . snType . snd) . Map.toList . fromSimpleTopo

stubTopology :: SimpleTopo
stubTopology = SimpleTopo Map.empty

summariseTopology :: Topology -> SimpleTopo
summariseTopology (TopologyStatic (AllStaticallyKnownPeers nodeMap)) =
  SimpleTopo $ Map.mapWithKey simplifier nodeMap
  where simplifier node (NodeMetadata snType snRegion (NodeRoutes outRoutes) nmAddr snKademlia snPublic mbOrg snZone) =
          SimpleNode{..}
          where (mPort,  fqdn)   = case nmAddr of
                                     (NodeAddrExact fqdn'  mPort') -> (mPort', fqdn') -- (Ok, bizarrely, this contains FQDNs, even if, well.. : -)
                                     (NodeAddrDNS   mFqdn  mPort') -> (mPort', flip fromMaybe mFqdn
                                                                      $ error "Cannot deploy a topology with nodes lacking a FQDN address.")
                (snPort, snFQDN) = (,) (fromMaybe defaultNodePort $ PortNo . fromIntegral <$> mPort)
                                   $ (FQDN . T.pack . BU.toString) $ fqdn
                snInPeers = Set.toList . Set.fromList
                            $ [ other
                              | (other, (NodeMetadata _ _ (NodeRoutes routes) _ _ _ _ _)) <- Map.toList nodeMap
                              , elem node (concat routes) ]
                            <> concat outRoutes
                snOrg = fromMaybe (trace (T.unpack $ format ("WARNING: node '"%s%"' has no 'org' field specified, defaulting to "%w%".")
                                          (fromNodeName node) defaultOrg)
                                   defaultOrg)
                        mbOrg
summariseTopology x = errorT $ format ("Unsupported topology type: "%w) x

getSimpleTopo :: [Deployment] -> FilePath -> IO SimpleTopo
getSimpleTopo cElements cTopology =
  if not $ elem Nodes cElements then pure stubTopology
  else do
    topoExists <- testpath cTopology
    unless topoExists $
      die $ format ("Topology config '"%fp%"' doesn't exist.") cTopology
    summariseTopology <$> readTopology cTopology

-- | Dump intermediate core/relay info, as parametrised by the simplified topology file.
dumpTopologyNix :: NixopsConfig -> IO ()
dumpTopologyNix NixopsConfig{..} = sh $ do
  let nodeSpecExpr prefix =
        format ("with (import <nixpkgs> {}); "%s%" (import ./globals.nix { deployerIP = \"\"; environment = \""%s%"\"; topologyYaml = ./"%fp%"; systemStart = 0; "%s%" = \"-stub-\"; })")
               prefix (lowerShowT cEnvironment) cTopology (T.intercalate " = \"-stub-\"; " $ fromAccessKeyId <$> accessKeyChain)
      getNodeArgsAttr prefix attr = inproc "nix-instantiate" ["--strict", "--show-trace", "--eval" ,"-E", nodeSpecExpr prefix <> "." <> attr] empty
      liftNixList = inproc "sed" ["s/\" \"/\", \"/g"]
  (cores  :: [NodeName]) <- getNodeArgsAttr "map (x: x.name)" "cores"  & liftNixList <&> ((NodeName <$>) . readT . lineToText)
  (relays :: [NodeName]) <- getNodeArgsAttr "map (x: x.name)" "relays" & liftNixList <&> ((NodeName <$>) . readT . lineToText)
  echo "Cores:"
  forM_ cores  $ \(NodeName x) -> do
    printf ("  "%s%"\n    ") x
    Turtle.proc "nix-instantiate" ["--strict", "--show-trace", "--eval" ,"-E", nodeSpecExpr "" <> ".nodeMap." <> x] empty
  echo "Relays:"
  forM_ relays $ \(NodeName x) -> do
    printf ("  "%s%"\n    ") x
    Turtle.proc "nix-instantiate" ["--strict", "--show-trace", "--eval" ,"-E", nodeSpecExpr "" <> ".nodeMap." <> x] empty

nodeNames :: Options -> NixopsConfig -> [NodeName]
nodeNames (oOnlyOn -> nodeLimit)  NixopsConfig{..}
  | Nothing   <- nodeLimit = topoNodes topology <> [explorerNode | elem Explorer cElements]
  | Just node <- nodeLimit
  , SimpleTopo nodeMap <- topology
  = if Map.member node nodeMap || node == explorerNode then [node]
    else errorT $ format ("Node '"%s%"' doesn't exist in cluster '"%fp%"'.") (showT $ fromNodeName node) cTopology




data Options = Options
  { oChdir            :: Maybe FilePath
  , oConfigFile       :: Maybe FilePath
  , oOnlyOn           :: Maybe NodeName
  , oDeployerIP       :: Maybe IP
  , oConfirm          :: Confirmed
  , oDebug            :: Debug
  , oSerial           :: Serialize
  , oVerbose          :: Verbose
  , oNoComponentCheck :: ComponentCheck
  , oNixpkgs          :: Maybe FilePath
  } deriving Show

parserBranch :: Optional HelpMessage -> Parser Branch
parserBranch desc = Branch <$> argText "branch" desc

parserCommit :: Optional HelpMessage -> Parser Commit
parserCommit desc = Commit <$> argText "commit" desc

parserNodeLimit :: Parser (Maybe NodeName)
parserNodeLimit = optional $ NodeName <$> (optText "just-node" 'n' "Limit operation to the specified node")

flag :: Flag a => a -> ArgName -> Char -> Optional HelpMessage -> Parser a
flag effect long ch help = (\case
                               True  -> effect
                               False -> opposite effect) <$> switch long ch help

parserOptions :: Parser Options
parserOptions = Options
                <$> optional (optPath "chdir"     'C' "Run as if 'iohk-ops' was started in <path> instead of the current working directory.")
                <*> optional (optPath "config"    'c' "Configuration file")
                <*> (optional $ NodeName
                     <$>     (optText "on"        'o' "Limit operation to the specified node"))
                <*> (optional $ IP
                     <$>     (optText "deployer"  'd' "Directly specify IP address of the deployer: do not detect"))
                <*> flag Confirmed        "confirm"            'y' "Pass --confirm to nixops"
                <*> flag Debug            "debug"              'd' "Pass --debug to nixops"
                <*> flag Serialize        "serial"             's' "Disable parallelisation"
                <*> flag Verbose          "verbose"            'v' "Print all commands that are being run"
                <*> flag NoComponentCheck "no-component-check" 'p' "Disable deployment/*.nix component check"
                <*> (optional $ optPath "nixpkgs" 'i' "Set 'nixpkgs' revision")

nixopsCmdOptions :: Options -> NixopsConfig -> [Text]
nixopsCmdOptions Options{..} NixopsConfig{..} =
  ["--debug"   | oDebug   == Debug]   <>
  ["--confirm" | oConfirm == Confirmed] <>
  ["--show-trace"
  ,"--deployment", fromNixopsDepl cName
  ] <> fromMaybe [] ((["-I"] <>) . (:[]) . ("nixpkgs=" <>) . format fp <$> oNixpkgs)


-- | Before adding a field here, consider, whether the value in question
--   ought to be passed to Nix.
--   If so, the way to do it is to add a deployment argument (see DeplArgs),
--   which are smuggled across Nix border via --arg/--argstr.
data NixopsConfig = NixopsConfig
  { cName             :: NixopsDepl
  , cGenCmdline       :: Text
  , cNixpkgs          :: Maybe Commit
  , cTopology         :: FilePath
  , cEnvironment      :: Environment
  , cTarget           :: Target
  , cElements         :: [Deployment]
  , cFiles            :: [Text]
  , cDeplArgs         :: DeplArgs
  -- this isn't stored in the config file, but is, instead filled in during initialisation
  , topology          :: SimpleTopo
  } deriving (Generic, Show)
instance FromJSON NixopsConfig where
    parseJSON = AE.withObject "NixopsConfig" $ \v -> NixopsConfig
        <$> v .: "name"
        <*> v .:? "gen-cmdline"   .!= "--unknown--"
        <*> v .:? "nixpkgs"
        <*> v .:? "topology"      .!= "topology-development.yaml"
        <*> v .: "environment"
        <*> v .: "target"
        <*> v .: "elements"
        <*> v .: "files"
        <*> v .: "args"
        <*> pure undefined -- this is filled in in readConfig
instance ToJSON Environment
instance ToJSON Target
instance ToJSON Deployment
instance ToJSON NixopsConfig where
  toJSON NixopsConfig{..} = AE.object
   [ "name"         .= fromNixopsDepl cName
   , "gen-cmdline"  .= cGenCmdline
   , "topology"     .= cTopology
   , "environment"  .= showT cEnvironment
   , "target"       .= showT cTarget
   , "elements"     .= cElements
   , "files"        .= cFiles
   , "args"         .= cDeplArgs ]

deploymentFiles :: Environment -> Target -> [Deployment] -> [Text]
deploymentFiles cEnvironment cTarget cElements =
  nub $ concat (elementDeploymentFiles cEnvironment cTarget <$> cElements)

type DeplArgs = Map.Map NixParam NixValue

selectInitialConfigDeploymentArgs :: Options -> FilePath -> Environment -> [Deployment] -> Elapsed -> Maybe ConfigurationKey -> IO DeplArgs
selectInitialConfigDeploymentArgs _ _ env delts (Elapsed systemStart) mConfigurationKey = do
    let EnvSettings{..}   = envSettings env
        akidDependentArgs = [ ( NixParam $ fromAccessKeyId akid
                              , NixStr . fromNodeName $ selectDeployer env delts)
                            | akid <- accessKeyChain ]
        configurationKey  = fromMaybe envDefaultConfigurationKey mConfigurationKey
    pure $ Map.fromList $
      akidDependentArgs
      <> [ ("systemStart",  NixInt $ fromIntegral systemStart)
         , ("configurationKey", NixStr $ fromConfigurationKey configurationKey) ]

deplArg :: NixopsConfig -> NixParam -> NixValue -> NixValue
deplArg    NixopsConfig{..} k def = Map.lookup k cDeplArgs & fromMaybe def
  --(errorT $ format ("Deployment arguments don't hold a value for key '"%s%"'.") (showT k))

setDeplArg :: NixParam -> NixValue -> NixopsConfig -> NixopsConfig
setDeplArg p v c@NixopsConfig{..} = c { cDeplArgs = Map.insert p v cDeplArgs }

-- | Interpret inputs into a NixopsConfig
mkNewConfig :: Options -> Text -> NixopsDepl -> Maybe FilePath -> Environment -> Target -> [Deployment] -> Elapsed -> Maybe ConfigurationKey -> IO NixopsConfig
mkNewConfig o cGenCmdline cName                       mTopology cEnvironment cTarget cElements systemStart mConfigurationKey = do
  let EnvSettings{..} = envSettings                             cEnvironment
      cFiles          = deploymentFiles                         cEnvironment cTarget cElements
      cTopology       = flip fromMaybe                mTopology envDefaultTopology
      cNixpkgs        = defaultNixpkgs
  cDeplArgs    <- selectInitialConfigDeploymentArgs o cTopology cEnvironment         cElements systemStart mConfigurationKey
  topology <- getSimpleTopo cElements cTopology
  pure NixopsConfig{..}

-- | Write the config file
writeConfig :: MonadIO m => Maybe FilePath -> NixopsConfig -> m FilePath
writeConfig mFp c@NixopsConfig{..} = do
  let configFilename = flip fromMaybe mFp $ envDefaultConfig $ envSettings cEnvironment
  liftIO $ writeTextFile configFilename $ T.pack $ BU.toString $ YAML.encode c
  pure configFilename

-- | Read back config, doing validation
readConfig :: MonadIO m => Options -> FilePath -> m NixopsConfig
readConfig Options{..} cf = do
  cfParse <- liftIO $ YAML.decodeFileEither $ Path.encodeString $ cf
  let c@NixopsConfig{..}
        = case cfParse of
            Right cfg -> cfg
            -- TODO: catch and suggest versioning
            Left  e -> errorT $ format ("Failed to parse config file "%fp%": "%s)
                       cf (T.pack $ YAML.prettyPrintParseException e)
      storedFileSet  = Set.fromList cFiles
      deducedFiles   = deploymentFiles cEnvironment cTarget cElements
      deducedFileSet = Set.fromList $ deducedFiles

  unless (storedFileSet == deducedFileSet || oNoComponentCheck == NoComponentCheck) $
    die $ format ("Config file '"%fp%"' is incoherent with respect to elements "%w%":\n  - stored files:  "%w%"\n  - implied files: "%w%"\n")
          cf cElements (sort cFiles) (sort deducedFiles)
  -- Can't read topology file without knowing its name, hence this phasing.
  topo <- liftIO $ getSimpleTopo cElements cTopology
  pure c { topology = topo }

clusterConfigurationKey :: NixopsConfig -> ConfigurationKey
clusterConfigurationKey c =
  ConfigurationKey . fromNixStr $ deplArg c (NixParam "configurationKey") $ errorT $
                                  format "'configurationKey' network argument missing from cluster config"


parallelIO' :: Options -> NixopsConfig -> ([NodeName] -> [a]) -> (a -> IO ()) -> IO ()
parallelIO' o@Options{..} c@NixopsConfig{..} xform action =
  ((case oSerial of
      Serialize     -> sequence_
      DontSerialize -> sh . parallel) $
   action <$> (xform $ nodeNames o c))
  >> echo ""

parallelIO :: Options -> NixopsConfig -> (NodeName -> IO ()) -> IO ()
parallelIO o c = parallelIO' o c id

logCmd  bin args = do
  printf ("-- "%s%"\n") $ T.intercalate " " $ bin:args
  Sys.hFlush Sys.stdout

inproc :: Text -> [Text] -> Shell Line -> Shell Line
inproc bin args inp = do
  liftIO $ logCmd bin args
  Turtle.inproc bin args inp

minprocs :: MonadIO m => Text -> [Text] -> Shell Line -> m (Either ProcFailed Text)
minprocs bin args inp = do
  (exitCode, out) <- liftIO $ procStrict bin args inp
  pure $ case exitCode of
           ExitSuccess -> Right out
           _           -> Left $ ProcFailed bin args exitCode

inprocs :: MonadIO m => Text -> [Text] -> Shell Line -> m Text
inprocs bin args inp = do
  ret <- minprocs bin args inp
  case ret of
    Right out -> pure out
    Left  err -> liftIO $ throwIO err

cmd   :: Options -> Text -> [Text] -> IO ()
cmd'  :: Options -> Text -> [Text] -> IO (ExitCode, Text)
incmd :: Options -> Text -> [Text] -> IO Text

cmd   Options{..} bin args = do
  when (toBool oVerbose) $ logCmd bin args
  Turtle.procs      bin args empty
cmd'  Options{..} bin args = do
  when (toBool oVerbose) $ logCmd bin args
  Turtle.procStrict bin args empty
incmd Options{..} bin args = do
  when (toBool oVerbose) $ logCmd bin args
  inprocs bin args empty


-- * Invoking nixops
--
iohkNixopsPath :: FilePath -> FilePath
iohkNixopsPath defaultNix =
  let storePath  = Sys.unsafePerformIO $ inprocs "nix-build" ["-A", "nixops", format fp defaultNix] $
                   (trace (T.unpack $ format ("INFO: using "%fp%" expression for its definition of 'nixops'") defaultNix) empty)
      nixopsPath = Path.fromText $ T.strip storePath <> "/bin/nixops"
  in trace (T.unpack $ format ("INFO: nixops is "%fp) nixopsPath) nixopsPath

nixops'' :: (Options -> Text -> [Text] -> IO b) -> Options -> NixopsConfig -> NixopsCmd -> [Arg] -> IO b
nixops'' executor o@Options{..} c@NixopsConfig{..} com args =
  executor o (format fp $ iohkNixopsPath "default.nix")
  (fromCmd com : nixopsCmdOptions o c <> fmap fromArg args)

nixops' :: Options -> NixopsConfig -> NixopsCmd -> [Arg] -> IO (ExitCode, Text)
nixops  :: Options -> NixopsConfig -> NixopsCmd -> [Arg] -> IO ()
nixops' = nixops'' cmd'
nixops  = nixops'' cmd

nixopsMaybeLimitNodes :: Options -> [Arg]
nixopsMaybeLimitNodes (oOnlyOn -> maybeNode) = ((("--include":) . (:[]) . Arg . fromNodeName) <$> maybeNode & fromMaybe [])


-- * Deployment lifecycle
--
exists :: Options -> NixopsConfig -> IO Bool
exists o c@NixopsConfig{..} = do
  (code, _) <- nixops' o c "info" []
  pure $ code == ExitSuccess

create :: Options -> NixopsConfig -> IO ()
create o c@NixopsConfig{..} = do
  deplExists <- exists o c
  if deplExists
  then do
    printf ("Deployment already exists?: '"%s%"'") $ fromNixopsDepl cName
  else do
    printf ("Creating deployment "%s%"\n") $ fromNixopsDepl cName
    nixops o c "create" $ Arg <$> deploymentFiles cEnvironment cTarget cElements

buildGlobalsImportNixExpr :: [(NixParam, NixValue)] -> NixValue
buildGlobalsImportNixExpr deplArgs =
  NixImport (NixFile "globals.nix")
  $ NixAttrSet $ Map.fromList $ (fromNixParam *** id) <$> deplArgs

computeFinalDeploymentArgs :: Options -> NixopsConfig -> IO [(NixParam, NixValue)]
computeFinalDeploymentArgs o@Options{..} NixopsConfig{..} = do
  IP deployerIP <- establishDeployerIP o oDeployerIP
  let deplArgs' = Map.toList cDeplArgs
                  <> [("deployerIP",   NixStr  deployerIP)
                     ,("topologyYaml", NixFile cTopology)
                     ,("environment",  NixStr  $ lowerShowT cEnvironment)]
  pure $ ("globals", buildGlobalsImportNixExpr deplArgs'): deplArgs'

modify :: Options -> NixopsConfig -> IO ()
modify o@Options{..} c@NixopsConfig{..} = do
  printf ("Syncing Nix->state for deployment "%s%"\n") $ fromNixopsDepl cName
  nixops o c "modify" $ Arg <$> cFiles

  printf ("Setting deployment arguments:\n")
  deplArgs <- computeFinalDeploymentArgs o c
  forM_ deplArgs $ \(name, val)
    -> printf ("  "%s%": "%s%"\n") (fromNixParam name) (nixValueStr val)
  nixops o c "set-args" $ Arg <$> (concat $ uncurry nixArgCmdline <$> deplArgs)

  simpleTopo <- getSimpleTopo cElements cTopology
  liftIO . writeTextFile simpleTopoFile . T.pack . LBU.toString $ encodePretty (fromSimpleTopo simpleTopo)
  when (toBool oDebug) $ dumpTopologyNix c

setenv :: Options -> EnvVar -> Text -> IO ()
setenv o@Options{..} (EnvVar k) v = do
  export k v
  when (oVerbose == Verbose) $
    cmd o "/bin/sh" ["-c", format ("echo 'export "%s%"='$"%s) k k]

deploy :: Options -> NixopsConfig -> DryRun -> BuildOnly -> PassCheck -> RebuildExplorer -> Maybe Seconds -> IO ()
deploy o@Options{..} c@NixopsConfig{..} dryrun buonly check reExplorer bumpSystemStartHeldBy = do
  when (elem Nodes cElements) $ do
     keyExists <- testfile "keys/key1.sk"
     unless keyExists $
       die "Deploying nodes, but 'keys/key1.sk' is absent."

  _ <- pure $ clusterConfigurationKey c
  when (dryrun /= DryRun && elem Explorer cElements && reExplorer /= NoExplorerRebuild) $ do
    cmd o "scripts/generate-explorer-frontend.sh" []
  when (dryrun /= DryRun && buonly /= BuildOnly) $ do
    deployerIP <- establishDeployerIP o oDeployerIP
    setenv o "SMART_GEN_IP" $ getIP deployerIP
  when (elem Nodes cElements) $
    setenv o "GC_INITIAL_HEAP_SIZE" (showT $ 6 * 1024*1024*1024) -- for 100 nodes it eats 12GB of ram *and* needs a bigger heap

  now <- timeCurrent
  let startParam             = NixParam "systemStart"
      secNixVal (Elapsed x)  = NixInt $ fromIntegral x
      holdSecs               = fromMaybe defaultHold bumpSystemStartHeldBy
      nowHeld                = now `timeAdd` mempty { durationSeconds = holdSecs }
      startE                 = case bumpSystemStartHeldBy of
        Just _  -> nowHeld
        Nothing -> Elapsed $ fromIntegral $ (\(NixInt x)-> x) $ deplArg c startParam (secNixVal nowHeld)
      c' = setDeplArg startParam (secNixVal startE) c
  when (isJust bumpSystemStartHeldBy) $ do
    let timePretty = (T.pack $ timePrint ISO8601_DateAndTime (timeFromElapsed startE :: DateTime))
    printf ("Setting --system-start to "%s%" ("%d%" minutes into future)\n")
           timePretty (div holdSecs 60)
    cFp <- writeConfig oConfigFile c'
    cmd o "git" (["add", format fp cFp])
    cmd o "git" ["commit", "-m", format ("Bump systemStart to "%s) timePretty]

  modify o c'

  printf ("Deploying cluster "%s%"\n") $ fromNixopsDepl cName
  nixops o c' "deploy"
    $  [ "--max-concurrent-copy", "50", "-j", "4" ]
    ++ [ "--dry-run"       | dryrun == DryRun ]
    ++ [ "--build-only"    | buonly == BuildOnly ]
    ++ [ "--check"         | check  == PassCheck  ]
    ++ nixopsMaybeLimitNodes o
  echo "Done."

destroy :: Options -> NixopsConfig -> IO ()
destroy o c@NixopsConfig{..} = do
  printf ("Destroying cluster "%s%"\n") $ fromNixopsDepl cName
  nixops (o { oConfirm = Confirmed }) c "destroy"
    $ nixopsMaybeLimitNodes o
  echo "Done."

delete :: Options -> NixopsConfig -> IO ()
delete o c@NixopsConfig{..} = do
  printf ("Un-defining cluster "%s%"\n") $ fromNixopsDepl cName
  nixops (o { oConfirm = Confirmed }) c "delete"
    $ nixopsMaybeLimitNodes o
  echo "Done."

nodeDestroyElasticIP :: Options -> NixopsConfig -> NodeName -> IO ()
nodeDestroyElasticIP o c name =
  let nodeElasticIPResource :: NodeName -> Text
      nodeElasticIPResource = (<> "-ip") . fromNodeName
  in nixops (o { oConfirm = Confirmed }) c "destroy" ["--include", Arg $ nodeElasticIPResource name]


-- * Higher-level (deploy-based) scenarios
--
defaultDeploy :: Options -> NixopsConfig -> IO ()
defaultDeploy o c =
  deploy o c NoDryRun NoBuildOnly DontPassCheck RebuildExplorer (Just defaultHold)

fromscratch :: Options -> NixopsConfig -> IO ()
fromscratch o c = do
  destroy o c
  delete o c
  create o c
  defaultDeploy o c

-- | Destroy elastic IPs corresponding to the nodes listed and reprovision cluster.
reallocateElasticIPs :: Options -> NixopsConfig -> [NodeName] -> IO ()
reallocateElasticIPs o c@NixopsConfig{..} nodes = do
  mapM_ (nodeDestroyElasticIP o c) nodes
  defaultDeploy o c

reallocateCoreIPs :: Options -> NixopsConfig -> IO ()
reallocateCoreIPs o c = reallocateElasticIPs o c (topoCores $ topology c)


-- * Building
--

buildAMI :: Options -> NixopsConfig -> IO ()
buildAMI o _ = do
  cmd o "nix-build" ["jobsets/cardano.nix", "-A", "cardano-node-image", "-o", "image"]
  cmd o "./scripts/create-amis.sh" []

dumpLogs :: Options -> NixopsConfig -> Bool -> IO Text
dumpLogs o c withProf = do
    TIO.putStrLn $ "WithProf: " <> T.pack (show withProf)
    when withProf $ do
        stop o c
        sleep 2
        echo "Dumping logs..."
    (_, dt) <- fmap T.strip <$> cmd' o "date" ["+%F_%H%M%S"]
    let workDir = "experiments/" <> dt
    TIO.putStrLn workDir
    cmd o "mkdir" ["-p", workDir]
    parallelIO o c $ dump workDir
    return dt
  where
    dump workDir node =
        forM_ logs $ \(rpath, fname) -> do
          scpFromNode o c node rpath (workDir <> "/" <> fname (fromNodeName node))
    logs = mconcat
             [ if withProf
                  then profLogs
                  else []
             , defLogs
             ]
prefetchURL :: Options -> Project -> Commit -> IO (NixHash, FilePath)
prefetchURL o proj rev = do
  let url = projectURL proj
  hashPath <- incmd o "nix-prefetch-url" ["--unpack", "--print-path", (fromURL $ url) <> "/archive/" <> fromCommit rev <> ".tar.gz"]
  let hashPath' = T.lines hashPath
  pure (NixHash (hashPath' !! 0), Path.fromText $ hashPath' !! 1)

runSetRev :: Options -> Project -> Commit -> Maybe Text -> IO ()
runSetRev o proj rev mCommitChanges = do
  printf ("Setting '"%s%"' commit to "%s%"\n") (lowerShowT proj) (fromCommit rev)
  let url = projectURL proj
  (hash, _) <- prefetchURL o proj rev
  printf ("Hash is"%s%"\n") (showT hash)
  let revspecFile = format fp $ projectSrcFile proj
      revSpec = GitSource{ gRev             = rev
                         , gUrl             = url
                         , gSha256          = hash
                         , gFetchSubmodules = True }
  writeFile (T.unpack $ revspecFile) $ LBU.toString $ encodePretty revSpec
  case mCommitChanges of
    Nothing  -> pure ()
    Just msg -> do
      cmd o "git" (["add", revspecFile])
      cmd o "git" ["commit", "-m", msg]

deploymentBuildTarget :: Deployment -> NixAttr
deploymentBuildTarget Nodes = "cardano-sl-static"
deploymentBuildTarget x     = error $ "'deploymentBuildTarget' has no idea what to build for " <> show x

build :: Options -> NixopsConfig -> Deployment -> IO ()
build o _c depl = do
  echo "Building derivation..."
  cmd o "nix-build" ["--max-jobs", "4", "--cores", "2", "-A", fromAttr $ deploymentBuildTarget depl]


-- * State management
--
-- Check if nodes are online and reboots them if they timeout
checkstatus :: Options -> NixopsConfig -> IO ()
checkstatus o c = do
  parallelIO o c $ rebootIfDown o c

rebootIfDown :: Options -> NixopsConfig -> NodeName -> IO ()
rebootIfDown o c (Arg . fromNodeName -> node) = do
  (x, _) <- nixops' o c "ssh" $ (node : ["-o", "ConnectTimeout=5", "echo", "-n"])
  case x of
    ExitSuccess -> return ()
    ExitFailure _ -> do
      TIO.putStrLn $ "Rebooting " <> fromArg node
      nixops o c "reboot" ["--include", node]

ssh  :: Options -> NixopsConfig -> Exec -> [Arg] -> NodeName -> IO ()
ssh o c e a n = ssh' o c e a n (TIO.putStr . ((fromNodeName n <> "> ") <>))

ssh' :: Options -> NixopsConfig -> Exec -> [Arg] -> NodeName -> (Text -> IO ()) -> IO ()
ssh' o c exec args (fromNodeName -> node) postFn = do
  let cmdline = Arg node: "--": Arg (fromExec exec): args
  (exitcode, out) <- nixops' o c "ssh" cmdline
  postFn out
  case exitcode of
    ExitSuccess -> return ()
    ExitFailure code -> TIO.putStrLn $ "ssh cmd '" <> (T.intercalate " " $ fromArg <$> cmdline) <> "' to '" <> node <> "' failed with " <> showT code

parallelSSH :: Options -> NixopsConfig -> Exec -> [Arg] -> IO ()
parallelSSH o c@NixopsConfig{..} ex as = do
  parallelIO o c $
    ssh o c ex as

scpFromNode :: Options -> NixopsConfig -> NodeName -> Text -> Text -> IO ()
scpFromNode o c (fromNodeName -> node) from to = do
  (exitcode, _) <- nixops' o c "scp" $ Arg <$> ["--from", node, from, to]
  case exitcode of
    ExitSuccess -> return ()
    ExitFailure code -> TIO.putStrLn $ "scp from " <> node <> " failed with " <> showT code

deployedCommit :: Options -> NixopsConfig -> NodeName -> IO ()
deployedCommit o c m = do
  ssh' o c "pgrep" ["-fa", "cardano-node"] m $
    \r-> do
      case cut space r of
        (_:path:_) -> do
          drv <- incmd o "nix-store" ["--query", "--deriver", T.strip path]
          pathExists <- testpath $ fromText $ T.strip drv
          unless pathExists $
            errorT $ "The derivation used to build the package is not present on the system: " <> T.strip drv
          sh $ do
            str <- inproc "nix-store" ["--query", "--references", T.strip drv] empty &
                   inproc "egrep"       ["/nix/store/[a-z0-9]*-cardano-sl-[0-9a-f]{7}\\.drv"] &
                   inproc "sed" ["-E", "s|/nix/store/[a-z0-9]*-cardano-sl-([0-9a-f]{7})\\.drv|\\1|"]
            when (str == "") $
              errorT $ "Cannot determine commit id for derivation: " <> T.strip drv
            echo $ "The 'cardano-sl' process running on '" <> unsafeTextToLine (fromNodeName m) <> "' has commit id " <> str
        [""] -> errorT $ "Looks like 'cardano-node' is down on node '" <> fromNodeName m <> "'"
        _    -> errorT $ "Unexpected output from 'pgrep -fa cardano-node': '" <> r <> "' / " <> showT (cut space r)


startForeground :: Options -> NixopsConfig -> NodeName -> IO ()
startForeground o c node =
  ssh' o c "bash" [ "-c", "'systemctl show cardano-node --property=ExecStart | sed -e \"s/.*path=\\([^ ]*\\) .*/\\1/\" | xargs grep \"^exec \" | cut -d\" \" -f2-'"]
  node $ \unitStartCmd ->
    printf ("Starting Cardano in foreground;  Command line:\n  "%s%"\n") unitStartCmd >>
    ssh o c "bash" ["-c", Arg $ "'sudo -u cardano-node " <> unitStartCmd <> "'"] node

stop :: Options -> NixopsConfig -> IO ()
stop o c = echo "Stopping nodes..."
  >> parallelSSH o c "systemctl" ["stop", "cardano-node"]

defLogs, profLogs :: [(Text, Text -> Text)]
defLogs =
    [ ("/var/lib/cardano-node/node.log", (<> ".log"))
    , ("/var/lib/cardano-node/jsonLog.json", (<> ".json"))
    , ("/var/lib/cardano-node/time-slave.log", (<> "-ts.log"))
    , ("/var/log/saALL", (<> ".sar"))
    ]
profLogs =
    [ ("/var/lib/cardano-node/cardano-node.prof", (<> ".prof"))
    , ("/var/lib/cardano-node/cardano-node.hp", (<> ".hp"))
    -- in fact, if there's a heap profile then there's no eventlog and vice versa
    -- but scp will just say "not found" and it's all good
    , ("/var/lib/cardano-node/cardano-node.eventlog", (<> ".eventlog"))
    ]

start :: Options -> NixopsConfig -> IO ()
start o c =
  parallelSSH o c "bash" ["-c", Arg $ "'" <> rmCmd <> "; " <> startCmd <> "'"]
  where
    rmCmd = foldl (\str (f, _) -> str <> " " <> f) "rm -f" logs
    startCmd = "systemctl start cardano-node"
    logs = mconcat [ defLogs, profLogs ]

date :: Options -> NixopsConfig -> IO ()
date o c = parallelIO o c $
  \n -> ssh' o c "date" [] n
  (\out -> TIO.putStrLn $ fromNodeName n <> ": " <> out)

wipeJournals :: Options -> NixopsConfig -> IO ()
wipeJournals o c@NixopsConfig{..} = do
  echo "Wiping journals on cluster.."
  parallelSSH o c "bash"
    ["-c", "'systemctl --quiet stop systemd-journald && rm -f /var/log/journal/*/* && systemctl start systemd-journald && sleep 1 && systemctl restart nix-daemon'"]
  echo "Done."

getJournals :: Options -> NixopsConfig -> IO ()
getJournals o c@NixopsConfig{..} = do
  let nodes = nodeNames o c

  echo "Dumping journald logs on cluster.."
  parallelSSH o c "bash"
    ["-c", "'rm -f log && journalctl -u cardano-node > log'"]

  echo "Obtaining dumped journals.."
  let outfiles  = format ("log-cardano-node-"%s%".journal") . fromNodeName <$> nodes
  parallelIO' o c (flip zip outfiles) $
    \(node, outfile) -> scpFromNode o c node "log" outfile
  timeStr <- T.replace ":" "_" . T.pack . timePrint ISO8601_DateAndTime <$> dateCurrent

  let archive   = format ("journals-"%s%"-"%s%"-"%s%".tgz") (lowerShowT cEnvironment) (fromNixopsDepl cName) timeStr
  printf ("Packing journals into "%s%"\n") archive
  cmd o "tar" (["czf", archive] <> outfiles)
  cmd o "rm" $ "-f" : outfiles
  echo "Done."

wipeNodeDBs :: Options -> NixopsConfig -> Confirmation -> IO ()
wipeNodeDBs o c@NixopsConfig{..} confirmation = do
  confirmOrTerminate confirmation
  echo "Wiping node databases.."
  parallelSSH o c "rm" ["-rf", "/var/lib/cardano-node"]
  echo "Done."



-- * Functions for extracting information out of nixops info command
--
-- | Get all nodes in EC2 cluster
data DeploymentStatus = UpToDate | Obsolete | Outdated
  deriving (Show, Eq)

instance FromField DeploymentStatus where
  parseField "up-to-date" = pure UpToDate
  parseField "obsolete" = pure Obsolete
  parseField "outdated" = pure Outdated
  parseField _ = mzero

data DeploymentInfo = DeploymentInfo
    { diName :: !NodeName
    , diStatus :: !DeploymentStatus
    , diType :: !Text
    , diResourceID :: !Text
    , diPublicIP :: !IP
    , diPrivateIP :: !IP
    } deriving (Show, Generic)

instance FromRecord DeploymentInfo
deriving instance FromField NodeName

nixopsDecodeOptions = defaultDecodeOptions {
    decDelimiter = fromIntegral (ord '\t')
  }

info :: Options -> NixopsConfig -> IO (Either String (V.Vector DeploymentInfo))
info o c = do
  (exitcode, nodes) <- nixops' o c "info" ["--no-eval", "--plain"]
  case exitcode of
    ExitFailure code -> return $ Left ("Parsing info failed with exit code " <> show code)
    ExitSuccess -> return $ decodeWith nixopsDecodeOptions NoHeader (encodeUtf8 $ fromStrict nodes)

toNodesInfo :: V.Vector DeploymentInfo -> [DeploymentInfo]
toNodesInfo vector =
  V.toList $ V.filter filterEC2 vector
    where
      filterEC2 di = T.take 4 (diType di) == "ec2 " && diStatus di /= Obsolete

getNodePublicIP :: Text -> V.Vector DeploymentInfo -> Maybe Text
getNodePublicIP name vector =
    headMay $ V.toList $ fmap (getIP . diPublicIP) $ V.filter (\di -> fromNodeName (diName di) == name) vector

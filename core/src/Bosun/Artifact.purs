-- | DESIGN §3.x / docs/ARTIFACTS.md — `Artifact`, the WHAT axis.
-- |
-- | A deployment is a triple **(artifact, executor, target)**: the *executor* is
-- | HOW a service runs (`Bosun.Executor`), the *target* is WHERE
-- | (`Bosun.Target`), and the **artifact is WHAT** — the built bytes,
-- | substrate-independent. Today the content is baked into each executor (a
-- | `Process` carries its `-root DIR`, a `Container` its `image:`/`build:`), so
-- | the same logical service can carry *different content* on different
-- | substrates — the disease behind the stale public polyglot site: the MBP
-- | served `site/polyglot/public` while the mini built the website image from a
-- | different (stale) dir. Two facets, two contents, same service.
-- |
-- | The cure is to make the content a SINGLE declaration and DERIVE each
-- | executor's run-spec from it (`runCommandFor` / `containerSourceFor`), so
-- | "same service, different content per substrate" becomes unrepresentable —
-- | the project's MISU ethos applied to content. This module provides:
-- |
-- |   * `Artifact` — the type (kind + a pinnable ref);
-- |   * `artifactOf` — classify the artifact an existing executor *implies*
-- |     (the bridge from today's per-facet content to the single declaration);
-- |   * `runCommandFor` / `containerSourceFor` — DERIVE a substrate's run-spec
-- |     from one artifact (the MISU machinery, the inverse direction);
-- |   * `artifactConsensus` — given the artifacts a service's facets imply, do
-- |     they agree on *content*? Disagreement is the architectural drift the
-- |     reconcile layer now surfaces (`Bosun.Reconcile.ArtifactDrift`).
module Bosun.Artifact
  ( Artifact(..)
  , ArtifactRef(..)
  , ArtifactKind(..)
  , mkRef
  , artifactRef
  , artifactKind
  , artifactKindLabel
  , sourceDir
  , artifactLabel
  , artifactOf
  , runCommandFor
  , containerSourceFor
  , ArtifactConsensus(..)
  , artifactConsensus
  ) where

import Prelude

import Bosun.Atoms (Port, unPort)
import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..), ImageRef(..))
import Data.Array as A
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Show.Generic (genericShow)
import Data.String (Pattern(..))
import Data.String as String

-- | WHAT runs — the built bytes. The same artifact, run via any executor on any
-- | target, must yield the same content (that is the guarantee). Each kind names
-- | a different *form* of content; the run-FORM may legitimately differ per
-- | substrate (a static dir is served by `static-httpd` natively and by nginx in
-- | docker), but the CONTENT (the `ArtifactRef`) must not.
-- |
-- | `SourceBuild` is distinct from `Image` on purpose: an `Image` is a *prebuilt,
-- | shippable* image (the build-once-ship target); a `SourceBuild` is a local
-- | source directory that gets **built per host** — the anti-pattern that lets
-- | two hosts produce different bytes from "the same" service.
data Artifact
  = StaticDir ArtifactRef       -- a built static directory (httpd -root DIR / nginx web root)
  | Binary ArtifactRef          -- a compiled executable
  | BundleRuntime ArtifactRef    -- a bundle needing a runtime (node entry.mjs)
  | SourceBuild ArtifactRef      -- a source dir built per host (compose `build:` context)
  | Image ArtifactRef           -- a prebuilt container image (the build-once-ship target)

derive instance Eq Artifact
derive instance Generic Artifact _
instance Show Artifact where
  show = genericShow

-- | A reference to the artifact's content: a `source` (a dir path, an image
-- | name, an entrypoint) and an optional `pin` (a digest / git revision / image
-- | tag). A pin makes "what content" FIXED rather than re-derived per host — the
-- | property that turns build-once-ship from hope into a guarantee. Unpinned =
-- | floating (the current reality across the fleet; flagged, not forbidden).
newtype ArtifactRef = ArtifactRef { source :: String, pin :: Maybe String }

derive instance Eq ArtifactRef
derive newtype instance Show ArtifactRef

mkRef :: String -> ArtifactRef
mkRef s = ArtifactRef { source: s, pin: Nothing }

artifactRef :: Artifact -> ArtifactRef
artifactRef = case _ of
  StaticDir r -> r
  Binary r -> r
  BundleRuntime r -> r
  SourceBuild r -> r
  Image r -> r

-- | The artifact KIND, dropping the ref — the run-FORM tag.
data ArtifactKind = KStaticDir | KBinary | KBundleRuntime | KSourceBuild | KImage

derive instance Eq ArtifactKind
derive instance Ord ArtifactKind
derive instance Generic ArtifactKind _
instance Show ArtifactKind where
  show = genericShow

artifactKind :: Artifact -> ArtifactKind
artifactKind = case _ of
  StaticDir _ -> KStaticDir
  Binary _ -> KBinary
  BundleRuntime _ -> KBundleRuntime
  SourceBuild _ -> KSourceBuild
  Image _ -> KImage

artifactKindLabel :: ArtifactKind -> String
artifactKindLabel = case _ of
  KStaticDir -> "static-dir"
  KBinary -> "binary"
  KBundleRuntime -> "bundle+runtime"
  KSourceBuild -> "source-build"
  KImage -> "image"

-- | The local SOURCE DIRECTORY a facet builds or serves from, if it has one: a
-- | `StaticDir` (a process serving `-root DIR`) or a `SourceBuild` (a container
-- | building from a `build:` context). A prebuilt `Image` (already shipped) and
-- | an opaque `Binary` launcher have NO source dir — so they cannot manifest the
-- | "two facets, two different source dirs" drift and are excluded from the
-- | consensus. This is the conservatism that keeps the §7 `npx serve` +
-- | prebuilt-image divergence from reading as a false positive: only a clearly
-- | comparable pair of source dirs can be flagged.
sourceDir :: Artifact -> Maybe String
sourceDir = case _ of
  StaticDir (ArtifactRef r) -> Just r.source
  SourceBuild (ArtifactRef r) -> Just r.source
  _ -> Nothing

-- | A short display label (entry-73 `display`, never `show`).
artifactLabel :: Artifact -> String
artifactLabel a =
  let (ArtifactRef r) = artifactRef a
  in artifactKindLabel (artifactKind a) <> " " <> r.source
       <> fromMaybe "" (map (\p -> "@" <> p) r.pin)

-- | The artifact an existing executor *implies* — the bridge from today's
-- | per-facet content (the `-root DIR` arg, the `image:`/`build:`) to the single
-- | declaration. `Nothing` for executors that carry no content we can name
-- | (systemd/launchd handles, unmanaged prose, a CDN with no local source).
artifactOf :: Executor -> Maybe Artifact
artifactOf = case _ of
  Process p -> Just (processArtifact p.command)
  Container (ContainerSpec cs) -> Just case cs.source of
    Left (ImageRef i) -> Image (mkRef i)
    -- a build context builds an IMAGE per host from its source dir — the
    -- anti-pattern. The dir is the content origin that must match the native
    -- facet's served dir (docs/ARTIFACTS.md).
    Right (BuildContext b) -> SourceBuild (mkRef b.context)
  StaticCDN _ -> Nothing
  SystemdUnit _ -> Nothing
  LaunchdJob _ -> Nothing
  Remote r -> artifactOf r.inner
  Unmanaged _ -> Nothing

-- Classify a Process launch command into the artifact it serves. A static file
-- server names its content with `-root DIR` (or `--root DIR`); a node bundle
-- runs an entrypoint; anything else is taken as a binary keyed by its first
-- token. The binary case carries NO source dir, so it never triggers drift —
-- heuristic on purpose: it reads today's startCommands and only the cases where
-- the content is genuinely nameable participate in the consensus. A DECLARED
-- artifact (future `x-bosun.artifact`) would replace the guess with a fact.
processArtifact :: String -> Artifact
processArtifact command = case rootArg command of
  Just dir -> StaticDir (mkRef dir)
  Nothing
    | hasNodeBundle -> BundleRuntime (mkRef (fromMaybe command (nodeEntry command)))
    | otherwise -> Binary (mkRef (firstToken command))
  where
  hasNodeBundle = String.contains (Pattern ".mjs") command || String.contains (Pattern ".js") command

-- The directory after a `-root`/`--root` flag, if present.
rootArg :: String -> Maybe String
rootArg command = go (tokens command)
  where
  go ts = case A.uncons ts of
    Nothing -> Nothing
    Just { head, tail }
      | head == "-root" || head == "--root" -> A.head tail
      | otherwise -> go tail

-- The first `*.mjs` / `*.js` token of a node command (its entrypoint bundle).
nodeEntry :: String -> Maybe String
nodeEntry command =
  A.find (\t -> String.contains (Pattern ".mjs") t || String.contains (Pattern ".js") t) (tokens command)

firstToken :: String -> String
firstToken command = fromMaybe command (A.head (tokens command))

tokens :: String -> Array String
tokens = String.split (Pattern " ") >>> A.filter (_ /= "")

-- | DERIVE a process run command from one artifact — the MISU machinery, the
-- | inverse of `artifactOf`. A `StaticDir` is served by `static-httpd`; a
-- | `BundleRuntime` by its runtime; a `Binary` runs directly. An `Image` /
-- | `SourceBuild` has no native process form (you do not run a container image —
-- | or an unbuilt source dir — as a bare process), so `Nothing`. Because the
-- | run-spec is DERIVED here from the single artifact, a process facet and a
-- | container facet cannot point at different content — the unrepresentability
-- | the whole axis exists to provide.
runCommandFor :: Port -> Artifact -> Maybe String
runCommandFor port = case _ of
  StaticDir (ArtifactRef r) -> Just ("static-httpd -root " <> r.source <> " -port " <> show (unPort port))
  BundleRuntime (ArtifactRef r) -> Just ("node " <> r.source)
  Binary (ArtifactRef r) -> Just r.source
  SourceBuild _ -> Nothing
  Image _ -> Nothing

-- | DERIVE a container source from one artifact. A prebuilt `Image` IS the
-- | container source (build-once-ship: the shipped bytes); everything else
-- | becomes a build context over its source dir (until it is built-and-shipped
-- | as an image). Pairing this with `runCommandFor` is what makes "one
-- | declaration → every substrate's run-spec" concrete.
containerSourceFor :: Artifact -> Either ImageRef BuildContext
containerSourceFor = case _ of
  Image (ArtifactRef r) -> Left (ImageRef r.source)
  a -> let (ArtifactRef r) = artifactRef a
       in Right (BuildContext { context: r.source, dockerfile: Nothing })

-- | Do a service's facets agree on content? Only facets that expose a source
-- | dir (`sourceDir`) participate — a prebuilt image / opaque launcher carries
-- | no comparable content origin. `NoArtifact` (no comparable facet), `Agreed`
-- | (one source dir — the common, healthy case, even when run-forms differ), or
-- | `Diverged` (facets name *different* source dirs — the architectural drift
-- | behind the stale public site). Compared by basename, so a path-prefix
-- | accident (the same dir reached differently per machine) does not read as
-- | drift; only a clearly different dir does.
data ArtifactConsensus
  = NoArtifact
  | Agreed Artifact
  | Diverged (NonEmptyArray Artifact)

derive instance Eq ArtifactConsensus

artifactConsensus :: Array Artifact -> ArtifactConsensus
artifactConsensus arts = case NEA.fromArray (A.filter (isJust <<< sourceDir) arts) of
  Nothing -> NoArtifact
  Just comparable ->
    let distinctDirs = A.nub (A.mapMaybe (map basename <<< sourceDir) (NEA.toArray comparable))
    in if A.length distinctDirs <= 1 then Agreed (NEA.head comparable) else Diverged comparable

basename :: String -> String
basename p = fromMaybe p (A.last (A.filter (_ /= "") (String.split (Pattern "/") p)))

-- | The artifact axis (`Bosun.Artifact`, docs/ARTIFACTS.md) — the WHAT of a
-- | deployment triple. Covers: classifying an executor's implied artifact
-- | (`artifactOf`); deriving a substrate's run-spec from one artifact
-- | (`runCommandFor`/`containerSourceFor`, the MISU machinery); and the
-- | cross-facet consensus that flags "same service, different content per
-- | substrate" — INCLUDING the guard that the canonical §7 divergence
-- | (`npx serve` native + a prebuilt image) is NOT a false positive.
module Test.Bosun.ArtifactSpec where

import Prelude

import Bosun.Artifact
  ( Artifact(..), ArtifactConsensus(..), artifactConsensus, artifactOf
  , containerSourceFor, mkRef, runCommandFor, sourceDir
  )
import Bosun.Atoms (Port, mkAbsPath, mkPort)
import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..), ImageRef(..))
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromJust)
import Partial.Unsafe (unsafePartial)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

port_ :: Int -> Port
port_ n = unsafePartial (fromJust (mkPort n))

process :: String -> Executor
process command = Process { cwd: unsafeAbs, command, env: [] }
  where
  -- cwd is irrelevant to artifactOf (it reads the command), so any abs path.
  unsafeAbs = unsafePartial (fromJust (mkAbsPath "/x"))

buildCtx :: String -> Executor
buildCtx context =
  Container (ContainerSpec { source: Right (BuildContext { context, dockerfile: Nothing }), internalPort: Nothing, publish: Nothing })

prebuilt :: String -> Executor
prebuilt image =
  Container (ContainerSpec { source: Left (ImageRef image), internalPort: Nothing, publish: Nothing })

consensusTok :: ArtifactConsensus -> String
consensusTok = case _ of
  NoArtifact -> "none"
  Agreed _ -> "agreed"
  Diverged _ -> "diverged"

spec :: Spec Unit
spec = describe "Bosun.Artifact" do

  describe "artifactOf — classifying an executor's implied content" do
    it "a static server (-root DIR) ⇒ StaticDir over that dir" $
      (artifactOf (process "static-httpd -root site/polyglot/public -port 3040") >>= sourceDir)
        `shouldEqual` Just "site/polyglot/public"
    it "a compose build context ⇒ SourceBuild over the context dir" $
      (artifactOf (buildCtx "../purescript-polyglot/site/website") >>= sourceDir)
        `shouldEqual` Just "../purescript-polyglot/site/website"
    it "a prebuilt image carries NO source dir (it is shipped, not built)" $
      (artifactOf (prebuilt "hylograph/edge:abc123") >>= sourceDir)
        `shouldEqual` Nothing
    it "an opaque launcher (npx serve) carries no source dir" $
      (artifactOf (process "npx serve") >>= sourceDir)
        `shouldEqual` Nothing

  describe "derivation — one artifact ⇒ each substrate's run-spec (MISU)" do
    it "a StaticDir derives a static-httpd process command" $
      runCommandFor (port_ 3040) (StaticDir (mkRef "site/polyglot/public"))
        `shouldEqual` Just "static-httpd -root site/polyglot/public -port 3040"
    it "a prebuilt Image derives the image as the container source (build-once-ship)" $
      (case containerSourceFor (Image (mkRef "hylograph/edge:abc")) of
         Left (ImageRef i) -> i
         Right _ -> "BUILD") `shouldEqual` "hylograph/edge:abc"
    it "a StaticDir derives a build CONTEXT for the container (until shipped as an image)" $
      (case containerSourceFor (StaticDir (mkRef "site/polyglot/public")) of
         Left _ -> "IMAGE"
         Right (BuildContext b) -> b.context) `shouldEqual` "site/polyglot/public"

  describe "artifactConsensus — do a service's facets agree on content?" do
    it "two facets, two different source dirs ⇒ Diverged (the stale-site bug)" $
      consensusTok (artifactConsensus
        [ StaticDir (mkRef "site/polyglot/public")   -- native facet serves the built dir
        , SourceBuild (mkRef "../purescript-polyglot/site/website") -- container builds another dir
        ]) `shouldEqual` "diverged"
    it "two facets, same source dir basename ⇒ Agreed (run-form may differ)" $
      consensusTok (artifactConsensus
        [ StaticDir (mkRef "/abs/path/public")
        , SourceBuild (mkRef "../relative/public")
        ]) `shouldEqual` "agreed"
    it "§7 guard: npx serve + prebuilt image ⇒ NOT drift (no comparable source dirs)" $
      consensusTok (artifactConsensus
        [ Binary (mkRef "npx")        -- from `npx serve` — no source dir
        , Image (mkRef "tidal-frontend")  -- prebuilt — no source dir
        ]) `shouldEqual` "none"
    it "a single comparable facet ⇒ Agreed (nothing to disagree with)" $
      consensusTok (artifactConsensus [ StaticDir (mkRef "site/public") ])
        `shouldEqual` "agreed"

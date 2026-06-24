-- | DESIGN §3.x — the publish-channel sum for static-site deployments.
-- |
-- | A static site reaches its CDN via one of several platform-specific
-- | mechanisms; each mechanism wants different runtime data (CF Pages
-- | git-watched needs a branch + subdir inside a workdir; CF Pages wrangler
-- | needs an artifact dir; GitHub Pages needs a workdir + branch + serving
-- | dir). The MISU shape is a sum: the variant choice encodes the channel
-- | completely, and the per-variant record holds *only* the fields meaningful
-- | to that channel. No nullable fields, no booleans about git, no shared
-- | "provider" tag that the rest of the type then has to be consistent with.
-- |
-- | Four bad states the previous `{ provider :: CDNProvider, domain :: Domain }`
-- | shape couldn't catch become structurally impossible:
-- |
-- |   - CF git-watched without a branch              → not constructible
-- |   - wrangler ship with a `branch` field          → not constructible
-- |   - GH Pages with a `cfProject`                  → not constructible
-- |   - one site claiming two channels at once       → one variant = one channel
-- |
-- | Andrew's concrete worry — "widgets has a git repo (it lives in
-- | cloudflare-sites) but the demo is on Cloudflare, not GitHub Pages" — also
-- | dissolves: widgets is just `CloudflarePagesWrangler { cfProject, artifactDir }`.
-- | The fact that artifactDir happens to live inside a git workdir is incidental
-- | infrastructure and absent from the channel model, exactly because for THIS
-- | channel git has no runtime role.
-- |
-- | BUILD vs PUBLISH. This module is the publish half only. How an artifact comes
-- | to EXIST at workdir/subdir or artifactDir (`spago bundle`, `make website`,
-- | `python3 build-book.py`, etc.) is Quartermaster's domain and lives in the
-- | future `quartermaster ship` verb. Bosun knows WHERE the artifact lives and
-- | HOW it ships; it does not know how it got there. That's the principled
-- | build-once-ship seam already established between Bosun and Quartermaster
-- | (see bosun/docs/PROVISIONING-SEAM.md).
module Bosun.Publish
  ( PublishChannel(..)
  , ChannelKey(..)
  , channelKey
  ) where

import Prelude

import Bosun.Atoms (AbsPath, GitWorkdir)
import Data.Generic.Rep (class Generic)
import Data.Show.Generic (genericShow)

-- | How a static-site artifact reaches its CDN. The variant choice IS the
-- | platform + delivery-mechanism choice; the per-variant record carries
-- | exactly the runtime data that platform needs.
data PublishChannel
  -- | CF Pages with the project wired to a git repo: CF watches `<branch>`
  -- | of `<workdir>` and auto-deploys what's in `<subdir>`. "Deploy" = git
  -- | push from the workdir. Today's hylograph.net, blog.hylograph.net,
  -- | polyglot.hylograph.net.
  = CloudflarePagesGit
      { cfProject :: String      -- the CF Pages project name (cf dashboard)
      , workdir   :: GitWorkdir  -- the repo CF watches (e.g. cloudflare-sites)
      , branch    :: String      -- usually "main"
      , subdir    :: String      -- the artifact directory inside workdir; "" = root
      }
  -- | CF Pages with the artifact uploaded directly via wrangler. No git
  -- | involvement at the CF↔upload boundary — the artifact dir is just a
  -- | local folder QM uploads wholesale. May HAPPEN to live inside a git
  -- | repo (e.g. cloudflare-sites/widgets) but that's incidental
  -- | infrastructure, not part of THIS channel. Today's widgets,
  -- | andrewcondon.com, heresiarch.com, signal-box.hylograph.net.
  | CloudflarePagesWrangler
      { cfProject   :: String
      , artifactDir :: AbsPath
      }
  -- | GitHub Pages — GH serves a directory of the source repo on `<branch>`.
  -- | "Deploy" = build into `<servingDir>`, commit, push to `<branch>`.
  -- | Today's elements-of-purescript-style, the-prelude, sigil, sigil-hats,
  -- | hylograph-demos.
  | GitHubPagesRepoDir
      { workdir    :: GitWorkdir
      , branch     :: String    -- usually "main"; some legacy sites use "gh-pages"
      , servingDir :: String    -- e.g. "docs"; "/" = root of branch
      }

derive instance Eq PublishChannel
derive instance Generic PublishChannel _
instance Show PublishChannel where show = genericShow

-- | The "same destination" key for collision validation. Each variant
-- | has its own notion of what makes two services trample each other on
-- | deploy: two CloudflarePagesGit services pushing to the same
-- | `(cfProject, branch, subdir)` would race; two wrangler services on the
-- | same `cfProject` would race; two GitHubPagesRepoDir services on the
-- | same `(workdir, branch, servingDir)` would race. Different variants
-- | are never collisions even if surface fields look similar, because they
-- | go to different CDNs entirely.
data ChannelKey
  = CfGitKey      { cfProject :: String, branch :: String, subdir :: String }
  | CfWranglerKey String                                                       -- cfProject
  | GhPagesKey    { workdir :: GitWorkdir, branch :: String, servingDir :: String }

derive instance Eq ChannelKey
derive instance Ord ChannelKey
derive instance Generic ChannelKey _
instance Show ChannelKey where show = genericShow

channelKey :: PublishChannel -> ChannelKey
channelKey = case _ of
  CloudflarePagesGit r ->
    CfGitKey { cfProject: r.cfProject, branch: r.branch, subdir: r.subdir }
  CloudflarePagesWrangler r ->
    CfWranglerKey r.cfProject
  GitHubPagesRepoDir r ->
    GhPagesKey { workdir: r.workdir, branch: r.branch, servingDir: r.servingDir }

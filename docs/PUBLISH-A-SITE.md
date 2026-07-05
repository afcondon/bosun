# Publishing a static site to a CDN (`quartermaster publish`)

**Status:** current procedure (2026-07-05). The CDN-publish companion to
`REGISTER-A-SERVICE.md` (which is *local* serving via `bosun serve`). Ownership
is decision **D-G2**; the responsibility model is `PROVISIONING-SEAM.md`.

## Serve vs publish — two different things

| | Local serve | CDN publish |
|--|--|--|
| tool | `bosun serve` (lazy-spawn router) | **`quartermaster publish`** |
| registry | `x-bosun.process` row in `fleet.json` | `x-bosun.static` block in a `compose.yml` |
| result | `http://localhost:<port>` on your machine | a site on Cloudflare Pages + its custom domain |

Bosun *declares* a static site (`x-bosun.static`) and, on `apply`, *advises*
— it does not publish. **Quartermaster publishes** (the ship half, beside its
`build` = docker build-once-ship). This is decision D-G2 and mirrors the
SourceBuild → `quartermaster build` seam.

## Declare the site (`x-bosun.static`)

A `compose.yml` beside the site (the `cloudflare-pages-wrangler` channel):

```yaml
services:
  liquid-purescript:
    x-bosun:
      host: cloudflare
      probe: http
      static:
        channel: cloudflare-pages-wrangler
        cfProject: liquid-purescript
        artifactDir: /abs/path/to/site      # the folder of built/authored assets
        url: https://liquid-purescript.hylograph.net
```

`quartermaster publish <compose> <registry>` (any `registry.json`, e.g.
`{"servers":[],"count":0}`) then ships it. `--dry-run` prints the plan.

## Host prep — TWO credentials, deliberately separate

Publishing needs two different Cloudflare permissions, and they must **not**
share the `CLOUDFLARE_API_TOKEN` env var — wrangler hijacks that name for its
own auth, and a DNS-scoped token there breaks the deploy ("Failed to
automatically retrieve account IDs"). So:

1. **wrangler OAuth** — `npx wrangler login` once. Covers the deploy + the
   Pages custom-domain *attach* (`pages:write`, account read). This is the
   ambient auth `quartermaster publish` uses for steps 1–3 below.
2. **`QM_CF_DNS_TOKEN`** — a **Zone:DNS:Edit** API token scoped to the site's
   zone (CF dashboard → My Profile → API Tokens → "Edit zone DNS" → Specific
   zone). Needed only to create the CNAME (step 4). Put it in **`~/.zshenv`**
   (not `~/.zshrc` — non-interactive shells, incl. tooling, read `~/.zshenv`):
   ```zsh
   export QM_CF_DNS_TOKEN='…'
   ```
   Without it, publish attaches the domain and prints the exact CNAME to add by
   hand — the site works on `<cfProject>.pages.dev` but the custom domain stays
   `pending` until the record exists.

## What `quartermaster publish` does (one shot, no retry loops)

1. **Ensure the Pages project** — `wrangler pages project create … || true`
   (`pages deploy` does NOT auto-create it; creating the project is provisioning).
2. **Stage a clean artifact** — rsync `artifactDir` into a scratch dir minus
   infra/meta files (`.git`, the `compose.yml`/`registry.json` declaration,
   `README.md`, `.assetsignore`). **`wrangler pages deploy` serves the dir
   wholesale and does NOT honour `.assetsignore`** (a Workers-assets feature),
   so staging is how meta files stay unpublished.
3. **Deploy** the staged dir (`wrangler pages deploy`).
4. **Ensure the custom domain** — attach it to the project (OAuth), then create
   the zone CNAME `<sub> → <cfProject>.pages.dev` (proxied) with `QM_CF_DNS_TOKEN`.

~4 CF API calls, each once, no backoff/poll loops. The custom domain shows
`pending` on CF for a few minutes after the CNAME lands while the cert
provisions, then serves.

## Worked example (liquid-purescript, 2026-07-05)

```sh
export QM_CF_DNS_TOKEN='…'    # in ~/.zshenv; Zone:DNS:Edit on hylograph.net
quartermaster publish /abs/cloudflare-sites/liquid-purescript/compose.yml \
                      /abs/cloudflare-sites/liquid-purescript/registry.json
# → project ensured, clean deploy, domain attached, CNAME created
# → live at https://liquid-purescript.hylograph.net
```

## Channels

Only **`cloudflare-pages-wrangler`** is automated today. `cloudflare-pages-git`
and `github-pages-repo-dir` are recognised (`bosun check` validates them) but
`quartermaster publish` reports them as not-yet-automated rather than acting —
never a silent skip.

## Scope boundary (what Quartermaster does NOT do here)

Quartermaster ships an artifact that already EXISTS at `artifactDir`. Building
it (`spago bundle`, `make website`, …) is out of scope for `publish` — a
pre-step, or a future `build:`-for-static hook. And this is not `quartermaster
build`: that verb is docker build-once-ship for source-built container
services; a StaticCDN site never touches it.

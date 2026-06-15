-- | Bosun's Chair v0 — the watch dashboard. A Halogen root that polls
-- | `bosun serve`'s /state every 1.5s and renders the three-way admission
-- | picture (admitted / 421-redirect / rejected) and the live route table
-- | (up?, pid). Styling is Swiss/light, in chair/index.html.
module Chair.Main where

import Prelude

import Affjax.ResponseFormat as RF
import Affjax.Web as AX
import Chair.State (RedirectInfo, RejectInfo, RouteStatus, StateView, decodeStateView)
import Data.Argonaut.Decode.Error (printJsonDecodeError)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), maybe)
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), delay)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)

stateUrl :: String
stateUrl = "http://localhost:3997/state"

pollMs :: Number
pollMs = 1500.0

type State = { view :: Maybe StateView, error :: Maybe String, ticks :: Int }

data Action = Initialize | Refresh

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  void (runUI component unit body)

component :: forall q i o. H.Component q i o Aff
component =
  H.mkComponent
    { initialState: \_ -> { view: Nothing, error: Nothing, ticks: 0 }
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handleAction, initialize = Just Initialize }
    }

handleAction :: forall o. Action -> H.HalogenM State Action () o Aff Unit
handleAction = case _ of
  Initialize -> do
    refresh
    void (H.fork pollLoop)
  Refresh -> refresh

pollLoop :: forall o. H.HalogenM State Action () o Aff Unit
pollLoop = do
  H.liftAff (delay (Milliseconds pollMs))
  refresh
  pollLoop

refresh :: forall o. H.HalogenM State Action () o Aff Unit
refresh = do
  res <- H.liftAff (AX.get RF.json stateUrl)
  H.modify_ \s -> case res of
    Left err -> s { error = Just (AX.printError err), ticks = s.ticks + 1 }
    Right resp -> case decodeStateView resp.body of
      Left e -> s { error = Just (printJsonDecodeError e), ticks = s.ticks + 1 }
      Right v -> s { view = Just v, error = Nothing, ticks = s.ticks + 1 }

-- ── render (Swiss/light; classes styled in index.html) ───────────────────────

render :: forall m. State -> H.ComponentHTML Action () m
render s =
  HH.div [ cls "chair" ]
    [ HH.header [ cls "head" ]
        [ HH.h1_ [ HH.text "Bosun’s Chair" ]
        , HH.p [ cls "sub" ] [ HH.text "cockpit for bosun serve · polling localhost:3997/state" ]
        ]
    , maybe (HH.text "") errorBanner s.error
    , case s.view of
        Nothing -> HH.p [ cls "muted" ] [ HH.text "waiting for serve…" ]
        Just v -> viewBody v
    , HH.footer [ cls "foot" ] [ HH.text ("refresh #" <> show s.ticks) ]
    ]
  where
  errorBanner e = HH.div [ cls "error" ] [ HH.text ("serve unreachable — " <> e) ]

viewBody :: forall m. StateView -> H.ComponentHTML Action () m
viewBody v =
  HH.div_
    [ HH.div [ cls "stats" ]
        [ stat "admitted" (show (Array.length (Array.filter _.up v.routes)) <> " / " <> show (Array.length v.routes) <> " up")
        , stat "redirect" (show (Array.length v.redirects))
        , stat "rejected" (show (Array.length v.rejected))
        ]
    , sectionTable "ADMITTED" (Array.length v.routes)
        [ "port", "service", "state", "backend", "pid" ]
        (map routeRow v.routes)
    , sectionTable "REDIRECT (421)" (Array.length v.redirects)
        [ "port", "service", "host", "→ target" ]
        (map redirectRow v.redirects)
    , sectionTable "REJECTED" (Array.length v.rejected)
        [ "service", "reason" ]
        (map rejectRow v.rejected)
    ]

routeRow :: forall m. RouteStatus -> H.ComponentHTML Action () m
routeRow r =
  HH.tr_
    [ td (show r.publicPort)
    , td r.serviceId
    , HH.td_ [ HH.span [ cls (if r.up then "dot up" else "dot down") ] [ HH.text (if r.up then "up" else "down") ] ]
    , td (show r.internalPort)
    , td (maybe "—" show r.pid)
    ]

redirectRow :: forall m. RedirectInfo -> H.ComponentHTML Action () m
redirectRow r =
  HH.tr_ [ td (show r.publicPort), td r.serviceId, td r.host, td r.target ]

rejectRow :: forall m. RejectInfo -> H.ComponentHTML Action () m
rejectRow r = HH.tr_ [ td r.serviceId, td r.reason ]

-- ── small html helpers ───────────────────────────────────────────────────────

sectionTable
  :: forall m
   . String
  -> Int
  -> Array String
  -> Array (H.ComponentHTML Action () m)
  -> H.ComponentHTML Action () m
sectionTable title n heads rows =
  HH.section [ cls "sec" ]
    [ HH.h2_ [ HH.text (title <> " "), HH.span [ cls "count" ] [ HH.text (show n) ] ]
    , if n == 0 then HH.p [ cls "muted" ] [ HH.text "none" ]
      else HH.table_
        [ HH.thead_ [ HH.tr_ (map (\h -> HH.th_ [ HH.text h ]) heads) ]
        , HH.tbody_ rows
        ]
    ]

stat :: forall m. String -> String -> H.ComponentHTML Action () m
stat label val =
  HH.div [ cls "stat" ]
    [ HH.div [ cls "stat-val" ] [ HH.text val ]
    , HH.div [ cls "stat-lbl" ] [ HH.text label ]
    ]

td :: forall m. String -> H.ComponentHTML Action () m
td t = HH.td_ [ HH.text t ]

cls :: forall r i. String -> HP.IProp (class :: String | r) i
cls c = HP.class_ (HH.ClassName c)

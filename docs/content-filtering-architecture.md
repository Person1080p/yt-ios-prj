# How Content Blockers Work

A technical reference on the architecture of browser content blocking, using
uBlock Origin as the worked example, and how those capabilities map onto iOS.

**Scope.** This explains how the system is designed and why it behaves the way
it does. It is not an implementation guide for removing ads from a specific
service — see [Why this app doesn't do it](#why-this-app-takes-a-different-route)
at the end for the approach taken here instead.

---

## 1. The mental model: five layers, ordered by when they act

The single most useful idea is that content blocking is not one mechanism. It is
several, acting at different moments in a page's life. A rule can only work if
there is something for it to grab at the moment it runs.

| # | Layer | Acts when | Can it see page JS state? |
|---|---|---|---|
| 1 | Dynamic filtering | Before request | No |
| 2 | Static network filtering | Before request | No |
| 3 | Redirect / resource replacement | At response | No |
| 4 | Cosmetic filtering | After DOM exists | DOM only |
| 5 | Scriptlet injection | Before page scripts run | Yes |

Layers 1–3 operate on **network requests** — they know a URL, a resource type
and an initiator, and nothing else. Layers 4–5 operate **inside the page**.

Almost every interesting question ("why can't it block X?", "why did this get
worse in Chrome?") resolves to: *which layer could act here, and is that layer
available on this platform?*

---

## 2. Layer 1 — Dynamic filtering

uBO's per-site matrix: rules the user sets interactively, at
`(source domain, destination domain, resource type)` granularity, with
block/allow/noop states.

These take **priority over static filters** and are evaluated first. The point is
that static lists are a shared public good updated slowly, while dynamic rules
are personal and immediate. Keeping them in separate layers with a defined
precedence is what lets a user override a list without editing it.

Also here: uBO's "block all third-party scripts/frames" global toggles, which
are coarse dynamic rules rather than filter-list entries.

---

## 3. Layer 2 — Static network filtering

The workhorse. Rules come from filter lists (EasyList, uBO's own, regional
lists) and are matched against every outgoing request.

### Filter anatomy

```
||example.com/ads/banner.js$script,third-party,domain=site.com
│ │           │              │
│ │           │              └── options: narrow when the rule applies
│ │           └── pattern to match in the URL
│ └── anchor: start of hostname (matches any scheme and subdomain)
└── (a leading @@ would make this an exception instead)
```

Common option families:

- **Resource type** — `$script`, `$image`, `$stylesheet`, `$xmlhttprequest`,
  `$subdocument`, `$media`, `$font`, `$websocket`, `$ping`
- **Party** — `$third-party` / `$first-party`
- **Scoping** — `$domain=a.com|b.com`, `$denyallow=`, `$matches-path=`
- **Behaviour** — `$important` (outrank exceptions), `$redirect=`,
  `$removeparam=` (strip query parameters), `$csp=` (inject a Content-Security-Policy)
- **List hygiene** — `$badfilter` neutralises a rule defined in another list,
  so one list can correct another without forking it

Exception filters invert a block: `@@||example.com^$script`. Precedence between
block, exception and `$important` is a defined order, not a guess — this is why
"why is this still loading?" usually means an exception somewhere outranks you.

### How it stays fast

This is the part most people never look at, and it's the most interesting
engineering in the project.

A naive implementation tests every rule against every URL — tens of thousands of
pattern matches per request. uBO instead:

1. **Tokenises each pattern at compile time**, extracting a representative
   substring (preferring a *rare* token, so buckets stay small).
2. **Buckets rules by token.** A request is tokenised the same way, and only
   rules sharing a token with the URL are ever tested.
3. **Stores hostname sets in a trie** (`HNTrie`) rather than a hash set, so
   `$domain=` lists with thousands of entries match in time proportional to the
   hostname length, not the list size. Some builds compile this to WASM.
4. **Caches the compiled form** (typed arrays / a custom memory buffer) so
   startup doesn't re-parse megabytes of text.

The lesson generalises: the cost of a filtering engine is dominated by candidate
selection, not by matching.

---

## 4. Layer 3 — Redirect and resource replacement

`$redirect=noopjs` serves an inert stub in place of the real resource.

The reason this exists is subtle and worth internalising: **blocking is not
always safer than substituting.** A page that does

```js
await loadAnalytics();
renderContent();
```

breaks entirely if `loadAnalytics()` rejects. A no-op stub that resolves
successfully keeps control flow intact while removing the behaviour. uBO ships a
small library of these neutered resources (empty JS, 1×1 GIF, silent MP3, stub
implementations of common analytics APIs).

This is also why aggressive blocking often "breaks sites" while curated lists
don't — the lists know where substitution beats denial.

---

## 5. Layer 4 — Cosmetic filtering

Hiding elements that *did* load.

### Declarative cosmetic filters

```
example.com##.ad-banner
example.com##div[data-ad]
```

Compiled into a stylesheet of `display: none !important` and injected. Cheap,
because the browser's own selector engine does the work.

Two scopes: **specific** (bound to a domain) and **generic** (applied broadly,
with extra machinery to avoid breaking unrelated sites).

### Procedural cosmetic filters

Some targets can't be expressed in CSS at all. uBO implements its own operators
and evaluates them in JavaScript:

| Operator | Selects by |
|---|---|
| `:has-text(...)` | visible text content |
| `:matches-css(...)` | computed style |
| `:matches-attr(...)` / `:matches-prop(...)` | attribute / JS property |
| `:upward(n)` / `:upward(selector)` | walking *up* the tree from a match |
| `:xpath(...)` | arbitrary XPath |
| `:watch-attr(...)` | re-evaluating on attribute mutation |
| `:min-text-length(n)` | text length |

Because these run in JS, they must re-evaluate on DOM mutation — which is why
heavy procedural filter use costs more than declarative ones.

### HTML filtering (Firefox only)

`example.com##^script:has-text(...)` removes nodes from the **response body
before parsing**. It requires `webRequest.filterResponseData`, which only
Firefox implements. Chrome has no equivalent, so this layer simply does not
exist there. A good example of a capability gap that isn't about policy.

---

## 6. Layer 5 — Scriptlet injection

The deepest layer, and the one that matters when nothing else has purchase.

```
example.com##+js(scriptlet-name, arg1, arg2)
```

uBO ships a library of small parameterised scripts (`assets/resources/scriptlets.js`)
injected at `document_start` — **before the page's own scripts execute**.

### What the general-purpose scriptlets do

- **`set-constant`** — defines a property to a fixed value, so a page's check
  reads a predetermined answer rather than the truth
- **`json-prune`** — wraps `JSON.parse` and `Response.prototype.json` to delete
  properties matching a path from the parsed object before the page sees it
- **`abort-on-property-read` / `-write`** — throws when a named property is
  touched, killing the script that depends on it
- **`abort-current-script`** — aborts a script matching a text pattern
- **`no-fetch-if` / `no-xhr-if`** — neuters matching requests at the API level
  rather than the network level
- **`prevent-setTimeout` / `-setInterval`** — suppresses timers whose callback
  matches a pattern

### Two things that make or break it

**Execution order.** Winning the race to run first *is* the mechanism. Once page
scripts have read their configuration, there is nothing left to influence. This
is why `document_start` and `run_at` semantics matter so much.

**JavaScript world.** Extensions normally run in an *isolated* world — a
separate global scope that shares the DOM but not JS objects. Patching
`JSON.parse` so the *page* sees the patched version requires running in the
**main world**. In MV2 this is done by injecting a `<script>` element; Chrome MV3
added `world: "MAIN"` for registered content scripts. If you ever wonder why a
scriptlet "did nothing," world confusion is the usual answer.

---

## 7. Case study: why video ads land in layer 5

A useful exercise, because it shows the layer model doing real work. Walk the
layers against a modern streaming service:

**Layer 2 (network)?** The ad media segments are served from the *same CDN
hostnames, with the same URL shape*, as the actual content. There is no
distinguishing signal available to a URL-based rule that wouldn't also match
legitimate playback. Blocking by URL means blocking the video.

**Layer 3 (redirect)?** Same problem — you can't substitute what you can't
identify.

**Layer 4 (cosmetic)?** The ad isn't a DOM element to hide; it's media playing
in the same player element as the content. Hiding it would hide everything.

**Layer 5 (scriptlet)?** The ad *schedule* arrives as part of the player's
bootstrap configuration object. That object is parsed in-page, which means it is
reachable — and it is the only thing in the whole pipeline that distinguishes an
ad from content.

So the design forces the intervention to layer 5. That isn't a preference; it's
the only layer with a usable signal. Understanding this explains a lot of
otherwise mysterious behaviour — including why services have moved ad scheduling
*into* the content stream specifically to remove that last signal.

---

## 8. The anti-adblock dynamic

Once intervention is confined to layer 5, the service's counter-move is to
verify its own invariants: did the ad actually render, did playback report the
expected events, does the measured timeline match the schedule.

The consequence is structural, not incidental:

- Countering detection means patching the detection paths too, which doubles the
  surface area that can break.
- Each player change can invalidate the patches, so filter rules for such
  services churn constantly.
- A fix has to ship on the *blocker's* release cadence. Anywhere that cadence is
  slow — an app store review queue, say — you are broken more often than working.

This is the part people underestimate. A content blocker against an adversarial
target is **a maintained position, not a configuration**. Budget for it as
ongoing work or don't take it on.

---

## 9. Platform capability matrix

The same filter list is far more or less effective depending on which layers the
host platform exposes.

| Platform / API | L2 network | L4 cosmetic | L5 scriptlet | Notes |
|---|---|---|---|---|
| Firefox (MV2) | Full, blocking | Full + HTML filtering | Full | The most capable target |
| Chrome (MV2) | Full, blocking | Full | Full | Being retired |
| Chrome (MV3) | Declarative only | Full | Constrained | Rule-count caps; `uBO Lite` is materially weaker |
| Safari content blocker | Declarative only | CSS hide only | **None** | Hard rule cap (~150k) |
| Safari Web Extension | Declarative only | Full | Full | **Scoped to Safari's own tabs** |
| `WKContentRuleList` | Declarative only | CSS hide only | **None** | Usable in your own `WKWebView` |
| `WKWebExtension` (iOS 18.4+) | Per extension | Full | Full | Loads real extensions into your own `WKWebView` |

Three things fall out of this table:

1. **"Declarative only" means no layer 5.** Any target that requires scriptlet
   injection is simply out of reach. This is the substance of the MV2 → MV3
   complaint, and it is the same reason a Safari content blocker can't do what
   uBO does.

2. **A Safari Web Extension cannot reach another app's web view.** Extensions
   are scoped to Safari's own browsing contexts. App Groups let an app and its
   extension share *data* — not script injection into a third surface. There is
   no "pipe" from a Safari extension into your `WKWebView`.

3. **`WKWebExtension` is the real equivalent**, and it's recent. It exists so
   third-party browsers can host extensions, and it does restore layer 5 inside
   your own web view. Note the iOS 18.4 floor, well above this app's iOS 17 target.

---

## 10. Glossary

- **Filter list** — a text file of rules, fetched and updated on a schedule
- **Tokenisation** — extracting a rare substring from a pattern to bucket rules
  for fast candidate selection
- **HNTrie** — hostname trie; matches large domain sets in time proportional to
  hostname length
- **Generic vs specific** — whether a cosmetic filter is scoped to a domain
- **Procedural filter** — a selector CSS can't express, evaluated in JS
- **Scriptlet** — a parameterised script injected before page scripts run
- **Isolated vs main world** — whether injected JS shares the page's JS globals
- **`document_start`** — the injection timing that runs before page scripts
- **Surrogate / no-op resource** — an inert stand-in served instead of blocking
- **DNR** — `declarativeNetRequest`, Chrome MV3's declarative network layer

---

## 11. Further reading

Primary sources, in rough order of usefulness:

- **uBO wiki** — <https://github.com/gorhill/uBlock/wiki> — in particular
  "Static filter syntax", "Procedural cosmetic filters", and "Blocking mode"
- **uBO scriptlet library** —
  `assets/resources/scriptlets.js` in <https://github.com/gorhill/uBlock>; the
  clearest way to see what layer 5 can actually do
- **AdGuard filter syntax reference** —
  <https://adguard.com/kb/general/ad-filtering/create-own-filters/> — the most
  complete written spec of this syntax family
- **Chrome `declarativeNetRequest`** —
  <https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest>
  — read the limits section to understand MV3's constraints
- **Apple content blockers** —
  <https://developer.apple.com/documentation/safariservices/creating-a-content-blocker>
- **`WKWebExtension`** —
  <https://developer.apple.com/documentation/webkit/wkwebextension>

A note on licensing, since it matters if you ever build on this: uBO is
**GPLv3**. Linking it into an App Store binary is not possible — Apple's
distribution terms add restrictions the GPL forbids. VLC was removed from the App
Store in 2011 over precisely this and had to relicense before returning.

---

## Why this app takes a different route

The layer model above explains why ad filtering against a major video service is
a permanent maintenance commitment: it can only act at layer 5, it must also
defeat active detection, and it breaks on the target's release schedule rather
than yours.

This app sidesteps that rather than entering it. `MatchingSource` takes
*discovery* from a metadata API and *audio* from a backend you control, so for
anything in your own library there is nothing to filter — no ads exist in the
path. The gap that leaves is music you don't own, and a Premium subscription
closes that one by paying for it.

See the "The hybrid source" section of the top-level [README](../README.md).

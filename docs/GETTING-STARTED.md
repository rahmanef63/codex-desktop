# Getting started: connect Codex to your own model

You cloned this repo and Codex opens with an empty model list, or you have no profile at all.
This is the short path.

## One command

```bash
bin/codex-onboard
```

It does five things, in this order, and stops at the first one that fails:

| step | what it checks | why first |
| --- | --- | --- |
| 1 | Codex Desktop is installed | nothing else matters if it is not |
| 2 | which Codex home is in use | one resolver, no hardcoded username |
| 3 | whether a profile already exists | setup must not overwrite silently |
| 4 | opens the local setup page | the page writes the profile |
| 5 | verifies the endpoint answers | a saved file is not a working profile |

Step 4 is the only interactive part. A browser opens on `127.0.0.1`; you fill in three
fields and press save. When you are done, the page's server exits — it is not a daemon.

## The setup page

Three connection types, because people arrive with three different things:

| type | what you paste | typical |
| --- | --- | --- |
| **API key** | `https://api.example.com/v1` + `sk-…` | a provider token |
| **OAuth gateway** | your gateway root + its bearer token | a local proxy that already holds the OAuth session |
| **Custom endpoint** | any OpenAI-compatible root, token optional | a local runtime, a self-hosted server |

The page does two checks before it lets you save, and both exist because their absence is
silent:

* **It calls your endpoint's `/models`.** A profile pointing at a dead URL produces a Codex
  window with an empty model list and no error message. You see 99 models here instead.
* **It refuses a model the endpoint does not serve.** Typing a model name from memory is the
  most common way to end up with a profile that loads but never answers.

If you leave the model field blank, the first model the endpoint reports is used.

## What gets written

One file, `<CODEX_HOME>/<profile>.config.toml`, mode `0600`:

```toml
model_provider = "byok_local"
model = "cx/gpt-6.1-sol"

[model_providers.byok_local]
name = "local"
base_url = "http://127.0.0.1:20128/v1"
experimental_bearer_token = "sk-…"
wire_api = "responses"
requires_openai_auth = false
```

Two fields are not optional, and the page sets both:

* `wire_api = "responses"` — anything else drops namespace tools on the Codex side;
* the key is **inline**, not `env_key`, because Codex cannot read a shell environment on
  Windows. That is also why the file is `0600`.

An existing profile is backed up to `<profile>.config.toml.bak` before being replaced.

## Running it

```bash
codex -p local                  # the profile you just made
bin/codex-byok profile list     # what is configured, and what each one can reach
bin/codex-byok pick             # every model from every profile
```

## When it does not work

| symptom | cause | fix |
| --- | --- | --- |
| page says `cannot reach it` | wrong URL, or the endpoint needs `https` | check the base URL ends at the API root, not at `/chat/completions` |
| `HTTP 401` | token wrong or expired | re-run, paste a fresh key |
| `'X' is not served by this endpoint` | the model id is wrong | copy one from the list the page prints |
| Codex opens with no models | profile in the wrong home | `bin/codex-home --json` shows which home is in use |
| model answers but tools fail | `wire_api` not `responses` | re-run setup; do not hand-edit that line |

## Security notes

The page binds `127.0.0.1` only, puts a random token in its URL so another local user cannot
reach it blind, checks the token again on every write, and exits after one successful save or
after 15 minutes. The key is never echoed to the page, never logged, and never appears in
shell history — it goes from the form straight to a `0600` file.

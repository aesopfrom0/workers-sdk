---
"@cloudflare/deploy-helpers": minor
"wrangler": minor
---

[private beta]: Create the parent Worker automatically when `wrangler preview` targets one that doesn't exist yet

Previews hang off a parent Worker, so running `wrangler preview` before the Worker had ever been deployed failed with a raw API error naming the Preview endpoint. Wrangler now offers to create an empty parent Worker with Preview URLs enabled and then carries on creating the Preview. In non-interactive environments, it creates the Worker without asking.

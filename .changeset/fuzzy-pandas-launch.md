---
"@cloudflare/workers-utils": minor
"@cloudflare/deploy-helpers": minor
"wrangler": minor
---

Add namespace-backed Container Instance Group configuration

Wrangler now accepts a `container` block on local Durable Object bindings and configures namespace-backed Container Instance Groups through the Containers API after the Worker upload resolves their namespace IDs.

The nested block accepts `type: "instance"` and a group `name`. Existing top-level `containers` entries continue to use the application-backed deployment flow unchanged.

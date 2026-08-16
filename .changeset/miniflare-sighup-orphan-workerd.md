---
"miniflare": patch
---

Terminate `workerd` when the parent process receives `SIGHUP`

Closing a terminal window sends `SIGHUP` to the processes running in it. Miniflare only listened for `SIGINT` and `SIGTERM`, so on `SIGHUP` the Node process exited on the default disposition, `dispose()` never ran, and the `workerd` child was left behind, reparented to init. Each restart leaked another one. `SIGHUP` is now handled like the other termination signals, so `workerd` is killed and the temporary directory is cleaned up.

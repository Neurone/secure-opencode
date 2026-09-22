// A directory-based plugin, not a single file: opencode only resolves a
// "tui" entrypoint (see tui.js) for plugins loaded from a directory, and
// only includes a discovered plugin at all once it also has a "server"
// entrypoint (see packages/core/src/config/plugin/source.ts's
// `if (!entrypoints.server) return []` in the upstream source) -- hence this
// no-op server-role module alongside it.
export default {
  id: "sandbox-banner",
  setup: async () => {},
}

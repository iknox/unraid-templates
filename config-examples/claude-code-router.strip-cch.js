// CCR custom router that strips Claude Code's per-request cache-bust hash.
//
// Claude Code injects a system text block like:
//   "x-anthropic-billing-header: cc_version=2.1.143.23e; cc_entrypoint=sdk-cli; cch=<5-hex>;"
// where <5-hex> changes every request. That mutation defeats prefix-cache
// reuse on any local backend, forcing full reprocess of 40K+ tokens per turn.
//
// We strip lines beginning with "x-anthropic-billing-header:" entirely, so
// turn N+1 lines up perfectly with turn N for everything before the first
// real user message.
//
// Returns nothing (undefined) so CCR's default routing logic still runs.

module.exports = function stripCch(req, config, ctx) {
  const sys = req.body && req.body.system;
  if (Array.isArray(sys)) {
    for (let i = 0; i < sys.length; i++) {
      const block = sys[i];
      if (block && typeof block.text === "string" &&
          block.text.startsWith("x-anthropic-billing-header:")) {
        sys.splice(i, 1);
        i--;
      }
    }
  } else if (typeof sys === "string" &&
             sys.startsWith("x-anthropic-billing-header:")) {
    // Strip leading line through first newline.
    const nl = sys.indexOf("\n");
    req.body.system = nl >= 0 ? sys.slice(nl + 1) : "";
  }
  // Returning undefined lets CCR's built-in router pick the model.
};

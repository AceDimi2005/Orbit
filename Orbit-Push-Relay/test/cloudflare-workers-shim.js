// Stand-in for the "cloudflare:workers" module when the relay runs under
// Node's test runner. Only the parts the relay uses.
export class DurableObject {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
  }
}

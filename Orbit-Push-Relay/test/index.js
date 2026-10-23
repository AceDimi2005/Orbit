// Entry point for `node --test Orbit-Push-Relay/test` (Node resolves a
// directory argument to its index.js). Each file can also run on its own:
//   node --test Orbit-Push-Relay/test/apns.test.js
import './apns.test.js';
import './worker.test.js';
import './channel.test.js';

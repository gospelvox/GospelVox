"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sessionWatchdog = void 0;
const scheduler_1 = require("firebase-functions/v2/scheduler");
const constants_1 = require("../config/constants");
exports.sessionWatchdog = (0, scheduler_1.onSchedule)({ schedule: "every 5 minutes", region: constants_1.REGION }, async () => {
    // TODO Week 3: Find sessions with no heartbeat > 2 min
    // Auto-end them, charge only confirmed minutes
    console.log("Session watchdog — not yet implemented");
});
//# sourceMappingURL=sessionWatchdog.js.map
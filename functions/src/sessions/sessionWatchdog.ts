import {onSchedule} from "firebase-functions/v2/scheduler";
import {REGION} from "../config/constants";

export const sessionWatchdog = onSchedule(
  {schedule: "every 5 minutes", region: REGION},
  async () => {
    // TODO Week 3: Find sessions with no heartbeat > 2 min
    // Auto-end them, charge only confirmed minutes
    console.log("Session watchdog — not yet implemented");
  }
);

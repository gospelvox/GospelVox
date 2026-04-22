import {onCall, HttpsError} from "firebase-functions/v2/https";
import {REGION} from "../config/constants";

export const billingTick = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 3: Called by client heartbeat every 60s
    // Deduct coins from user, credit priest earnings
    // Check low balance, auto-end if zero
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);

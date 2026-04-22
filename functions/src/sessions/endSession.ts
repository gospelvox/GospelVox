import {onCall, HttpsError} from "firebase-functions/v2/https";
import {REGION} from "../config/constants";

export const endSession = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 3: End session, final billing, update stats
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);

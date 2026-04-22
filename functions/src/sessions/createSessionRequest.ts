import {onCall, HttpsError} from "firebase-functions/v2/https";
import {REGION} from "../config/constants";

export const createSessionRequest = onCall(
  {region: REGION},
  async (request) => {
    // TODO Week 3: Create session doc, check user balance,
    // notify priest, return sessionId
    throw new HttpsError("unimplemented", "Not yet implemented");
  }
);
